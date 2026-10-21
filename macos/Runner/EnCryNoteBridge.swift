import Foundation
import FlutterMacOS

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
final class EnCryNoteBridge: NSObject, FlutterPlugin {
  private static let channelName = "encrynote/platform"
  private static let stagedName = "vault.next"
  private static let activeName = "vault.enc"
  private static let previousName = "vault.previous"

  private let queue = DispatchQueue(label: "encrynote.commit")

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName, binaryMessenger: registrar.messenger)
    registrar.addMethodCallDelegate(EnCryNoteBridge(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "commitVault" else {
      result(FlutterMethodNotImplemented)
      return
    }
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

    // All three must share one parent; the vault is one directory, not a set of
    // files that may be split across directories.
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
