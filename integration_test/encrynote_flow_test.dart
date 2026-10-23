import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hello_flutter/platform/native_bridge.dart';
import 'package:hello_flutter/session/note_session.dart';
import 'package:hello_flutter/transfer/transfer_service.dart';
import 'package:hello_flutter/vault/vault_crypto.dart';
import 'package:hello_flutter/vault/vault_store.dart';
import 'package:hello_flutter/vault/vault_types.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import '../test/support/fixtures.dart';

/// End-to-end EnCryNote flow on a real platform: real crypto, real vault files,
/// real native commit. Only the OS file dialog is replaced, by a bridge that
/// hands back test-owned exchange files instead of showing a panel.
///
/// Usage:
///   flutter test integration_test/encrynote_flow_test.dart -d macos --no-uninstall
///   flutter test integration_test/encrynote_flow_test.dart -d DEVICE_ID --no-uninstall
///
/// Always pass `--no-uninstall`, and only on a device or emulator you own or can
/// throw away that holds no personal vault. The test build uses the product
/// application id, and `flutter test` uninstalls that package afterwards by
/// default, which deletes its private data directory (`vault.enc`,
/// `vault.previous`). A test-owned subdirectory does not protect a real vault.
///
/// Cross-platform exchange (both directions):
///   1. Run on platform A; the log prints `EXCHANGE_EXPORT=<path>` and
///      `EXCHANGE_EXPORT_BASE64=<artifact>`. Copy the path when the host can
///      reach the app's private directory; otherwise decode the base64 into a
///      file the host can write (for example `/data/local/tmp/` via `adb push`).
///      The base64 form also works when the app is uninstalled afterwards.
///   2. Copy that file to a test-owned path on platform B.
///   3. Run on B with
///      `--dart-define=ENCRYNOTE_IMPORT_ARTIFACT=<path>`
///      `--dart-define=ENCRYNOTE_EXPECT_MARKER=<marker from A>`
///      and read the `EXCHANGE_EXPORT=` path it prints.
///   4. Copy B's export back to A and repeat step 3 there.
///
/// The base64 line is log transport for the artifact, not a product path: the
/// file it decodes to is still a normal export opened only by its password.
///
/// Every vault and artifact lives in a fresh subdirectory of the app's private
/// support root. The live `vault.enc` in that root is never read or written.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final crypto = VaultCrypto();

  const exportPassword = 'export-1234';
  const restartedPassword = 'recovered-5678';
  const secondPassword = 'second-1234';
  // The note marker is overridable so each side of an exchange writes a
  // recognisable note: the receiving run then proves whose export it opened.
  const marker = String.fromEnvironment(
    'ENCRYNOTE_MARKER',
    defaultValue: 'flow-marker-a71f',
  );
  const exchangedMarker = String.fromEnvironment('ENCRYNOTE_EXPECT_MARKER');

  late Directory root;
  late Directory dir;
  late Directory exchangeDir;
  late Directory cacheDir;

  Directory uniqueDir(String label) => Directory(
    '${root.path}/encrynote_flow_${label}_${pid}_'
    '${DateTime.now().microsecondsSinceEpoch}',
  );

  File exportFile() => File('${exchangeDir.path}/export.encrynote');

  setUpAll(() async {
    root = await getApplicationSupportDirectory();
    dir = uniqueDir('a');
    await dir.create(recursive: true);
    // The exchange artifact outlives the test body only so the log can carry it
    // to the other platform; tearDownAll removes it. Nothing is left behind.
    exchangeDir = uniqueDir('exchange');
    await exchangeDir.create(recursive: true);
    // A cache directory this run owns, so the plaintext scan never reads the
    // shared app cache (which the real app and other runs also use).
    cacheDir = Directory(
      '${(await getApplicationCacheDirectory()).path}/'
      'encrynote_flow_cache_${pid}_'
      '${DateTime.now().microsecondsSinceEpoch}',
    );
    await cacheDir.create(recursive: true);
    // ignore: avoid_print
    print('flow test directory: ${dir.path}');
  });

  tearDownAll(() async {
    for (final owned in [dir, exchangeDir, cacheDir]) {
      if (await owned.exists()) await owned.delete(recursive: true);
    }
  });

  testWidgets(
    'setup, write, restart locked, unlock, recovery, export, import',
    (tester) async {
      final bridge = _ExchangeBridge(exportPath: exportFile().path);
      final session = NoteSession(
        crypto: crypto,
        store: VaultStore(directory: dir, native: bridge),
      );
      final transfer = TransferService(
        session: session,
        crypto: crypto,
        native: bridge,
      );
      addTearDown(() {
        transfer.dispose();
        session.dispose();
      });

      // --- setup -----------------------------------------------------------
      await session.load();
      expect(session.phase, SessionPhase.needsSetup);
      await session.setup(localPassword, fixtureRecovery);
      expect(session.phase, SessionPhase.unlocked);
      expect(session.data!.notes, isEmpty);

      // --- write a note through the session --------------------------------
      final note = Note(
        id: session.newNoteId(),
        title: 'Flow note',
        markdown: '# Flow\n\n$marker\n\ncafé 日本語 😀\r\n',
        createdAt: DateTime.utc(2026, 10, 23, 1),
        updatedAt: DateTime.utc(2026, 10, 23, 1),
      );
      await session.saveNote(note);
      await session.flushSave();
      expect(session.data!.notes.single.markdown, note.markdown);

      // --- locked session over the same files ------------------------------
      // A fresh session over the same files is the service-level cold-start
      // case: no key, no notes, only the public recovery questions. The
      // process-level "nothing was persisted" guarantee is covered by
      // test/lock/privacy_lifecycle_test.dart, not here.
      await session.lock();
      expect(session.phase, SessionPhase.locked);

      final reopened = NoteSession(
        crypto: crypto,
        store: VaultStore(directory: dir, native: bridge),
      );
      addTearDown(reopened.dispose);
      await reopened.load();
      expect(reopened.phase, SessionPhase.locked);
      expect(
        reopened.data,
        isNull,
        reason: 'a locked vault hands out no notes',
      );
      expect(reopened.recoveryQuestions, fixtureRecovery.questions);

      // --- unlock ----------------------------------------------------------
      await reopened.unlock(localPassword);
      expect(reopened.phase, SessionPhase.unlocked);
      expect(reopened.data!.notes.single.markdown, note.markdown);
      await reopened.lock();

      // --- recovery replaces the password without losing the note ---------
      await reopened.beginRecovery(fixtureRecovery.answers);
      expect(reopened.phase, SessionPhase.recovering);
      expect(reopened.data, isNull);
      await reopened.completeRecovery(restartedPassword);
      expect(reopened.phase, SessionPhase.unlocked);
      expect(reopened.data!.notes.single.markdown, note.markdown);
      await reopened.lock();

      await expectLater(
        reopened.unlock(localPassword),
        throwsA(
          isA<VaultException>().having(
            (error) => error.code,
            'code',
            FailureCode.credentials,
          ),
        ),
      );
      await reopened.unlock(restartedPassword);
      expect(reopened.data!.notes.single.markdown, note.markdown);

      // --- export through the real transfer service ----------------------
      final exportTransfer = TransferService(
        session: reopened,
        crypto: crypto,
        native: bridge,
      );
      addTearDown(exportTransfer.dispose);
      expect(await exportTransfer.exportNotes(exportPassword), isTrue);
      expect(await exportFile().exists(), isTrue);

      final exportBytes = await exportFile().readAsBytes();
      final asText = utf8.decode(exportBytes, allowMalformed: true);
      expect(asText.contains(marker), isFalse, reason: 'export is ciphertext');
      for (final question in fixtureRecovery.questions) {
        expect(
          asText.contains(question),
          isFalse,
          reason: 'no local recovery material may reach an export',
        );
      }
      // The export opens with its own password only.
      await expectLater(
        crypto.importExport(exportBytes, restartedPassword),
        throwsA(isA<VaultException>()),
      );

      // --- import into a second, independently set-up vault --------------
      final secondDir = uniqueDir('b');
      await secondDir.create(recursive: true);
      addTearDown(() async {
        if (await secondDir.exists()) await secondDir.delete(recursive: true);
      });
      final secondBridge = _ExchangeBridge(importPath: exportFile().path);
      final second = NoteSession(
        crypto: crypto,
        store: VaultStore(directory: secondDir, native: secondBridge),
      );
      final importTransfer = TransferService(
        session: second,
        crypto: crypto,
        native: secondBridge,
      );
      addTearDown(() {
        importTransfer.dispose();
        second.dispose();
      });
      await second.load();
      expect(second.phase, SessionPhase.needsSetup);
      await second.setup(
        secondPassword,
        RecoveryConfig(
          questions: const ['Second pet?', 'Second street?', 'Second school?'],
          answers: const ['Fido', 'Green Road', 'SMA 2'],
        ),
      );

      final picked = await importTransfer.pickImport();
      expect(picked, isNotNull);
      await importTransfer.importPicked(
        picked!,
        exportPassword: exportPassword,
      );
      expect(second.data!.notes.single.title, 'Flow note');
      expect(second.data!.notes.single.markdown, note.markdown);
      expect(
        second.data!.notes.single.id,
        isNot(note.id),
        reason: 'an import gets a fresh local id',
      );

      // The second vault has its own credentials and keeps them.
      await second.lock();
      await second.unlock(secondPassword);
      expect(second.data!.notes.single.markdown, note.markdown);

      // --- hand the artifact to the other platform -----------------------
      // The artifact is printed as base64 so a host that cannot reach the app's
      // private directory (and after `flutter test` uninstalls the app) can
      // still carry it to the other platform. It is ciphertext, and it is
      // removed with this run's directories in tearDownAll.
      final exchangeBytes = await exportFile().readAsBytes();
      // ignore: avoid_print
      print('EXCHANGE_EXPORT=${exportFile().path}');
      // ignore: avoid_print
      print('EXCHANGE_EXPORT_BASE64=${base64Encode(exchangeBytes)}');
      // ignore: avoid_print
      print(
        'EXCHANGE_MARKER=$marker platform=${Platform.operatingSystem} '
        'build=${const bool.fromEnvironment('dart.vm.product')
            ? 'release-AOT'
            : const bool.fromEnvironment('dart.vm.profile')
            ? 'profile-AOT'
            : 'debug-JIT'}',
      );
    },
  );

  testWidgets('no note plaintext is left in the app private directories', (
    tester,
  ) async {
    // Only directories this run created are scanned: the support root also
    // holds a developer's live vault, and the cache root is shared with the
    // real app and other runs.
    final roots = [dir, exchangeDir, cacheDir];
    final needles = [
      marker,
      'Fixture Note Title',
      'Fixture Markdown Body',
      localPassword,
      exportPassword,
      restartedPassword,
    ];
    var scanned = 0;
    for (final root in roots) {
      if (!await root.exists()) continue;
      await for (final entity in root.list(recursive: true)) {
        if (entity is! File) continue;
        // The exchange directory holds the export this test hands to a person;
        // it is ciphertext, and scanning it is still a fair check.
        final bytes = await entity.readAsBytes();
        scanned++;
        final text = utf8.decode(bytes, allowMalformed: true);
        for (final needle in needles) {
          expect(
            text.contains(needle),
            isFalse,
            reason: '${entity.path} must not hold "$needle"',
          );
        }
      }
    }
    expect(scanned, greaterThan(0), reason: 'the vault files exist');
    // ignore: avoid_print
    print('PLAINTEXT_SCAN=ok files=$scanned');
  });

  testWidgets('the bundled notices asset carries third-party text', (
    tester,
  ) async {
    // The test binding disables LicenseRegistry's collector on purpose, so read
    // the asset the real ServicesBinding feeds it from. This proves the licence
    // texts ship inside the running build, not only in the repository.
    final bytes = await rootBundle.load('NOTICES.Z');
    final text = await compute(
      (Uint8List data) => utf8.decode(gzip.decode(data)),
      bytes.buffer.asUint8List(),
    );
    expect(text, contains('Apache License'));
    expect(text, contains('BSD'));
    expect(text, contains('cryptography'));
    expect(text, contains('jni'));
    // ignore: avoid_print
    print('LICENSES=ok chars=${text.length}');
  });

  testWidgets('an export made on the other platform imports here', (
    tester,
  ) async {
    const artifact = String.fromEnvironment('ENCRYNOTE_IMPORT_ARTIFACT');
    if (artifact.isEmpty) {
      // ignore: avoid_print
      print('EXCHANGE_IMPORT=skipped (no ENCRYNOTE_IMPORT_ARTIFACT)');
      return;
    }
    expect(
      exchangedMarker,
      isNotEmpty,
      reason: 'pass ENCRYNOTE_EXPECT_MARKER with the artifact',
    );

    final otherDir = uniqueDir('from_other_platform');
    await otherDir.create(recursive: true);
    addTearDown(() async {
      if (await otherDir.exists()) await otherDir.delete(recursive: true);
    });

    final bridge = _ExchangeBridge(importPath: artifact);
    final session = NoteSession(
      crypto: crypto,
      store: VaultStore(directory: otherDir, native: bridge),
    );
    final transfer = TransferService(
      session: session,
      crypto: crypto,
      native: bridge,
    );
    addTearDown(() {
      transfer.dispose();
      session.dispose();
    });
    await session.load();
    await session.setup(localPassword, fixtureRecovery);

    final picked = await transfer.pickImport();
    expect(picked, isNotNull);
    await transfer.importPicked(picked!, exportPassword: exportPassword);

    final imported = session.data!.notes.single;
    expect(imported.markdown, contains(exchangedMarker));
    expect(imported.title, isNotEmpty);

    // The artifact really is password-protected and has no local vault header.
    final bytes = await File(artifact).readAsBytes();
    final text = utf8.decode(bytes, allowMalformed: true);
    expect(text, contains('"type":"export"'));
    expect(text.contains('"recovery"'), isFalse);
    expect(text.contains('"passwordWrap"'), isFalse);

    await session.lock();
    // ignore: avoid_print
    print('EXCHANGE_IMPORT=ok marker=$exchangedMarker');
  });
}

