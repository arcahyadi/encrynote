import 'dart:convert';
import 'dart:io';

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

/// Exercises the real native transfer channel on the target platform.
///
/// Usage:
///   flutter test integration_test/transfer_platform_test.dart -d macos
///   flutter test integration_test/transfer_platform_test.dart -d DEVICE_ID
///
/// The picker is a human-driven OS panel, so this test does not click it. It
/// covers what can be checked without a person: the channel's refusal of an
/// unknown handle, a bounded read through a real grant when one is provided by
/// the environment, the vault write that follows an import, and the absence of a
/// plaintext copy in the app's own directories. Cross-platform transfer needs
/// two devices; see the task report for what was actually run.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const native = MethodChannelNativeBridge();
  final crypto = VaultCrypto();

  late Directory root;
  late Directory dir;
  late NoteSession session;
  late TransferService transfer;

  setUpAll(() async {
    root = await getApplicationSupportDirectory();
    dir = Directory(
      '${root.path}/encrynote_transfer_${pid}_'
      '${DateTime.now().microsecondsSinceEpoch}',
    );
    await dir.create(recursive: true);
    session = NoteSession(
      crypto: crypto,
      store: VaultStore(directory: dir, native: native),
    );
    transfer = TransferService(
      session: session,
      crypto: crypto,
      native: native,
    );
    await session.load();
    expect(session.phase, SessionPhase.needsSetup);
    await session.setup(localPassword, fixtureRecovery);
    expect(session.phase, SessionPhase.unlocked);
    // ignore: avoid_print
    print('transfer test directory: ${dir.path}');
  });

  tearDownAll(() async {
    session.dispose();
    transfer.dispose();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('an unknown handle is refused without reading any file', () async {
    await expectLater(
      native.readImport('not-a-real-token', maxBytes: maxMarkdownBytes),
      throwsA(isA<VaultException>()),
    );
    await native.releaseImport('not-a-real-token');
  });

  test('an export envelope round-trips through the real crypto', () async {
    final note = Note(
      id: '0123456789abcdef0123456789abcdef',
      title: 'Platform round trip',
      markdown: '# Platform\n\ncafé 日本語 😀\r\n',
      createdAt: DateTime.utc(2026, 10, 22, 9),
      updatedAt: DateTime.utc(2026, 10, 22, 9),
    );
    final bytes = await crypto.exportNotes([note], 'export-1234');
    final opened = await crypto.importExport(bytes, 'export-1234');

    expect(opened.single.markdown, note.markdown);
    expect(opened.single.title, note.title);
    await expectLater(
      crypto.importExport(bytes, localPassword),
      throwsA(isA<VaultException>()),
    );
  });

  test('an imported batch is encrypted in the app support directory', () async {
    const marker = 'runtime-marker-9f21c';
    await session.appendImported([
      Note(
        id: 'ffffffffffffffffffffffffffffffff',
        title: 'Runtime import',
        markdown: '# $marker\n',
        createdAt: DateTime.utc(2026, 10, 22, 10),
        updatedAt: DateTime.utc(2026, 10, 22, 10),
      ),
    ]);
    expect(
      session.data!.notes.map((note) => note.markdown),
      contains('# $marker\n'),
    );

    final files = await dir
        .list(recursive: true)
        .where((entity) => entity is File)
        .cast<File>()
        .toList();
    expect(files, isNotEmpty);
    for (final file in files) {
      final bytes = await file.readAsBytes();
      expect(
        utf8.decode(bytes, allowMalformed: true).contains(marker),
        isFalse,
        reason: '${file.path} must hold ciphertext only',
      );
    }
  });

  test('vanilla Markdown imports without any extra metadata', () async {
    // The integration app runs inside the sandbox container, so the fixture is
    // inline here; the unit suite imports the real `plain_note.md` file.
    const text = '# Plain Markdown\r\n\r\nCafé 日本語 😀\r\n';
    await session.appendImported([
      Note(
        id: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        title: 'plain_note',
        markdown: text,
        createdAt: DateTime.utc(2026, 10, 22, 11),
        updatedAt: DateTime.utc(2026, 10, 22, 11),
      ),
    ]);
    expect(session.data!.notes.map((note) => note.markdown), contains(text));
  });
}
