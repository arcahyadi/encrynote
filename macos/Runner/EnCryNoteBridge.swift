import Cocoa
import FlutterMacOS
import UniformTypeIdentifiers

/// Replaces the vault on disk with an explicit commit point.
///
/// Commit point: the staged ciphertext is renamed over the active file, the new
/// active file is flushed to stable storage, and the parent directory is
/// flushed. Success is only reported after all three.
///
/// Failure semantics: any failure after the active file was moved puts the
/// previous generation back, so a failed commit leaves the old vault active and
/// a caller that reports "not saved" tells the truth. If that rollback itself
/// fails, the active generation is genuinely unknown and the call reports
/// `commit.uncertain` rather than claiming either outcome.
///
/// It also owns the privacy shield and the window-focus stream. The shield is
/// installed when the app or its window loses key status, before AppKit can
/// snapshot the window; only Flutter removes it, after its deadline and frame
/// checks.
///
/// File transfer goes through NSOpenPanel/NSSavePanel. A pick keeps only the
/// security-scoped URL for the current selection; a read starts that scope,
/// streams with a byte bound, and stops it again. No path from Flutter is ever
/// opened, and no plaintext copy is cached.
final class EnCryNoteBridge: NSObject, FlutterPlugin, FlutterStreamHandler {
  private static let channelName = "encrynote/platform"
  private static let focusChannelName = "encrynote/focus"
  private static let stagedName = "vault.next"
  private static let activeName = "vault.enc"
  private static let previousName = "vault.previous"

  /// Bounds the bytes a read may hand back even when the file reports no size.
  private static let readChunk = 64 * 1024

  private let queue = DispatchQueue(label: "encrynote.commit")
  private weak var registrarView: NSView?
  private var shield: NSView?
  private var focusSink: FlutterEventSink?

  /// The security-scoped URL the picker last returned, plus its opaque handle.
  private var importURL: URL?
  private var importToken: String?

  /// Test seam: whether the opaque cover is currently installed.
  var isShieldInstalled: Bool { shield != nil }

  /// Test seam: supplies the view the cover is installed over.
  func attachHostView(_ view: NSView) {
    registrarView = view
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let bridge = EnCryNoteBridge()
    bridge.registrarView = registrar.view
    let channel = FlutterMethodChannel(
      name: channelName, binaryMessenger: registrar.messenger)
    registrar.addMethodCallDelegate(bridge, channel: channel)
    let focus = FlutterEventChannel(
      name: focusChannelName, binaryMessenger: registrar.messenger)
    focus.setStreamHandler(bridge)
    bridge.observeFocus()
  }

  /// AppKit tells us before the window is hidden or the app is deactivated, so
  /// the cover is already in place when the system takes its snapshot.
  ///
  /// Window notifications are filtered to this app's own window: an OS open or
  /// save panel becomes key while the app is still in front, and that must not
  /// count as the app regaining focus.
  func observeFocus() {
    let center = NotificationCenter.default
    let window = registrarView?.window
    center.addObserver(
      self, selector: #selector(willLoseFocus),
      name: NSApplication.didResignActiveNotification, object: nil)
    center.addObserver(
      self, selector: #selector(willLoseFocus),
      name: NSWindow.didResignKeyNotification, object: window)
    center.addObserver(
      self, selector: #selector(willLoseFocus),
      name: NSWindow.didMiniaturizeNotification, object: window)
    center.addObserver(
      self, selector: #selector(didGainFocus),
      name: NSApplication.didBecomeActiveNotification, object: nil)
    center.addObserver(
      self, selector: #selector(didGainFocus),
      name: NSWindow.didBecomeKeyNotification, object: window)
  }

  @objc private func willLoseFocus() {
    installShield()
    focusSink?(false)
  }

  @objc private func didGainFocus() {
    focusSink?(true)
  }

