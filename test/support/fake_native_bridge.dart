import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:hello_flutter/platform/native_bridge.dart';
import 'package:hello_flutter/vault/vault_types.dart';

/// Stages of the native commit, in the order the native handler performs them.
///
/// A stage name means "the work of this stage is what fails": `backup` fails
/// before `vault.enc` moves, `backupSync` after it moved, `replace` before
/// `vault.next` becomes active, and `fileSync`/`dirSync` after the replacement.
enum CommitStage { backup, backupSync, replace, fileSync, dirSync }

typedef CommitCall = ({
  String stagedPath,
  String activePath,
  String previousPath,
});

/// In-memory [NativeBridge] that mirrors the native commit sequence with plain
/// `dart:io` renames, so store tests can break one stage at a time.
///
/// It also mirrors the native rollback: a failure after the backup or the
/// replacement puts the previous generation back, so a failed commit leaves the
/// old vault active. When that rollback itself fails, the commit reports
/// `commit.uncertain` and the new generation may be the active one.
class FakeNativeBridge implements NativeBridge {
  /// Fails the next commit at [stage]; the failing stage does not take effect.
  CommitStage? failAt;

  final StreamController<bool> _focus = StreamController<bool>.broadcast();

  /// Every native call in order, so a test can prove the shield was up before
  /// a frame could expose notes.
  final List<String> events = [];

  /// Mirrors the native state: no cover is installed at startup.
  bool shieldVisible = false;

  /// Counts every shield request, including the no-op repeats the native
  /// implementations skip, so a test can prove a call was made.
  int shieldCalls = 0;

  /// Delivers a focus change to the app as the native side would.
  void emitFocus(bool focused) => _focus.add(focused);

  /// Models the native shield installation failing.
  bool failShield = false;

  /// Models a bridge throwing something that is not a [VaultException].
  bool throwRawOnShield = false;

  @override
  Stream<bool> get focusChanges => _focus.stream;

  // --- import/export seams -------------------------------------------------

  /// Returned by the next [pickImport]; `null` models a cancelled picker.
  PickedImport? nextPicked;

  /// Bytes the next [readImport] hands back.
  Uint8List? importBytes;

  /// Fails the next read with a storage failure.
  bool failRead = false;

  /// Fails the next export save with a storage failure.
  bool failSave = false;

  /// Returned by the next [saveExport]; `false` models a cancelled save.
  bool saveResult = true;

  /// Holds the export save open until completed, so a lock can land while the
  /// native panel is up.
  Completer<void>? saveGate;

  /// Holds the open panel until completed, so a lock can land while it is up.
  Completer<void>? pickGate;

  int pickCalls = 0;
  final List<String> readTokens = [];
  final List<int> readLimits = [];
  final List<String> released = [];
  String? savedFileName;
  Uint8List? savedExport;

  @override
  Future<PickedImport?> pickImport() async {
    pickCalls++;
    final gate = pickGate;
    if (gate != null) await gate.future;
    return nextPicked;
  }

  @override
  Future<Uint8List> readImport(String token, {required int maxBytes}) async {
    readTokens.add(token);
    readLimits.add(maxBytes);
    if (failRead) {
      failRead = false;
      throw const VaultException(FailureCode.storage, 'read.failed');
    }
    final bytes = importBytes ?? Uint8List(0);
    if (bytes.length > maxBytes) {
      throw const VaultException(FailureCode.limit, 'read.size');
    }
    return bytes;
  }

  @override
  Future<void> releaseImport(String token) async {
    released.add(token);
  }

  @override
  Future<bool> saveExport(Uint8List bytes, {required String fileName}) async {
    final gate = saveGate;
    if (gate != null) {
      savedFileName = fileName;
      savedExport = Uint8List.fromList(bytes);
      await gate.future;
    }
    if (failSave) {
      failSave = false;
      throw const VaultException(FailureCode.storage, 'save.failed');
    }
    if (!saveResult) return false;
    savedFileName = fileName;
    savedExport = Uint8List.fromList(bytes);
    return true;
  }

