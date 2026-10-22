import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hello_flutter/session/note_session.dart';
import 'package:hello_flutter/vault/vault_crypto.dart';
import 'package:hello_flutter/vault/vault_store.dart';
import 'package:hello_flutter/vault/vault_types.dart';

import '../support/fake_native_bridge.dart';
import '../support/fixtures.dart';

Matcher _rejectedAs(FailureCode code) =>
    throwsA(isA<VaultException>().having((e) => e.code, 'code', code));

/// Test-only seal gate: holds the expensive seal so a second edit can land
/// between the payload capture and the sealed bytes.
class _GatedCrypto extends VaultCrypto {
  Completer<void>? gate;
  final Completer<void> entered = Completer<void>();

  @override
  Future<Uint8List> seal(
    UnlockedVault vault,
    VaultData data,
    int revision,
  ) async {
    final open = gate;
    if (open != null) {
      if (!entered.isCompleted) entered.complete();
      await open.future;
    }
    return super.seal(vault, data, revision);
  }
}

/// Session tests keep scratch files inside the project and only delete the
/// directory this test created. The encrypted seed is created once.
void main() {
  final crypto = VaultCrypto();
  late Uint8List seed;
  late Directory dir;
  late FakeNativeBridge native;
  late VaultStore store;
  late NoteSession session;
  late Completer<void> gateEntered;
  late Completer<void> gateRelease;
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
      '${Directory.current.path}/.dart_tool/test_scratch/note_session/'
      '${DateTime.now().microsecondsSinceEpoch}_$scratch',
    ).create(recursive: true);
    native = FakeNativeBridge();
    store = VaultStore(directory: dir, native: native);
    session = NoteSession(crypto: crypto, store: store);
  });

  tearDown(() async {
    session.dispose();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<void> seedVault() =>
      File('${dir.path}/vault.enc').writeAsBytes(seed, flush: true);

  Future<void> unlockSeeded() async {
    await seedVault();
    await session.load();
    await session.unlock(localPassword);
  }

  Note editedNote(String markdown) =>
      session.data!.notes.single.copyWith(markdown: markdown);

  test('load without a vault asks for setup', () async {
    await session.load();
    expect(session.phase, SessionPhase.needsSetup);
    expect(session.data, isNull);
    expect(session.recoveryQuestions, isEmpty);
    expect(session.canMutate, isFalse);
  });

  test('load with a vault stays locked and exposes only questions', () async {
    await seedVault();
    await session.load();
    expect(session.phase, SessionPhase.locked);
    expect(session.data, isNull);
    expect(session.recoveryQuestions, fixtureRecovery.questions);
    expect(session.canMutate, isFalse);
  });

  test('a failed load can be retried by loading again', () async {
    await File('${dir.path}/vault.enc').writeAsString('not a vault');
    await expectLater(session.load(), throwsA(isA<VaultException>()));
    expect(session.phase, SessionPhase.storageError);
    expect(
      session.needsReload,
      isTrue,
      reason: 'a load failure must ask for a reload, not a save retry',
    );
    expect(session.data, isNull);

    await File('${dir.path}/vault.enc').writeAsBytes(seed, flush: true);
    await session.load();

    expect(session.needsReload, isFalse);
    expect(session.phase, SessionPhase.locked);
    expect(session.recoveryQuestions, fixtureRecovery.questions);
  });

  test('retrySave refuses a load failure instead of doing nothing', () async {
    await File('${dir.path}/vault.enc').writeAsString('not a vault');
    await expectLater(session.load(), throwsA(isA<VaultException>()));

    await expectLater(
      session.retrySave(),
      _rejectedAs(FailureCode.storage),
      reason: 'a no-op retry would look like a successful recovery',
    );
    expect(session.phase, SessionPhase.storageError);
    expect(session.needsReload, isTrue);
  });

  test('lock keeps a load failure on its retry screen', () async {
    await File('${dir.path}/vault.enc').writeAsString('not a vault');
    await expectLater(session.load(), throwsA(isA<VaultException>()));

    await session.lock();

    expect(
      session.phase,
      SessionPhase.storageError,
      reason: 'locking would hide the only way to retry the load',
    );
    expect(session.needsReload, isTrue);
  });

  test('a failed save asks for a save retry, not a reload', () async {
    await unlockSeeded();
    native.failNextCommit = true;
    await expectLater(
      session.saveNote(editedNote('edited body')),
      throwsA(isA<VaultException>()),
    );

    expect(session.phase, SessionPhase.storageError);
    expect(session.needsReload, isFalse);
    expect(session.data, isNotNull, reason: 'frozen data stays readable');
    expect(
      session.holdsSensitiveState,
      isTrue,
      reason: 'the retry still needs the key and the frozen notes',
    );
    expect(
      session.canMutate,
      isFalse,
      reason: 'readable frozen data is not permission to edit',
    );

    await session.retrySave();
    expect(session.phase, SessionPhase.unlocked);
    expect(session.data!.notes.single.markdown, 'edited body');
  });

  test('setup is only complete after the commit point', () async {
    await session.load();
    native.holdAt = CommitStage.fileSync;
    final setup = session.setup(localPassword, fixtureRecovery);
    await native.entered.future;

    expect(session.phase, isNot(SessionPhase.unlocked));
    expect(session.isBusy, isTrue);
    expect(session.data, isNull);

    native.release();
    await setup;

    expect(session.phase, SessionPhase.unlocked);
    expect(session.data!.notes, isEmpty);
    expect(session.canMutate, isTrue);
    expect(await File('${dir.path}/vault.enc').exists(), isTrue);
  });

  test('a failed setup commit leaves the install unconfigured', () async {
    await session.load();
    // The first commit has no active file to back up, so fail at replace.
    native.failAt = CommitStage.replace;
    await expectLater(
      session.setup(localPassword, fixtureRecovery),
      throwsA(isA<VaultException>()),
    );
    expect(session.phase, SessionPhase.needsSetup);
    expect(session.data, isNull);
    expect(await File('${dir.path}/vault.enc').exists(), isFalse);
  });

  test('lock drops data from the session state', () async {
    await unlockSeeded();
    expect(session.data!.notes.single.id, fixtureData.notes.single.id);

    await session.lock();
    expect(session.phase, SessionPhase.locked);
    expect(session.data, isNull);
    expect(session.canMutate, isFalse);
  });

  test('flushSave writes the last accepted edit before the debounce', () async {
    await unlockSeeded();
    final save = session.saveNote(editedNote('last keystroke'));

    expect(native.commitCount, 0);
    await session.flushSave();
    await save;

    expect(native.commitCount, 1);
    expect(session.data!.notes.single.markdown, 'last keystroke');
    expect(session.phase, SessionPhase.unlocked);

    // Nothing accepted is waiting, so a second flush writes nothing.
    await session.flushSave();
    expect(native.commitCount, 1);
  });

  test('flushSave is a no-op once the session is locked', () async {
    await unlockSeeded();
    final save = session.saveNote(editedNote('locked flush'));
    await session.lock();
    await save;

    final commits = native.commitCount;
    await session.flushSave();
    expect(native.commitCount, commits);
    expect(session.data, isNull);
  });

  test('newNoteId returns a fresh 32-character hex id', () {
    final first = session.newNoteId();
    final second = session.newNoteId();
    expect(first, matches(RegExp(r'^[0-9a-f]{32}$')));
    expect(second, matches(RegExp(r'^[0-9a-f]{32}$')));
    expect(first, isNot(second));
  });

  test('debounced autosave coalesces edits into one commit', () async {
    await unlockSeeded();
    final first = session.saveNote(editedNote('first edit'));
    final second = session.saveNote(editedNote('second edit'));

    expect(native.commitCount, 0);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(native.commitCount, 0, reason: 'still inside the debounce window');

    await Future.wait<void>([first, second]);
    expect(native.commitCount, 1);
    expect(session.data!.notes.single.markdown, 'second edit');

    final onDisk = await crypto.unlock((await store.read())!, localPassword);
    expect(onDisk.data.notes.single.markdown, 'second edit');
  });

  test('failed save keeps its sealed snapshot authoritative', () async {
    await unlockSeeded();
    final edited = editedNote('edited body');

    native.failNextCommit = true;
    await expectLater(session.saveNote(edited), throwsA(isA<VaultException>()));
    expect(session.canMutate, isFalse);
    expect(session.phase, SessionPhase.storageError);

    // The final lock attempt fails too, so only the sealed ciphertext survives.
    native.failNextCommit = true;
    await session.lock();
    expect(session.data, isNull);

    final commitsBeforeUnlock = native.commitCount;
    await session.unlock(localPassword);
    expect(
      native.commitCount,
      greaterThan(commitsBeforeUnlock),
      reason: 'unlock reconciles the pending snapshot before opening',
    );
    expect(session.data!.notes.single.markdown, 'edited body');

    await session.retrySave();
    expect(session.data!.notes.single.markdown, 'edited body');
  });

  test('lock flushes the last keystroke before the debounce fires', () async {
    await unlockSeeded();
    final save = session.saveNote(editedNote('last keystroke'));

    await session.lock();
    await save;

    expect(native.commitCount, 1);
    expect(session.data, isNull);

    await session.unlock(localPassword);
    expect(session.data!.notes.single.markdown, 'last keystroke');
  });

  test('a late save completion cannot revive a locked session', () async {
    await unlockSeeded();
    native.holdAt = CommitStage.fileSync;
    final imported = session.appendImported([
      Note(
        id: 'ffffffffffffffffffffffffffffffff',
        title: 'Imported',
        markdown: 'imported body',
        createdAt: DateTime.utc(2026, 10, 22, 11),
        updatedAt: DateTime.utc(2026, 10, 22, 11),
      ),
    ]);
    await native.entered.future;

    final lock = session.lock();
    expect(session.data, isNull, reason: 'data is hidden before the await');
    native.release();

    await imported;
    await lock;
    expect(session.phase, SessionPhase.locked);
    expect(session.data, isNull);

    await session.unlock(localPassword);
    expect(session.data!.notes.length, 2);
  });

  test('recovery replaces the password without changing content', () async {
    await seedVault();
    await session.load();

    await session.beginRecovery(fixtureRecovery.answers);
    expect(session.phase, SessionPhase.recovering);
    expect(session.data, isNull, reason: 'recovery does not open notes');
    expect(session.recoveryQuestions, fixtureRecovery.questions);

    await session.completeRecovery('new-pass-9999');
    expect(session.phase, SessionPhase.unlocked);
    expect(
      session.data!.notes.single.markdown,
      fixtureData.notes.single.markdown,
    );

    await session.lock();
    await expectLater(
      session.unlock(localPassword),
      _rejectedAs(FailureCode.credentials),
    );
    await session.unlock('new-pass-9999');
    expect(session.data!.notes.single.id, fixtureData.notes.single.id);
  });

  test('a failed recovery commit keeps the original credentials', () async {
    await seedVault();
    await session.load();
    await session.beginRecovery(fixtureRecovery.answers);

    native.failNextCommit = true;
    await expectLater(
      session.completeRecovery('new-pass-9999'),
      throwsA(isA<VaultException>()),
    );
    expect(session.phase, SessionPhase.recovering);
    expect(session.data, isNull);

    await session.lock();
    await session.unlock(localPassword);
    expect(session.data, isNotNull);

    await session.lock();
    await expectLater(
      session.unlock('new-pass-9999'),
      _rejectedAs(FailureCode.credentials),
    );
  });

  test('retry cannot restore the old password after recovery', () async {
    await unlockSeeded();
    native.failNextCommit = true;
    await expectLater(
      session.saveNote(editedNote('before recovery')),
      throwsA(isA<VaultException>()),
    );
    await session.lock();

    await session.beginRecovery(fixtureRecovery.answers);
    await session.completeRecovery('new-pass-9999');
    await session.retrySave();

    await session.lock();
    await expectLater(
      session.unlock(localPassword),
      _rejectedAs(FailureCode.credentials),
    );
    await session.unlock('new-pass-9999');
    expect(session.data!.notes.single.markdown, 'before recovery');
  });

  test('recovery reconciles a pending snapshot before re-wrapping', () async {
    await unlockSeeded();
    native.failNextCommit = true;
    await expectLater(
      session.saveNote(editedNote('recovered edit')),
      throwsA(isA<VaultException>()),
    );
    native.failNextCommit = true;
    await session.lock();

    await session.beginRecovery(fixtureRecovery.answers);
    expect(session.phase, SessionPhase.recovering);
    expect(session.data, isNull);

    await session.completeRecovery('new-pass-9999');
    expect(session.data!.notes.single.markdown, 'recovered edit');

    await session.lock();
    await expectLater(
      session.unlock(localPassword),
      _rejectedAs(FailureCode.credentials),
    );
    await session.unlock('new-pass-9999');
    expect(session.data!.notes.single.markdown, 'recovered edit');
  });

  test('a snapshot over the payload limit is rejected unchanged', () async {
    await unlockSeeded();
    final huge = editedNote('a' * (maxPayloadBytes + 1));

    await expectLater(session.saveNote(huge), _rejectedAs(FailureCode.limit));
    expect(session.data!.notes.single.markdown, isNot(huge.markdown));
    expect(session.canMutate, isTrue);
    expect(native.commitCount, 0);

    await expectLater(
      session.appendImported([
        Note(
          id: 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
          title: 'Huge import',
          markdown: 'b' * (maxPayloadBytes + 1),
          createdAt: DateTime.utc(2026, 10, 22, 12),
          updatedAt: DateTime.utc(2026, 10, 22, 12),
        ),
      ]),
      _rejectedAs(FailureCode.limit),
    );
    expect(session.data!.notes.length, 1);
    expect(native.commitCount, 0);
  });

  test('import appends notes with new local ids in one commit', () async {
    await unlockSeeded();
    final source = Note(
      id: 'dddddddddddddddddddddddddddddddd',
      title: 'Imported Title',
      markdown: 'Imported body',
      createdAt: DateTime.utc(2026, 10, 22, 13),
      updatedAt: DateTime.utc(2026, 10, 22, 13),
    );

    await session.appendImported([source]);

    expect(native.commitCount, 1);
    expect(session.data!.notes.length, 2);
    final imported = session.data!.notes.last;
    expect(imported.id, isNot(source.id));
    expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(imported.id), isTrue);
    expect(imported.title, 'Imported Title');
    expect(imported.markdown, 'Imported body');
  });

  test('an uncertain commit is reconciled from disk on retry', () async {
    await unlockSeeded();
    native.failAt = CommitStage.fileSync;
    native.rollbackFails = true;
    await expectLater(
      session.saveNote(editedNote('uncertain edit')),
      throwsA(
        isA<VaultException>()
            .having((e) => e.code, 'code', FailureCode.storage)
            .having((e) => e.detail, 'detail', 'commit.uncertain'),
      ),
    );
    expect(session.canMutate, isFalse);

    native.rollbackFails = false;
    await session.retrySave();
    expect(session.canMutate, isTrue);
    expect(session.data!.notes.single.markdown, 'uncertain edit');
    expect(native.commitCount, 1, reason: 'the write already landed');

    await session.lock();
    await session.unlock(localPassword);
    expect(session.data!.notes.single.markdown, 'uncertain edit');
  });

  test('an edit accepted while a commit is in flight is not lost', () async {
    await unlockSeeded();
    native.holdAt = CommitStage.fileSync;
    final first = session.saveNote(editedNote('first'));
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await native.entered.future;

    final second = session.saveNote(editedNote('second'));
    native.release();
    await Future.wait<void>([first, second]);

    expect(session.data!.notes.single.markdown, 'second');
    final onDisk = await crypto.unlock((await store.read())!, localPassword);
    expect(onDisk.data.notes.single.markdown, 'second');
  });

  test('a wrong password never writes the pending snapshot', () async {
    await unlockSeeded();
    native.failNextCommit = true;
    await expectLater(
      session.saveNote(editedNote('unwritten')),
      throwsA(isA<VaultException>()),
    );
    native.failNextCommit = true;
    await session.lock();
    final commitsBefore = native.commitCount;

    await expectLater(
      session.unlock('wrong-pass-1234'),
      _rejectedAs(FailureCode.credentials),
    );
    expect(native.commitCount, commitsBefore);

    // The committed credential still opens and reconciles the snapshot.
    await session.unlock(localPassword);
    expect(session.data!.notes.single.markdown, 'unwritten');
  });

  test('delete and auto-lock changes commit through the same queue', () async {
    await unlockSeeded();
    await session.setAutoLock(AutoLockMode.tenMinutes);
    expect(session.data!.autoLock, AutoLockMode.tenMinutes);

    await session.deleteNote(fixtureData.notes.single.id);
    expect(session.data!.notes, isEmpty);

    final onDisk = await crypto.unlock((await store.read())!, localPassword);
    expect(onDisk.data.notes, isEmpty);
    expect(onDisk.data.autoLock, AutoLockMode.tenMinutes);
  });

  test('the saved auto-lock policy survives lock and recovery', () async {
    await unlockSeeded();
    await session.setAutoLock(AutoLockMode.immediately);
    await session.lock();
    expect(
      session.autoLock,
      AutoLockMode.immediately,
      reason: 'the lifecycle needs the policy while notes stay hidden',
    );

    await session.beginRecovery(fixtureRecovery.answers);
    expect(session.phase, SessionPhase.recovering);
    expect(session.autoLock, AutoLockMode.immediately);

    await session.lock();
    expect(session.autoLock, AutoLockMode.immediately);
    expect(session.data, isNull);
  });

  test('a lock without an open session still counts as a generation', () async {
    await seedVault();
    await session.load();
    final before = session.lockGeneration;

    await session.lock();
    expect(session.phase, SessionPhase.locked);
    expect(session.lockGeneration, before + 1);
  });

  test('export copies notes only while the session may operate', () async {
    await unlockSeeded();
    final notes = session.readNotesForExport();
    expect(notes.single.id, fixtureData.notes.single.id);
    expect(() => notes.add(notes.single), throwsUnsupportedError);

    native.failNextCommit = true;
    await expectLater(
      session.saveNote(editedNote('blocked export')),
      throwsA(isA<VaultException>()),
    );
    expect(() => session.readNotesForExport(), throwsA(isA<VaultException>()));
  });

  test('an edit accepted during the seal is neither acknowledged early nor '
      'dropped', () async {
    final gated = _GatedCrypto();
    final gatedSession = NoteSession(crypto: gated, store: store);
    addTearDown(gatedSession.dispose);
    await seedVault();
    await gatedSession.load();
    await gatedSession.unlock(localPassword);

    gated.gate = Completer<void>();
    final first = gatedSession.saveNote(
      gatedSession.data!.notes.single.copyWith(markdown: 'first'),
    );
    await gated.entered.future;

    // This edit lands after the payload was captured but before the seal
    // returned, so the sealed bytes cannot cover it.
    final second = gatedSession.saveNote(
      gatedSession.data!.notes.single.copyWith(markdown: 'second'),
    );
    gated.gate!.complete();
    await Future.wait<void>([first, second]);

    final onDisk = await crypto.unlock((await store.read())!, localPassword);
    expect(
      onDisk.data.notes.single.markdown,
      'second',
      reason: 'both completed futures must be inside the committed snapshot',
    );

    await gatedSession.lock();
    await gatedSession.unlock(localPassword);
    expect(gatedSession.data!.notes.single.markdown, 'second');
  });

  test('a draft that would exceed the envelope limit is rejected before '
      'acceptance', () async {
    // Recovery question text is user-chosen and unbounded, so a large header is
    // creatable. That header leaves less room for the payload in the envelope.
    final bigQuestions = RecoveryConfig(
      questions: [for (var i = 0; i < 3; i++) 'Q$i${'q' * 1900000}'],
      answers: fixtureRecovery.answers,
    );
    final bigVault = await crypto.createVault(
      localPassword,
      bigQuestions,
      fixtureData,
    );
    await File('${dir.path}/vault.enc')
        .writeAsBytes(bigVault.envelope, flush: true);
    await session.load();
    await session.unlock(localPassword);

    // Payload-legal (below maxPayloadBytes) but the base64 payload plus this
    // header no longer fits maxEnvelopeBytes.
    final tooBigForEnvelope = editedNote('a' * (maxPayloadBytes - 4096));
    await expectLater(
      session.saveNote(tooBigForEnvelope),
      throwsA(
        isA<VaultException>()
            .having((e) => e.code, 'code', FailureCode.limit)
            .having((e) => e.detail, 'detail', 'envelope'),
      ),
    );

    expect(session.phase, SessionPhase.unlocked);
    expect(session.canMutate, isTrue);
    expect(session.failure, isNull);
    expect(
      session.data!.notes.single.markdown,
      fixtureData.notes.single.markdown,
    );
    expect(native.commitCount, 0);

    // The session still works and the questions were never restricted.
    await session.saveNote(editedNote('still editable'));
    expect(session.data!.notes.single.markdown, 'still editable');
  });

  test('lock during an in-flight setup invalidates the late unlocked '
      'adoption', () async {
    await session.load();
    native.holdAt = CommitStage.fileSync;
    final setup = session.setup(localPassword, fixtureRecovery);
    await native.entered.future;

    await session.lock();
    expect(session.phase, SessionPhase.locked);
    expect(session.data, isNull);

    native.release();
    await setup;

    expect(
      session.phase,
      SessionPhase.locked,
      reason: 'a lock during setup must not end with an unlocked vault',
    );
    expect(session.data, isNull);
    expect(
      session.recoveryQuestions,
      fixtureRecovery.questions,
      reason: 'the committed vault is on disk, so recovery stays reachable',
    );

    await session.unlock(localPassword);
    expect(session.phase, SessionPhase.unlocked);
    expect(session.data!.notes, isEmpty);
  });

  /// Holds the first store read so a lock can arrive while `load()` is in it.
  void holdNextRead() {
    final entered = Completer<void>();
    final release = Completer<void>();
    var calls = 0;
    store.debugReadGate = () async {
      if (calls++ > 0) return;
      entered.complete();
      await release.future;
    };
    addTearDown(() {
      store.debugReadGate = null;
      if (!release.isCompleted) release.complete();
    });
    gateEntered = entered;
    gateRelease = release;
  }

  test('lock drops the plaintext copy of a sealed edit', () async {
    await unlockSeeded();
    native.failNextCommit = true;
    await expectLater(
      session.saveNote(editedNote('sealed but unwritten')),
      throwsA(isA<VaultException>()),
    );
    expect(
      session.holdsSensitiveState,
      isTrue,
      reason: 'the frozen session still holds its key and notes',
    );

    // The final lock attempt fails too, so only the ciphertext can wait.
    native.failNextCommit = true;
    await session.lock();

    expect(session.phase, SessionPhase.locked);
    expect(session.data, isNull);
    expect(
      session.holdsSensitiveState,
      isFalse,
      reason: 'after lock only ciphertext may wait for retry',
    );

    // The retained ciphertext alone still recovers the edit.
    await session.unlock(localPassword);
    expect(session.data!.notes.single.markdown, 'sealed but unwritten');
  });

  test(
    'retry after lock commits ciphertext without reopening the vault',
    () async {
      await unlockSeeded();
      native.failNextCommit = true;
      await expectLater(
        session.saveNote(editedNote('waits as ciphertext')),
        throwsA(isA<VaultException>()),
      );
      native.failNextCommit = true;
      await session.lock();
      expect(session.phase, SessionPhase.locked);
      expect(session.holdsSensitiveState, isFalse);

      final before = native.commitCount;
      await session.retrySave();

      expect(native.commitCount, before + 1);
      expect(
        session.phase,
        SessionPhase.locked,
        reason: 'writing a sealed snapshot never unlocks the session',
      );
      expect(session.data, isNull);
      expect(session.holdsSensitiveState, isFalse);

      await session.unlock(localPassword);
      expect(session.data!.notes.single.markdown, 'waits as ciphertext');
    },
  );

  test(
    'an uncertain pending snapshot settles after lock without a key',
    () async {
      await unlockSeeded();
      native.failAt = CommitStage.backup;
      await expectLater(
        session.saveNote(editedNote('uncertain body')),
        throwsA(isA<VaultException>()),
      );

      // The lock's own write is left uncertain too, so the sealed snapshot
      // survives the lock while the plaintext copy does not.
      native.failAt = CommitStage.dirSync;
      native.rollbackFails = true;
      await session.lock();
      expect(session.phase, SessionPhase.locked);
      expect(session.holdsSensitiveState, isFalse);

      await session.retrySave();
      expect(session.phase, SessionPhase.locked);
      expect(session.data, isNull);
      expect(session.holdsSensitiveState, isFalse);

      await session.unlock(localPassword);
      expect(session.data!.notes.single.markdown, 'uncertain body');
    },
  );

  test('lock drops the recovery key without ever opening notes', () async {
    await seedVault();
    await session.load();
    expect(session.holdsSensitiveState, isFalse);

    await session.beginRecovery(fixtureRecovery.answers);
    expect(session.data, isNull);
    expect(
      session.holdsSensitiveState,
      isTrue,
      reason: 'the verified recovery key is live state',
    );

    await session.lock();
    expect(session.holdsSensitiveState, isFalse);
    expect(session.phase, SessionPhase.locked);
  });

  test('a reload during in-flight setup is refused', () async {
    await session.load();
    native.holdAt = CommitStage.fileSync;
    final setup = session.setup(localPassword, fixtureRecovery);
    await native.entered.future;

    await expectLater(session.load(), _rejectedAs(FailureCode.busy));
    expect(session.isBusy, isTrue);

    native.release();
    await setup;
    expect(session.phase, SessionPhase.unlocked);
  });

  test('a reload on a live session is refused and stays lockable', () async {
    await unlockSeeded();
    await File('${dir.path}/vault.enc').writeAsString('corrupt');

    await expectLater(session.load(), _rejectedAs(FailureCode.busy));
    expect(session.phase, SessionPhase.unlocked);
    expect(session.data!.notes.single.id, fixtureData.notes.single.id);
    expect(session.needsReload, isFalse);

    await session.lock();
    expect(session.phase, SessionPhase.locked);
    expect(session.holdsSensitiveState, isFalse);
  });

  test('a reload cannot discard a sealed edit waiting for retry', () async {
    await unlockSeeded();
    native.failNextCommit = true;
    await expectLater(
      session.saveNote(editedNote('pending edit')),
      throwsA(isA<VaultException>()),
    );
    expect(session.phase, SessionPhase.storageError);

    await expectLater(session.load(), _rejectedAs(FailureCode.busy));
    expect(session.phase, SessionPhase.storageError);

    await session.retrySave();
    expect(session.data!.notes.single.markdown, 'pending edit');
  });

  test('a lock during load of a fresh install still reaches setup', () async {
    holdNextRead();
    final load = session.load();
    await gateEntered.future;

    await session.lock();
    gateRelease.complete();
    await load;

    expect(
      session.phase,
      SessionPhase.needsSetup,
      reason:
          'a lock must not discard the load result and strand a fresh '
          'install in locked with no vault',
    );
    expect(session.data, isNull);

    await session.setup(localPassword, fixtureRecovery);
    expect(session.phase, SessionPhase.unlocked);
  });

  test('a lock during load of an existing vault keeps the questions '
      'readable', () async {
    await seedVault();
    holdNextRead();
    final load = session.load();
    await gateEntered.future;

    await session.lock();
    gateRelease.complete();
    await load;

    expect(session.phase, SessionPhase.locked);
    expect(session.data, isNull);
    expect(
      session.recoveryQuestions,
      fixtureRecovery.questions,
      reason: 'the committed header stays readable while locked',
    );

    await session.unlock(localPassword);
    expect(session.data!.notes.single.id, fixtureData.notes.single.id);
  });
}