/// The real native commit channel, with only the OS picker replaced by
/// test-owned files in this run's private directory.
///
/// This is a test double: it proves the flow above the bridge, not the native
/// streaming reader or the real selected-file grant. Those remain covered only
/// by the platform integration suites' unknown-token refusal.
class _ExchangeBridge implements NativeBridge {
  _ExchangeBridge({this.importPath, this.exportPath});

  static const MethodChannelNativeBridge _native = MethodChannelNativeBridge();

  String? importPath;
  String? exportPath;

  @override
  Future<void> commitVault({
    required String stagedPath,
    required String activePath,
    required String previousPath,
  }) => _native.commitVault(
    stagedPath: stagedPath,
    activePath: activePath,
    previousPath: previousPath,
  );

  @override
  Stream<bool> get focusChanges => _native.focusChanges;

  @override
  Future<void> setPrivacyShield(bool visible) =>
      _native.setPrivacyShield(visible);

  @override
  Future<PickedImport?> pickImport() async {
    final path = importPath;
    if (path == null) return null;
    final file = File(path);
    return PickedImport(
      token: path,
      name: file.uri.pathSegments.last,
      length: await file.length(),
    );
  }

  @override
  Future<Uint8List> readImport(String token, {required int maxBytes}) async {
    // Mirrors the native contract: the size is refused before the file is read
    // whole, and the stream stops at the cap. This is a test double, not the
    // real native grant path (which has no automated coverage here).
    final file = File(token);
    if (await file.length() > maxBytes) {
      throw const VaultException(FailureCode.limit, 'read.size');
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in file.openRead()) {
      builder.add(chunk);
      if (builder.length > maxBytes) {
        throw const VaultException(FailureCode.limit, 'read.size');
      }
    }
    return builder.takeBytes();
  }

  @override
  Future<void> releaseImport(String token) async {}

  @override
  Future<bool> saveExport(Uint8List bytes, {required String fileName}) async {
    final path = exportPath;
    if (path == null) return false;
    await File(path).writeAsBytes(bytes, flush: true);
    return true;
  }
}