  func onListen(
    withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    focusSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    focusSink = nil
    return nil
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "setPrivacyShield":
      if call.arguments as? Bool == true { installShield() } else { removeShield() }
      result(nil)
    case "commitVault":
      commitCall(call, result: result)
    case "pickImport":
      pickImport(result: result)
    case "readImport":
      readImport(call, result: result)
    case "releaseImport":
      releaseImport(call.arguments as? String)
      result(nil)
    case "saveExport":
      saveExport(call, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // --- document panels -----------------------------------------------------

  /// Shows an open panel and keeps only a security-scoped URL for the choice.
  private func pickImport(result: @escaping FlutterResult) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    // No network volumes and no packages: this is a local note file.
    panel.resolvesAliases = false
    panel.treatsFilePackagesAsDirectories = false
    panel.allowedContentTypes = [.plainText, .data]
    panel.begin { response in
      guard response == .OK, let url = panel.url else {
        result(nil)
        return
      }
      self.releaseImport(nil)
      let token = UUID().uuidString
      self.importURL = url
      self.importToken = token
      let length = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
      result([
        "token": token,
        "name": url.lastPathComponent,
        "length": length as Any,
      ])
    }
  }

  /// Streams the picked file inside its security scope, refusing more than
  /// `maxBytes` on the bytes read rather than on a reported size.
  private func readImport(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any]
    guard let token = arguments?["token"] as? String,
      let maxBytes = arguments?["maxBytes"] as? Int, maxBytes > 0
    else {
      result(FlutterError(code: "format", message: "read.arguments", details: nil))
      return
    }
    guard let url = importURL, token == importToken else {
      result(FlutterError(code: "storage", message: "read.grant", details: nil))
      return
    }
    queue.async {
      let scoped = url.startAccessingSecurityScopedResource()
      defer { if scoped { url.stopAccessingSecurityScopedResource() } }
      do {
        let data = try Self.readBounded(url, maxBytes: maxBytes)
        DispatchQueue.main.async { result(FlutterStandardTypedData(bytes: data)) }
      } catch ReadFailure.tooLarge {
        DispatchQueue.main.async {
          result(FlutterError(code: "limit", message: "read.size", details: nil))
        }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "storage", message: "read.stream", details: nil))
        }
      }
    }
  }

  private enum ReadFailure: Error { case tooLarge }

  private static func readBounded(_ url: URL, maxBytes: Int) throws -> Data {
    guard let handle = try? FileHandle(forReadingFrom: url) else {
      throw ReadFailure.tooLarge
    }
    defer { try? handle.close() }
    var data = Data()
    while true {
      let chunk = try handle.read(upToCount: readChunk) ?? Data()
      if chunk.isEmpty { break }
      if data.count + chunk.count > maxBytes { throw ReadFailure.tooLarge }
      data.append(chunk)
    }
    return data
  }

  private func releaseImport(_ token: String?) {
    // Only the current selection can be dropped; a stale token is a no-op.
    if let token = token, token != importToken { return }
    importURL = nil
    importToken = nil
  }

  /// Shows a save panel and writes only the ciphertext Flutter prepared.
  private func saveExport(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any]
    guard let typed = arguments?["bytes"] as? FlutterStandardTypedData,
      let fileName = arguments?["fileName"] as? String,
      !fileName.contains("/")
    else {
      result(FlutterError(code: "format", message: "save.arguments", details: nil))
      return
    }
    let bytes = typed.data
    let panel = NSSavePanel()
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = fileName
    panel.begin { response in
      guard response == .OK, let url = panel.url else {
        result(false)
        return
      }
      let scoped = url.startAccessingSecurityScopedResource()
      defer { if scoped { url.stopAccessingSecurityScopedResource() } }
      do {
        try bytes.write(to: url, options: .atomic)
        result(true)
      } catch {
        result(
          FlutterError(
            code: "storage", message: "save.write",
            details: error.localizedDescription))
      }
    }
  }

  private func commitCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any]
    guard let stagedPath = arguments?["stagedPath"] as? String,
      let activePath = arguments?["activePath"] as? String,
      let previousPath = arguments?["previousPath"] as? String
    else {
      result(FlutterError(code: "storage", message: "commit.arguments", details: nil))
      return
    }
    // Filesystem work runs off the platform main thread.
    queue.async {
      do {
        try self.commit(staged: stagedPath, active: activePath, previous: previousPath)
        DispatchQueue.main.async { result(nil) }
      } catch let failure as CommitFailure {
        DispatchQueue.main.async {
          result(FlutterError(code: "storage", message: failure.reason, details: nil))
        }
      } catch {
        DispatchQueue.main.async {
          result(
            FlutterError(
              code: "storage", message: "commit.uncertain",
              details: error.localizedDescription))
        }
      }
    }
  }

  /// Opaque and covering, so no stale note frame reaches the app switcher.
  private func installShield() {
    let host = registrarView ?? NSApplication.shared.mainWindow?.contentView
    guard shield == nil, let host = host else { return }
    let cover = NSView(frame: host.bounds)
    cover.autoresizingMask = [.width, .height]
    cover.wantsLayer = true
    cover.layer?.backgroundColor = NSColor.black.cgColor
    host.addSubview(cover, positioned: .above, relativeTo: nil)
    shield = cover
  }

  private func removeShield() {
    shield?.removeFromSuperview()
    shield = nil
  }

  private struct CommitFailure: Error {
    let reason: String
  }

  /// The OS-provided private root for this app's support data.
  private var supportRoot: URL {
    let base = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask)[0]
    // path_provider adds the bundle id for non-sandboxed macOS builds; the
    // extra level is harmless inside the sandbox container.
    if let bundleId = Bundle.main.bundleIdentifier {
      return base.appendingPathComponent(bundleId, isDirectory: true)
    }
    return base
  }

  private func commit(staged: String, active: String, previous: String) throws {
    let root = supportRoot.standardizedFileURL.resolvingSymlinksInPath()
    let stagedURL = try checkedURL(staged, root: root, expectedName: Self.stagedName)
    let activeURL = try checkedURL(active, root: root, expectedName: Self.activeName)
    let previousURL = try checkedURL(
      previous, root: root, expectedName: Self.previousName)

    // All three must share one parent; the vault is one directory, not a set
    // of files that may be split across directories.
    let parent = activeURL.deletingLastPathComponent()
    guard stagedURL.deletingLastPathComponent().path == parent.path,
      previousURL.deletingLastPathComponent().path == parent.path
    else {
      throw CommitFailure(reason: "commit.path")
    }

    var isDirectory: ObjCBool = false
    guard
      FileManager.default.fileExists(atPath: stagedURL.path, isDirectory: &isDirectory),
      !isDirectory.boolValue
    else {
      throw CommitFailure(reason: "commit.staged")
    }

    let hadActive = FileManager.default.fileExists(atPath: activeURL.path)
    if hadActive {
      // Retire the current generation first; the active file still holds the
      // same bytes, so an interruption here never loses the only copy. POSIX
      // rename replaces the destination atomically.
      guard rename(activeURL.path, previousURL.path) == 0 else {
        throw CommitFailure(reason: "commit.backup")
      }
    }

    do {
      try syncDirectory(parent)
      guard rename(stagedURL.path, activeURL.path) == 0 else {
        throw CommitFailure(reason: "commit.replace")
      }
      try syncFile(activeURL)
      try syncDirectory(parent)
    } catch {
      let failure = error as? CommitFailure ?? CommitFailure(reason: "commit.sync")
      try rollback(
        staged: stagedURL, active: activeURL, previous: previousURL, hadActive: hadActive)
      throw failure
    }
  }

  /// Restores the previous generation after a failed commit. Leaving the new
  /// generation active would make a reported failure a lie, and for a password
  /// change it would leave the on-disk credentials different from the ones the
  /// caller believes are active.
  private func rollback(
    staged: URL, active: URL, previous: URL, hadActive: Bool
  ) throws {
    if FileManager.default.fileExists(atPath: active.path) {
      guard rename(active.path, staged.path) == 0 else {
        throw CommitFailure(reason: "commit.uncertain")
      }
    }
    if hadActive {
      guard rename(previous.path, active.path) == 0 else {
        throw CommitFailure(reason: "commit.uncertain")
      }
    }
    // Best effort: if this sync fails the old bytes are still active, which is
    // the state the caller reports.
    try? syncDirectory(active.deletingLastPathComponent())
  }

  /// Resolves [path] and requires the fixed basename plus a canonical parent
  /// that is the private root or a directory inside it. Import/export
  /// locations are outside that root, and a symlink that resolves outside it is
  /// rejected, so neither can become a commit target.
  private func checkedURL(_ path: String, root: URL, expectedName: String) throws -> URL {
    let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
    guard url.lastPathComponent == expectedName else {
      throw CommitFailure(reason: "commit.path")
    }
    let parent = url.deletingLastPathComponent()
    let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
    guard parent.path == root.path || parent.path.hasPrefix(prefix) else {
      throw CommitFailure(reason: "commit.path")
    }
    return url
  }

  private func syncFile(_ url: URL) throws {
    let fd = open(url.path, O_RDONLY)
    guard fd >= 0 else { throw CommitFailure(reason: "commit.sync") }
    defer { close(fd) }
    try syncDescriptor(fd)
  }

  /// Makes the rename itself durable; not every filesystem honours this.
  private func syncDirectory(_ url: URL) throws {
    let fd = open(url.path, O_RDONLY)
    guard fd >= 0 else { throw CommitFailure(reason: "commit.sync") }
    defer { close(fd) }
    try syncDescriptor(fd)
  }

  private func syncDescriptor(_ fd: Int32) throws {
    // F_FULLFSYNC asks the drive to flush its cache; plain fsync is the fallback
    // for filesystems that do not support it.
    if fcntl(fd, F_FULLFSYNC) == 0 { return }
    guard fsync(fd) == 0 else { throw CommitFailure(reason: "commit.sync") }
  }
}