  /// Mirrors the native idempotence: repeating the current state is a no-op.
  @override
  Future<void> setPrivacyShield(bool visible) async {
    shieldCalls++;
    if (throwRawOnShield) throw StateError('shield.raw');
    if (failShield) {
      throw const VaultException(FailureCode.storage, 'shield.failed');
    }
    if (shieldVisible == visible) return;
    shieldVisible = visible;
    events.add('shield:$visible');
  }

  /// Shorthand for `failAt = CommitStage.backup`, used by the brief's snippet.
  bool failNextCommit = false;

  /// Fails every commit at [CommitStage.backup] until cleared, for a storage
  /// fault that outlives one retry.
  bool failEveryCommit = false;

  /// Makes the rollback attempt itself fail, modelling an I/O fault that leaves
  /// the active file in an unknown generation.
  bool rollbackFails = false;

  /// Pauses the commit before the named stage's work until [release] is called.
  CommitStage? holdAt;

  /// Completes when the commit reaches [holdAt].
  final Completer<void> entered = Completer<void>();
  final Completer<void> _release = Completer<void>();

  int commitCount = 0;
  final List<CommitCall> calls = [];

  void release() {
    if (!_release.isCompleted) _release.complete();
  }

  @override
  Future<void> commitVault({
    required String stagedPath,
    required String activePath,
    required String previousPath,
  }) async {
    calls.add((
      stagedPath: stagedPath,
      activePath: activePath,
      previousPath: previousPath,
    ));
    commitCount++;

    final failure =
        failAt ??
        (failEveryCommit
            ? CommitStage.backup
            : (failNextCommit ? CommitStage.backup : null));
    failAt = null;
    failNextCommit = false;

    final staged = File(stagedPath);
    final active = File(activePath);
    final previous = File(previousPath);
    if (!await staged.exists()) {
      throw const VaultException(FailureCode.storage, 'commit.staged');
    }

    var backedUp = false;
    var replaced = false;
    try {
      if (await active.exists()) {
        if (failure == CommitStage.backup) {
          throw const VaultException(FailureCode.storage, 'commit.backup');
        }
        await active.rename(previousPath);
        backedUp = true;
      }
      await _maybeHold(CommitStage.backupSync);
      if (failure == CommitStage.backupSync) {
        throw const VaultException(FailureCode.storage, 'commit.backupSync');
      }
      if (failure == CommitStage.replace) {
        throw const VaultException(FailureCode.storage, 'commit.replace');
      }
      await staged.rename(activePath);
      replaced = true;
      await _maybeHold(CommitStage.fileSync);
      if (failure == CommitStage.fileSync) {
        throw const VaultException(FailureCode.storage, 'commit.fileSync');
      }
      if (failure == CommitStage.dirSync) {
        throw const VaultException(FailureCode.storage, 'commit.dirSync');
      }
    } on VaultException {
      await _rollback(
        staged: staged,
        active: active,
        previous: previous,
        backedUp: backedUp,
        replaced: replaced,
      );
      rethrow;
    }
  }

  Future<void> _maybeHold(CommitStage stage) async {
    if (holdAt != stage) return;
    if (!entered.isCompleted) entered.complete();
    await _release.future;
  }

  /// Puts the previous generation back. Throws `commit.uncertain` when the
  /// rollback cannot complete, because the active generation is then unknown.
  Future<void> _rollback({
    required File staged,
    required File active,
    required File previous,
    required bool backedUp,
    required bool replaced,
  }) async {
    if (rollbackFails) {
      throw const VaultException(FailureCode.storage, 'commit.uncertain');
    }
    try {
      if (replaced) await active.rename(staged.path);
      if (backedUp) await previous.rename(active.path);
    } on FileSystemException {
      throw const VaultException(FailureCode.storage, 'commit.uncertain');
    }
  }
}
