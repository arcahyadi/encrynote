import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hello_flutter/platform/native_bridge.dart';
import 'package:hello_flutter/session/note_session.dart';
import 'package:hello_flutter/transfer/transfer_service.dart';
import 'package:hello_flutter/vault/vault_crypto.dart';
import 'package:hello_flutter/vault/vault_store.dart';
import 'package:hello_flutter/vault/vault_types.dart';

import '../support/fake_native_bridge.dart';
import '../support/fixtures.dart';
import '../support/seal_failure_crypto.dart';

Matcher _rejectedAs(FailureCode code) =>
    throwsA(isA<VaultException>().having((e) => e.code, 'code', code));

/// Transfer service tests: export prepares ciphertext before the native save,
/// and an import batch is one atomic vault commit that never becomes a retry.
void main() {
  final crypto = VaultCrypto();
  late Uint8List seed;
  late Directory dir;
  late FakeNativeBridge native;
  late NoteSession session;
  late TransferService transfer;
  var scratch = 0;

  setUpAll(() async {
    seed = (await crypto.createVault(
      localPassword,
      fixtureRecovery,
      fixtureData,
    )).envelope;
  });

  setUp(() async {
    scratch++;
    dir = await Directory(
      '${Directory.current.path}/.dart_tool/test_scratch/transfer/'
      '${DateTime.now().microsecondsSinceEpoch}_$scratch',
    ).create(recursive: true);
    native = FakeNativeBridge();
    session = NoteSession(
      crypto: crypto,
      store: VaultStore(directory: dir, native: native),
    );
    transfer = TransferService(
      session: session,
      crypto: crypto,
      native: native,
    );
    await File('${dir.path}/vault.enc').writeAsBytes(seed, flush: true);
    await session.load();
    await session.unlock(localPassword);
  });

  tearDown(() async {
    session.dispose();
    transfer.dispose();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Note noteTitled(String title) =>
      session.data!.notes.firstWhere((note) => note.title == title);

  PickedImport picked({
    String token = 'token-1',
    String name = 'note.md',
    int? length,
  }) => PickedImport(token: token, name: name, length: length);

  group('export', () {
    test('saves only a fresh encrypted export envelope', () async {
      expect(await transfer.exportNotes('export-1234'), isTrue);

      expect(native.savedFileName, endsWith('.encrynote'));
      expect(native.savedFileName, isNot(contains('/')));
      final bytes = native.savedExport!;
      expect(
        utf8
            .decode(bytes, allowMalformed: true)
            .contains(fixtureData.notes.single.markdown),
        isFalse,
      );
      expect(bytes.length, lessThanOrEqualTo(maxEnvelopeBytes));

      final notes = await crypto.importExport(bytes, 'export-1234');
      expect(notes.single.markdown, fixtureData.notes.single.markdown);
      await expectLater(
        crypto.importExport(bytes, localPassword),
        _rejectedAs(FailureCode.credentials),
      );
    });

    test('flushes the last keystroke into the exported snapshot', () async {
      final commits = native.commitCount;
      await session.saveNote(
        session.data!.notes.single.copyWith(markdown: '# last keystroke'),
      );

      expect(await transfer.exportNotes('export-1234'), isTrue);

      expect(native.commitCount, greaterThan(commits));
      final exported = await crypto.importExport(
        native.savedExport!,
        'export-1234',
      );
      expect(exported.single.markdown, '# last keystroke');
    });

    test(
      'a short export password is rejected before any native call',
      () async {
        await expectLater(
          transfer.exportNotes('short'),
          _rejectedAs(FailureCode.credentials),
        );
        expect(native.savedExport, isNull);
      },
    );

    test('a frozen session cannot export', () async {
      final sealCrypto = SealFailureCrypto();
      final frozen = NoteSession(
        crypto: sealCrypto,
        store: VaultStore(directory: dir, native: native),
      );
      final frozenTransfer = TransferService(
        session: frozen,
        crypto: sealCrypto,
        native: native,
      );
      addTearDown(frozen.dispose);
      addTearDown(frozenTransfer.dispose);
      await frozen.load();
      await frozen.unlock(localPassword);

      sealCrypto.failSeal = true;
      await expectLater(
        frozen.saveNote(
          frozen.data!.notes.single.copyWith(markdown: '# unsealed'),
        ),
        throwsA(isA<VaultException>()),
      );

      await expectLater(
        frozenTransfer.exportNotes('export-1234'),
        _rejectedAs(FailureCode.busy),
      );
      expect(native.savedExport, isNull);
    });

    test(
      'a lock during the flush aborts before preparing ciphertext',
      () async {
        native.holdAt = CommitStage.fileSync;
        final save = session.saveNote(
          session.data!.notes.single.copyWith(markdown: '# racing'),
        );
        Object? exportError;
        final export = transfer
            .exportNotes('export-1234')
            .then<void>((_) {}, onError: (Object error) => exportError = error);

        await native.entered.future;
        final lock = session.lock();
        native.release();
        await save;
        await lock;
        await export;

        expect(exportError, isA<VaultException>());
        expect((exportError! as VaultException).code, FailureCode.busy);
        expect(native.savedExport, isNull);
      },
    );

    test('a lock after the ciphertext is ready still saves it', () async {
      native.saveGate = Completer<void>();
      final export = transfer.exportNotes('export-1234');
      while (native.savedExport == null) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      await session.lock();
      expect(session.phase, SessionPhase.locked);
      native.saveGate!.complete();

      expect(await export, isTrue);
      final bytes = native.savedExport!;
      expect(
        (await crypto.importExport(bytes, 'export-1234')).single.markdown,
        fixtureData.notes.single.markdown,
      );
    });

    test('a cancelled native save is reported as not saved', () async {
      native.saveResult = false;
      expect(await transfer.exportNotes('export-1234'), isFalse);
      expect(
        session.data!.notes.single.markdown,
        fixtureData.notes.single.markdown,
      );
    });

    test('a native save failure surfaces without changing notes', () async {
      native.failSave = true;
      await expectLater(
        transfer.exportNotes('export-1234'),
        _rejectedAs(FailureCode.storage),
      );
      expect(session.data!.notes.single.title, fixtureData.notes.single.title);
      expect(session.canMutate, isTrue);
    });
  });

  group('import pick', () {
    test('a cancelled picker is not an error and keeps no handle', () async {
      native.nextPicked = null;
      expect(await transfer.pickImport(), isNull);
      expect(transfer.pendingImport, isNull);
      expect(native.pickCalls, 1);
    });

    test('the pending handle is kept by the service', () async {
      native.nextPicked = picked(token: 'abc', name: 'raw.md');
      final result = await transfer.pickImport();

      expect(result?.token, 'abc');
      expect(transfer.pendingImport?.token, 'abc');
      expect(transfer.pendingImport?.name, 'raw.md');
    });

    test('a pick while locked opens no native picker', () async {
      await session.lock();
      await expectLater(transfer.pickImport(), _rejectedAs(FailureCode.busy));
      expect(native.pickCalls, 0);
    });

    test('cancel releases the pending handle without touching notes', () async {
      native.nextPicked = picked(token: 'abc');
      await transfer.pickImport();

      await transfer.cancelImport();

      expect(native.released, ['abc']);
      expect(transfer.pendingImport, isNull);
      expect(session.data!.notes, hasLength(1));
      expect(native.commitCount, 0);
    });

    test('a newer pick releases the older handle', () async {
      native.nextPicked = picked(token: 'first');
      await transfer.pickImport();
      native.nextPicked = picked(token: 'second');
      await transfer.pickImport();

      expect(native.released, ['first']);
      expect(transfer.pendingImport?.token, 'second');
    });

    test('cancel is idempotent and releases a handle once', () async {
      native.nextPicked = picked(token: 'once');
      await transfer.pickImport();

      await transfer.cancelImport();
      await transfer.cancelImport();
      // Dispose is the last path that could release the same handle again.
      transfer.dispose();
      // Recreate so tearDown's own dispose stays valid.
      transfer = TransferService(
        session: session,
        crypto: crypto,
        native: native,
      );

      expect(native.released, ['once']);
    });

    test(
      'a cancel mid-read stops the batch before it reaches the session',
      () async {
        native.nextPicked = picked(token: 'slow', name: 'slow.md');
        native.importBytes = Uint8List.fromList(utf8.encode('slow body'));
        native.readGate = Completer<void>();
        final handle = await transfer.pickImport();

        final importing = transfer.importPicked(handle!);
        // The read is parked, so the operation is still cancellable.
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(transfer.importStage, ImportStage.reading);
        await transfer.cancelImport();
        native.readGate!.complete();

        await expectLater(importing, _rejectedAs(FailureCode.busy));
        expect(session.data!.notes, hasLength(1));
        expect(native.commitCount, 0);
        expect(native.released, ['slow']);
        expect(transfer.pendingImport, isNull);
        expect(transfer.importStage, ImportStage.idle);
      },
    );

    test('a cancel cannot interrupt the vault commit stage', () async {
      native.nextPicked = picked(token: 'committing', name: 'c.md');
      native.importBytes = Uint8List.fromList(utf8.encode('commit body'));
      native.holdAt = CommitStage.fileSync;
      final handle = await transfer.pickImport();

      final importing = transfer.importPicked(handle!);
      for (var i = 0; i < 200 && !native.entered.isCompleted; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(native.entered.isCompleted, isTrue);
      expect(transfer.importStage, ImportStage.committing);

      await transfer.cancelImport();
      expect(native.released, isEmpty, reason: 'nothing cancelled mid-commit');

      native.release();
      await importing;

      expect(
        session.data!.notes.map((note) => note.markdown),
        contains('commit body'),
      );
      expect(native.released, ['committing']);
      expect(transfer.importStage, ImportStage.idle);
    });
  });

  group('markdown import', () {
    test(
      'keeps BOM-stripped CRLF and emoji, and titles from basename',
      () async {
        native.nextPicked = picked(
          token: 'md',
          name: '../../private/secret/My Note.md',
        );
        native.importBytes = Uint8List.fromList([
          0xEF,
          0xBB,
          0xBF,
          ...utf8.encode('line one\r\n😀 line two\r\n'),
        ]);

        final handle = await transfer.pickImport();
        await transfer.importPicked(handle!);

        expect(session.data!.notes, hasLength(2));
        final imported = noteTitled('My Note');
        expect(imported.markdown, 'line one\r\n😀 line two\r\n');
        expect(native.readLimits.single, maxMarkdownBytes);
        expect(native.released, ['md']);
        expect(transfer.pendingImport, isNull);
      },
    );

    test('an unknown length is read through a bounded stream', () async {
      native.nextPicked = picked(token: 'md', name: 'plain.md', length: null);
      native.importBytes = Uint8List.fromList(utf8.encode('body'));
      final handle = await transfer.pickImport();

      await transfer.importPicked(handle!);

      expect(noteTitled('plain').markdown, 'body');
      expect(native.readLimits.single, maxMarkdownBytes);
    });

    test('an empty markdown file becomes an Untitled note', () async {
      native.nextPicked = picked(token: 'md', name: '.md');
      native.importBytes = Uint8List(0);
      final handle = await transfer.pickImport();

      await transfer.importPicked(handle!);

      final imported = noteTitled('Untitled');
      expect(imported.markdown, isEmpty);
    });

    test('a stream over the markdown limit changes nothing', () async {
      native.nextPicked = picked(token: 'md', name: 'big.md');
      native.importBytes = Uint8List(maxMarkdownBytes + 1);
      final handle = await transfer.pickImport();
      final commits = native.commitCount;

      await expectLater(
        transfer.importPicked(handle!),
        _rejectedAs(FailureCode.limit),
      );

      expect(session.data!.notes, hasLength(1));
      expect(native.commitCount, commits);
      expect(native.released, ['md']);
      expect(transfer.pendingImport, isNull);
    });

    test('invalid UTF-8 is rejected as a format error', () async {
      native.nextPicked = picked(token: 'md', name: 'bad.md');
      native.importBytes = Uint8List.fromList([0xC3, 0x28]);
      final handle = await transfer.pickImport();

      await expectLater(
        transfer.importPicked(handle!),
        _rejectedAs(FailureCode.format),
      );
      expect(session.data!.notes, hasLength(1));
      expect(native.released, ['md']);
    });

    test('an unsupported extension is refused and released', () async {
      native.nextPicked = picked(token: 'txt', name: 'note.txt');
      final handle = await transfer.pickImport();

      await expectLater(
        transfer.importPicked(handle!),
        _rejectedAs(FailureCode.unsupported),
      );
      expect(native.readTokens, isEmpty);
      expect(native.released, ['txt']);
    });

    test('the vanilla .md fixture imports with no added metadata', () async {
      final fixture = File('test/fixtures/plain_note.md');
      final bytes = await fixture.readAsBytes();
      native.nextPicked = picked(token: 'fixture', name: 'plain_note.md');
      native.importBytes = bytes;
      final handle = await transfer.pickImport();

      await transfer.importPicked(handle!);

      final imported = noteTitled('plain_note');
      expect(imported.markdown, utf8.decode(bytes));
      expect(imported.markdown, contains('café'));
      expect(imported.markdown, isNot(contains('---')));
      expect(await fixture.readAsBytes(), bytes, reason: 'source is untouched');
    });

    test('no plaintext copy appears in the app support directory', () async {
      const marker = 'runtime-plaintext-marker-7f3a';
      native.nextPicked = picked(token: 'md', name: 'marker.md');
      native.importBytes = Uint8List.fromList(utf8.encode('# $marker\n'));
      final handle = await transfer.pickImport();
      await transfer.importPicked(handle!);

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
  });

  group('export import', () {
    test('adds the batch under fresh ids and keeps duplicates', () async {
      final bytes = await crypto.exportNotes(fixtureData.notes, 'export-1234');
      native.nextPicked = picked(
        token: 'enc',
        name: 'notes.encrynote',
        length: bytes.length,
      );
      native.importBytes = bytes;
      final handle = await transfer.pickImport();

      await transfer.importPicked(handle!, exportPassword: 'export-1234');

      expect(session.data!.notes, hasLength(2));
      final imported = session.data!.notes.last;
      expect(imported.id, isNot(fixtureData.notes.single.id));
      expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(imported.id), isTrue);
      expect(imported.markdown, fixtureData.notes.single.markdown);
      expect(native.readLimits.single, maxEnvelopeBytes);

      // Importing the same file again duplicates instead of overwriting.
      native.nextPicked = picked(
        token: 'enc2',
        name: 'notes.encrynote',
        length: bytes.length,
      );
      final again = await transfer.pickImport();
      await transfer.importPicked(again!, exportPassword: 'export-1234');

      expect(session.data!.notes, hasLength(3));
      expect(session.data!.notes.map((note) => note.id).toSet(), hasLength(3));
    });

    test(
      'a wrong export password changes nothing and leaves no retry',
      () async {
        final bytes = await crypto.exportNotes(
          fixtureData.notes,
          'export-1234',
        );
        native.nextPicked = picked(token: 'enc', name: 'notes.encrynote');
        native.importBytes = bytes;
        final handle = await transfer.pickImport();
        final commits = native.commitCount;

        await expectLater(
          transfer.importPicked(handle!, exportPassword: localPassword),
          _rejectedAs(FailureCode.credentials),
        );

        expect(session.data!.notes, hasLength(1));
        expect(session.canMutate, isTrue);
        expect(native.released, ['enc']);
        expect(transfer.pendingImport, isNull);

        // Neither an autosave flush nor a resume can write the failed batch.
        await session.flushSave();
        expect(native.commitCount, commits);
        await session.lock();
        await session.unlock(localPassword);
        expect(session.data!.notes, hasLength(1));
      },
    );

    test('a missing export password is refused before reading', () async {
      native.nextPicked = picked(token: 'enc', name: 'notes.encrynote');
      final handle = await transfer.pickImport();

      await expectLater(
        transfer.importPicked(handle!),
        _rejectedAs(FailureCode.credentials),
      );
      expect(native.readTokens, isEmpty);
      expect(native.released, ['enc']);
    });

    test(
      'a read failure keeps existing notes and releases the handle',
      () async {
        native.nextPicked = picked(token: 'enc', name: 'notes.encrynote');
        native.failRead = true;
        final handle = await transfer.pickImport();
        final commits = native.commitCount;

        await expectLater(
          transfer.importPicked(handle!, exportPassword: 'export-1234'),
          _rejectedAs(FailureCode.storage),
        );

        expect(session.data!.notes, hasLength(1));
        expect(session.canMutate, isTrue);
        expect(native.commitCount, commits);
        expect(native.released, ['enc']);
        expect(transfer.pendingImport, isNull);
      },
    );

    test('an import while locked reads nothing', () async {
      final handle = picked(token: 'enc', name: 'notes.encrynote');
      await session.lock();

      await expectLater(
        transfer.importPicked(handle, exportPassword: 'export-1234'),
        _rejectedAs(FailureCode.busy),
      );
      expect(native.readTokens, isEmpty);
    });
  });

  group('atomic batch', () {
    Note importedNote() => Note(
      id: 'dddddddddddddddddddddddddddddddd',
      title: 'Batch',
      markdown: 'batch body',
      createdAt: DateTime.utc(2026, 10, 22, 13),
      updatedAt: DateTime.utc(2026, 10, 22, 13),
    );

    test('a failed commit restores the previous snapshot', () async {
      native.failNextCommit = true;

      await expectLater(
        session.appendImported([importedNote()]),
        throwsA(isA<VaultException>()),
      );

      expect(session.data!.notes, hasLength(1));
      expect(session.canMutate, isTrue);
      expect(session.phase, SessionPhase.unlocked);

      // The rejected batch must not ride an autosave retry.
      final commits = native.commitCount;
      await session.flushSave();
      expect(native.commitCount, commits);

      await session.lock();
      await session.unlock(localPassword);
      expect(session.data!.notes, hasLength(1));
      expect(native.commitCount, commits);
    });

    test(
      'an uncertain commit freezes and reconciles the real outcome',
      () async {
        native.failAt = CommitStage.fileSync;
        native.rollbackFails = true;

        await expectLater(
          session.appendImported([importedNote()]),
          throwsA(isA<VaultException>()),
        );

        expect(session.canMutate, isFalse);
        expect(session.phase, SessionPhase.storageError);
        expect(session.holdsSensitiveState, isTrue);

        native.rollbackFails = false;
        await session.retrySave();

        expect(session.phase, SessionPhase.unlocked);
        expect(session.data!.notes, hasLength(2));
        expect(
          session.data!.notes.map((note) => note.title),
          contains('Batch'),
        );
      },
    );

    test('a lock that lands on a failed import ends locked and safe', () async {
      native.failEveryCommit = true;
      final import = session.appendImported([importedNote()]);
      final lock = session.lock();

      await expectLater(import, throwsA(isA<VaultException>()));
      await lock;

      expect(session.phase, SessionPhase.locked);
      expect(session.holdsSensitiveState, isFalse);

      native.failEveryCommit = false;
      await session.unlock(localPassword);
      expect(session.data!.notes, hasLength(1));
      final commits = native.commitCount;
      await session.flushSave();
      expect(native.commitCount, commits, reason: 'no batch survived the lock');
    });

    test(
      'a retry that already committed the batch is not reported failed',
      () async {
        // The first commit fails, the queued lock's flush retries it: the bytes
        // are durable, so the import must not claim a failure it cannot prove.
        native.failNextCommit = true;
        final import = session.appendImported([importedNote()]);
        final lock = session.lock();

        await import;
        await lock;

        expect(session.phase, SessionPhase.locked);
        await session.unlock(localPassword);
        expect(
          session.data!.notes.map((note) => note.title),
          contains('Batch'),
          reason: 'the retried commit is the durable outcome',
        );
      },
    );

    test(
      'a batch over the snapshot limit is rejected before any write',
      () async {
        final commits = native.commitCount;

        await expectLater(
          session.appendImported([
            Note(
              id: 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
              title: 'Huge',
              markdown: 'x' * (maxPayloadBytes + 1),
              createdAt: DateTime.utc(2026, 10, 22),
              updatedAt: DateTime.utc(2026, 10, 22),
            ),
          ]),
          _rejectedAs(FailureCode.limit),
        );

        expect(session.data!.notes, hasLength(1));
        expect(session.canMutate, isTrue);
        expect(native.commitCount, commits);
      },
    );
  });
}
