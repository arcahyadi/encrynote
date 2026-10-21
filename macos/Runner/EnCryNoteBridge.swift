import Foundation
import FlutterMacOS

/// Replaces the vault on disk with an explicit commit point.
///
/// Commit point: the staged ciphertext is renamed over the active file, the new
/// active file is flushed to stable storage, and the parent directory is
/// flushed. Success is only reported after all three. The previous generation is
/// kept as the recovery candidate for an interrupted replacement.
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
              code: "storage", message: "commit.failed",
              details: error.localizedDescription))
        }
      }
    }
  }

  private struct CommitFailure: Error {
    let reason: String
  }

  /// The OS-provided private directory this app writes its vault into.
  private var supportDirectory: URL {
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
    let base = supportDirectory.standardizedFileURL.resolvingSymlinksInPath()
    let stagedURL = try checkedURL(staged, base: base, expectedName: Self.stagedName)
    let activeURL = try checkedURL(active, base: base, expectedName: Self.activeName)
    let previousURL = try checkedURL(
      previous, base: base, expectedName: Self.previousName)

    guard FileManager.default.fileExists(atPath: stagedURL.path) else {
      throw CommitFailure(reason: "commit.staged")
    }

    // Retire the current generation first; the active file still holds the same
    // bytes, so an interruption here never loses the only copy. POSIX rename
    // replaces the destination atomically, so there is no window without a
    // previous generation.
    if FileManager.default.fileExists(atPath: activeURL.path) {
      guard rename(activeURL.path, previousURL.path) == 0 else {
        throw CommitFailure(reason: "commit.backup")
      }
    }
    try syncDirectory(base)

    guard rename(stagedURL.path, activeURL.path) == 0 else {
      throw CommitFailure(reason: "commit.replace")
    }
    try syncFile(activeURL)
    try syncDirectory(base)
  }

  /// Resolves [path] and requires the fixed basename plus the private directory
  /// as its exact parent. Import/export locations are outside it, so they can
  /// never become a commit target.
  private func checkedURL(_ path: String, base: URL, expectedName: String) throws -> URL {
    let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
    guard url.lastPathComponent == expectedName,
      url.deletingLastPathComponent().path == base.path
    else {
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
