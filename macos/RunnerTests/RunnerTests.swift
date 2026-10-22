import Cocoa
import FlutterMacOS
import XCTest

@testable import EnCryNote

/// Native channel checks that do not need a running Flutter engine.
///
/// The commit cases only use a uniquely named child of the app's private
/// support root and are rejected on the path check, so no vault file is read,
/// moved or written.
class RunnerTests: XCTestCase {

  private func invoke(
    _ call: FlutterMethodCall, on bridge: EnCryNoteBridge = EnCryNoteBridge()
  ) -> (result: Any?, error: FlutterError?) {
    var value: Any?
    var failure: FlutterError?
    bridge.handle(call) { result in
      if let error = result as? FlutterError {
        failure = error
      } else {
        value = result
      }
    }
    return (value, failure)
  }

  func testUnknownMethodIsNotImplemented() {
    let bridge = EnCryNoteBridge()
    var called = false
    bridge.handle(FlutterMethodCall(methodName: "nope", arguments: nil)) { result in
      called = true
      XCTAssertTrue(result as AnyObject === FlutterMethodNotImplemented)
    }
    XCTAssertTrue(called)
  }

  func testShieldCallSucceedsWithoutAWindow() {
    let (result, error) = invoke(
      FlutterMethodCall(methodName: "setPrivacyShield", arguments: true))
    XCTAssertNil(error)
    XCTAssertNil(result as? FlutterError)
  }

  func testCommitWithMissingArgumentsIsRejected() {
    let (_, error) = invoke(
      FlutterMethodCall(methodName: "commitVault", arguments: ["stagedPath": "/tmp/x"]))
    XCTAssertEqual(error?.code, "storage")
    XCTAssertEqual(error?.message, "commit.arguments")
  }

  func testCommitOutsideThePrivateRootIsRejected() {
    let outside = FileManager.default.temporaryDirectory
      .appendingPathComponent("encrynote_native_test_\(UUID().uuidString)")
    let root = outside.path
    let expectation = expectation(description: "rejected")
    EnCryNoteBridge().handle(
      FlutterMethodCall(
        methodName: "commitVault",
        arguments: [
          "stagedPath": "\(root)/vault.next",
          "activePath": "\(root)/vault.enc",
          "previousPath": "\(root)/vault.previous",
        ]
      )
    ) { result in
      let error = result as? FlutterError
      XCTAssertEqual(error?.code, "storage")
      XCTAssertEqual(error?.message, "commit.path")
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 5)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root))
  }

  func testShieldInstallsAndRemovesAnOpaqueCover() {
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
    let bridge = EnCryNoteBridge()
    bridge.attachHostView(host)

    let show = invoke(
      FlutterMethodCall(methodName: "setPrivacyShield", arguments: true), on: bridge)
    XCTAssertNil(show.error)
    XCTAssertTrue(bridge.isShieldInstalled)
    XCTAssertEqual(host.subviews.count, 1)
    XCTAssertEqual(host.subviews.first?.frame, host.bounds)
    XCTAssertEqual(host.subviews.first?.layer?.backgroundColor, NSColor.black.cgColor)

    let hide = invoke(
      FlutterMethodCall(methodName: "setPrivacyShield", arguments: false), on: bridge)
    XCTAssertNil(hide.error)
    XCTAssertFalse(bridge.isShieldInstalled)
    XCTAssertTrue(host.subviews.isEmpty)
  }

  func testShieldIsIdempotent() {
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
    let bridge = EnCryNoteBridge()
    bridge.attachHostView(host)
    _ = invoke(FlutterMethodCall(methodName: "setPrivacyShield", arguments: true), on: bridge)
    _ = invoke(FlutterMethodCall(methodName: "setPrivacyShield", arguments: true), on: bridge)
    XCTAssertEqual(host.subviews.count, 1)

    _ = invoke(FlutterMethodCall(methodName: "setPrivacyShield", arguments: false), on: bridge)
    _ = invoke(FlutterMethodCall(methodName: "setPrivacyShield", arguments: false), on: bridge)
    XCTAssertTrue(host.subviews.isEmpty)
  }

  func testLosingActiveShieldsAndGainingItOnlyReports() {
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
    let bridge = EnCryNoteBridge()
    bridge.attachHostView(host)
    bridge.observeFocus()
    addTeardownBlock {
      NotificationCenter.default.removeObserver(bridge)
    }

    NotificationCenter.default.post(
      name: NSApplication.didResignActiveNotification, object: nil)
    XCTAssertTrue(bridge.isShieldInstalled)

    // Regaining focus only reports it; Flutter removes the cover after its own
    // deadline and frame checks, so the native side must not uncover anything.
    NotificationCenter.default.post(
      name: NSApplication.didBecomeActiveNotification, object: nil)
    XCTAssertTrue(bridge.isShieldInstalled)
  }

  func testCommitWithEscapedBasenameIsRejected() {
    let root = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("encrynote_test_\(UUID().uuidString)")
    let expectation = expectation(description: "rejected")
    EnCryNoteBridge().handle(
      FlutterMethodCall(
        methodName: "commitVault",
        arguments: [
          "stagedPath": "\(root.path)/not-vault.next",
          "activePath": "\(root.path)/vault.enc",
          "previousPath": "\(root.path)/vault.previous",
        ]
      )
    ) { result in
      let error = result as? FlutterError
      XCTAssertEqual(error?.message, "commit.path")
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 5)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
  }
}
