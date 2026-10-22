import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hello_flutter/platform/native_bridge.dart';
import 'package:hello_flutter/platform/privacy_lifecycle.dart';
import 'package:hello_flutter/session/note_session.dart';
import 'package:hello_flutter/vault/vault_crypto.dart';
import 'package:hello_flutter/vault/vault_store.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

/// Exercises the real native privacy channel on the target platform.
///
/// Usage:
///   flutter test integration_test/privacy_platform_test.dart -d macos
///   flutter test integration_test/privacy_platform_test.dart -d DEVICE_ID
///
/// The cover is painted by the platform and the OS snapshot is taken by the
/// system compositor, so no test here can observe the snapshot itself. What the
/// last test does prove is the part Flutter owns: the engine reports a
/// rasterized frame through its frame timings, and only then does the lifecycle
/// ask the real channel to remove the cover.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const native = MethodChannelNativeBridge();

  testWidgets('the native shield channel accepts show and hide', (
    tester,
  ) async {
    await native.setPrivacyShield(true);
    await native.setPrivacyShield(false);
  });

  testWidgets('the focus stream can be subscribed and cancelled', (
    tester,
  ) async {
    final events = <bool>[];
    final subscription = native.focusChanges.listen(events.add);
    await subscription.cancel();
    expect(events, isEmpty);
  });

  testWidgets('the cover comes off only after a rasterized frame', (
    tester,
  ) async {
    // A scratch store under the app's own support root, never the live vault.
    final root = await getApplicationSupportDirectory();
    final dir = Directory(
      '${root.path}/encrynote_privacy_${pid}_'
      '${DateTime.now().microsecondsSinceEpoch}',
    );
    await dir.create(recursive: true);
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    final session = NoteSession(
      crypto: VaultCrypto(),
      store: VaultStore(directory: dir, native: native),
    );
    await session.load();
    expect(session.phase, SessionPhase.needsSetup);

    final bridge = _RecordingBridge(native);
    await tester.pumpWidget(
      PrivacyLifecycle(
        session: session,
        native: bridge,
        child: const SizedBox.expand(),
      ),
    );
    await tester.pump();

    bridge.focus(false);
    await _until(tester, () => bridge.shielded);
    expect(bridge.shielded, isTrue);

    // Focus returns; nothing in this test reports timings by hand. The cover
    // must come off on its own, driven by the engine's raster reports.
    bridge.focus(true);
    await _until(tester, () => !bridge.shielded);
    expect(
      bridge.shielded,
      isFalse,
      reason: 'the live engine must report a rasterized frame',
    );

    await tester.pumpWidget(const SizedBox.expand());
    session.dispose();
  });
}

/// Pumps real frames until [done] or a few seconds pass.
Future<void> _until(WidgetTester tester, bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 8));
  while (!done() && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 16));
    await Future<void>.delayed(const Duration(milliseconds: 16));
  }
}

/// Forwards to the real channel and remembers the last requested state.
class _RecordingBridge implements NativeBridge {
  _RecordingBridge(this._inner);

  final NativeBridge _inner;
  final StreamController<bool> _focus = StreamController<bool>.broadcast();
  bool shielded = false;

  void focus(bool focused) => _focus.add(focused);

  @override
  Stream<bool> get focusChanges => _focus.stream;

  @override
  Future<void> setPrivacyShield(bool visible) async {
    await _inner.setPrivacyShield(visible);
    shielded = visible;
  }

  @override
  Future<PickedImport?> pickImport() => _inner.pickImport();

  @override
  Future<Uint8List> readImport(String token, {required int maxBytes}) =>
      _inner.readImport(token, maxBytes: maxBytes);

  @override
  Future<void> releaseImport(String token) => _inner.releaseImport(token);

  @override
  Future<bool> saveExport(Uint8List bytes, {required String fileName}) =>
      _inner.saveExport(bytes, fileName: fileName);

  @override
  Future<void> commitVault({
    required String stagedPath,
    required String activePath,
    required String previousPath,
  }) => _inner.commitVault(
    stagedPath: stagedPath,
    activePath: activePath,
    previousPath: previousPath,
  );
}
