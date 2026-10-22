import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../vault/vault_crypto.dart';
import '../vault/vault_store.dart';
import '../vault/vault_types.dart';

enum SessionPhase {
  loading,
  needsSetup,
  locked,
  recovering,
  unlocked,
  storageError,
}

/// Owns the unlocked vault and the single commit order for every change.
///
/// Sealed ciphertext is authoritative: after a change is sealed, a failed write
/// keeps that snapshot, freezes mutations and export, and retries that snapshot
/// instead of branching from the older generation still on disk. Revisions are
/// assigned when sealing, and every write shares one queue, so a late callback
/// or an older credential can never win over a newer commit.
class NoteSession extends ChangeNotifier {
  NoteSession({required VaultCrypto crypto, required VaultStore store})
    : _crypto = crypto, // ignore: prefer_initializing_formals
      _store = store; // ignore: prefer_initializing_formals

  /// Autosave debounce; it lives here so a lock or a note switch can flush the
  /// last accepted edit before the widget is torn down.
  static const Duration autosaveDebounce = Duration(milliseconds: 500);

  final VaultCrypto _crypto;
  final VaultStore _store;
  final Random _random = Random.secure();

  SessionPhase _phase = SessionPhase.loading;
  FailureCode? _failure;
  VaultData? _data;
  UnlockedVault? _vault;
  UnlockedVault? _recovery;
  VaultData? _recoveryData;
  List<String> _questions = const [];

  Uint8List? _pending;
  VaultData? _pendingData;
  int? _pendingRevision;

  int _revision = 0;
  int _accepted = 0;
  int _sealedAt = 0;
  bool _failed = false;
  bool _uncertain = false;
  bool _reload = false;
  int _epoch = 0;
  int _busy = 0;
  bool _disposed = false;

  Timer? _debounce;
  Future<void> _tail = Future<void>.value();
  final List<_Waiter> _waiters = [];

  SessionPhase get phase => _phase;

  FailureCode? get failure => _failure;

  /// Note contents are exposed only while the session is usable. A locked or
  /// recovering session never hands notes to the UI.
  VaultData? get data => switch (_phase) {
    SessionPhase.unlocked || SessionPhase.storageError => _data,
    _ => null,
  };

  List<String> get recoveryQuestions => _questions;

  bool get isBusy => _busy > 0;

  /// A load failure means there is no open vault to retry writing, so the UI
  /// must call [load] again; [retrySave] cannot recover from it.
  bool get needsReload => _reload;

  /// A failed write freezes edits, import, export and credential changes until
  /// the sealed snapshot is reconciled with the disk. An in-flight commit does
  /// not freeze anything: the newer edit is simply sealed in the next round.
  bool get canMutate =>
      _phase == SessionPhase.unlocked &&
      _busy == 0 &&
      !_failed &&
      _data != null;

  Future<void> load() async {
    _begin();
    final epoch = _epoch;
    try {
      await _enqueue(() async {
        final disk = await _store.read();
        if (epoch != _epoch) return;
        if (disk == null) {
          _questions = const [];
          _phase = SessionPhase.needsSetup;
        } else {
          _questions = _crypto.readRecoveryQuestions(disk);
          _phase = SessionPhase.locked;
        }
        _data = null;
        _vault = null;
        _recovery = null;
        _recoveryData = null;
        _failure = null;
        _failed = false;
        _reload = false;
        _notify();
      });
    } on VaultException catch (error) {
      _failure = error.code;
      _phase = SessionPhase.storageError;
      _reload = true;
      _notify();
      rethrow;
    } finally {
      _end();
    }
  }

  Future<void> setup(String password, RecoveryConfig recovery) async {
    if (_phase != SessionPhase.needsSetup) {
      throw const VaultException(FailureCode.busy, 'phase');
    }
    if (!validPassword(password)) {
      throw const VaultException(FailureCode.credentials, 'password.length');
    }
    _begin();
    final epoch = _epoch;
    try {
      await _enqueue(() async {
        final created = await _crypto.createVault(
          password,
          recovery,
          VaultData(notes: const []),
        );
        await _store.commit(created.envelope);
        // The vault is on disk now, so its questions are readable even if a
        // lock during setup rejects the unlocked adoption below.
        _questions = recovery.questions;
        if (epoch != _epoch) return;
        _adopt(created, epoch);
      });
    } on VaultException catch (error) {
      _failure = error.code;
      _phase = SessionPhase.needsSetup;
      _data = null;
      _vault = null;
      _notify();
      rethrow;
    } finally {
      _end();
    }
  }

  Future<void> unlock(String password) async {
    if (_phase != SessionPhase.locked) {
      throw const VaultException(FailureCode.busy, 'phase');
    }
    _begin();
    final epoch = _epoch;
    try {
      await _enqueue(() async {
        final disk = await _store.read();
        if (disk == null) {
          throw const VaultException(FailureCode.format, 'vault.missing');
        }
        // Authenticate the last committed credential before touching the disk,
        // so a wrong password never rewrites a pending generation.
        final checked = await _crypto.unlock(disk, password);
        final pending = _pending;
        if (pending == null) {
          _adopt(checked, epoch);
          return;
        }
        // Validate the sealed snapshot with this key before writing it; a
        // snapshot that does not open under the committed credential is not
        // written at all.
        final verifiedPending = await _crypto.unlock(pending, password);
        await _commitPending();
        if (_pending != null) {
          throw VaultException(
            _failure ?? FailureCode.storage,
            'commit.pending',
          );
        }
        _adopt(verifiedPending, epoch);
      });
    } on VaultException catch (error) {
      _failure = error.code;
      _notify();
      rethrow;
    } finally {
      _end();
    }
  }

  /// Verifies the three answers and keeps the recovered key only as private
  /// recovery state. Notes stay hidden until [completeRecovery] commits.
  Future<void> beginRecovery(List<String> answers) async {
    if (_phase != SessionPhase.locked) {
      throw const VaultException(FailureCode.busy, 'phase');
    }
    _begin();
    final epoch = _epoch;
    try {
      await _enqueue(() async {
        // A sealed snapshot that never reached the disk is newer than the file,
        // so it is written first; recovery then authenticates the same content.
        if (_pending != null) {
          await _commitPending();
          if (_pending != null) {
            throw VaultException(
              _failure ?? FailureCode.storage,
              'commit.pending',
            );
          }
        }
        final disk = await _store.read();
        if (disk == null) {
          throw const VaultException(FailureCode.format, 'vault.missing');
        }
        final opened = await _crypto.recover(disk, answers);
        if (epoch != _epoch) return;
        _recovery = opened;
        _recoveryData = opened.data;
        _data = null;
        _vault = null;
        _phase = SessionPhase.recovering;
        _failure = null;
        _notify();
      });
    } on VaultException catch (error) {
      _failure = error.code;
      _phase = SessionPhase.locked;
      _notify();
      rethrow;
    } finally {
      _end();
    }
  }

  /// Re-wraps the data key under [newPassword] and only then activates the new
  /// credential. A failed commit leaves the old wrappers on disk untouched.
  Future<void> completeRecovery(String newPassword) async {
    if (_phase != SessionPhase.recovering || _recovery == null) {
      throw const VaultException(FailureCode.busy, 'phase');
    }
    if (!validPassword(newPassword)) {
      throw const VaultException(FailureCode.credentials, 'password.length');
    }
    _begin();
    final epoch = _epoch;
    try {
      await _enqueue(() async {
        final recovery = _recovery;
        if (recovery == null) {
          throw const VaultException(FailureCode.busy, 'recovery');
        }
        final data = _recoveryData ?? recovery.data;
        final revision = recovery.revision + 1;
        final sealed = await _crypto.rewrapPassword(
          UnlockedVault(
            envelope: recovery.envelope,
            dataKey: recovery.dataKey,
            data: data,
            revision: recovery.revision,
          ),
          newPassword,
          revision,
        );
        try {
          await _store.commit(sealed);
        } on VaultException catch (error) {
          _failure = error.code;
          _notify();
          rethrow;
        }
        // The rewrap replaced every wrapper, so any older sealed snapshot is
        // retired here; retrying it later must not revive the old password.
        _pending = null;
        _pendingData = null;
        _pendingRevision = null;
        _accepted = 0;
        _sealedAt = 0;
        _failed = false;
        _uncertain = false;
        _adopt(
          UnlockedVault(
            envelope: sealed,
            dataKey: recovery.dataKey,
            data: data,
            revision: revision,
          ),
          epoch,
        );
      });
    } on VaultException catch (error) {
      _failure = error.code;
      _notify();
      rethrow;
    } finally {
      _end();
    }
  }

  /// Validates the draft before accepting it and completes only once the commit
  /// covering that revision has landed.
  Future<void> saveNote(Note note) async {
    _requireMutable();
    final data = _data!;
    final notes = [...data.notes];
    final index = notes.indexWhere((existing) => existing.id == note.id);
    if (index < 0) {
      notes.add(note);
    } else {
      notes[index] = note;
    }
    await _accept(data.copyWith(notes: notes));
  }

  Future<void> deleteNote(String id) async {
    _requireMutable();
    final data = _data!;
    await _accept(
      data.copyWith(notes: data.notes.where((note) => note.id != id).toList()),
    );
  }

  Future<void> setAutoLock(AutoLockMode mode) async {
    _requireMutable();
    await _accept(_data!.copyWith(autoLock: mode));
  }

  /// Commits the newest sealed snapshot again after a failed write.
  Future<void> retrySave() async {
    if (_phase == SessionPhase.recovering) {
      throw const VaultException(FailureCode.busy, 'phase');
    }
    // A load failure left no open vault; silently returning would look like a
    // successful retry, so callers must load again instead.
    if (_reload) {
      throw const VaultException(FailureCode.storage, 'load');
    }
    if (_pending == null && !_failed) return;
    _begin();
    try {
      await _enqueue(() async {
        if (_uncertain) await _reconcileUncertain();
        await _flush();
        if (_failed || _pending != null) {
          throw VaultException(_failure ?? FailureCode.storage, 'commit');
        }
      });
    } on VaultException catch (error) {
      _failure = error.code;
      _notify();
      rethrow;
    } finally {
      _end();
    }
  }

  /// Hides every note immediately, then seals and writes the last accepted edit
  /// before the key is dropped.
  ///
  /// A lock during `setup` invalidates the pending adoption: the vault may
  /// already be on disk, so the user unlocks instead of being handed an
  /// unlocked session they left. A lock during `load` must not invalidate the
  /// load result, because `load` adopts no key and still has to publish
  /// `needsSetup`/`locked` and the recovery questions.
  Future<void> lock() {
    if (_phase == SessionPhase.loading) return Future<void>.value();
    // A failed load has no key and no notes to hide; locking would hide the
    // only way to retry the load.
    if (_reload) return Future<void>.value();
    if (_phase == SessionPhase.needsSetup) {
      if (_busy == 0) return Future<void>.value();
      _epoch++;
      _phase = SessionPhase.locked;
      _debounce?.cancel();
      _debounce = null;
      _notify();
      return Future<void>.value();
    }
    _epoch++;
    _phase = SessionPhase.locked;
    _failure = null;
    _debounce?.cancel();
    _debounce = null;
    _notify();
    return _enqueue(() async {
      try {
        // The getter already hides the notes; the internal state survives until
        // the last accepted keystroke is sealed and written.
        if (_uncertain) await _reconcileUncertain();
        await _flush();
      } on VaultException catch (error) {
        _failure = error.code;
        _failed = true;
        _failWaiters(error);
      } finally {
        if (_pending != null) _failure ??= FailureCode.storage;
        _vault = null;
        _recovery = null;
        _recoveryData = null;
        _data = null;
        _notify();
      }
    });
  }

  List<Note> readNotesForExport() {
    if (!canMutate) {
      throw const VaultException(FailureCode.busy, 'session');
    }
    return List<Note>.unmodifiable(_data!.notes);
  }

  /// Appends imported notes under fresh local ids in one commit.
  Future<void> appendImported(List<Note> notes) async {
    _requireMutable();
    if (notes.isEmpty) return;
    final data = _data!;
    final added = [
      for (final note in notes)
        Note(
          id: _newId(),
          title: note.title,
          markdown: note.markdown,
          createdAt: note.createdAt,
          updatedAt: note.updatedAt,
        ),
    ];
    await _accept(
      data.copyWith(notes: [...data.notes, ...added]),
      immediate: true,
    );
  }

  @override
  void dispose() {
    // Dropping a timer with accepted edits still inside the debounce window
    // would discard the last keystroke, so flush it now.
    if (_debounce != null && _sealedAt < _accepted) {
      _debounce!.cancel();
      _debounce = null;
      unawaited(_enqueue(_flush));
    }
    _disposed = true;
    super.dispose();
  }

  Future<void> _accept(VaultData next, {bool immediate = false}) {
    _requireMutable();
    final revision = _revision + 1;
    final vault = _vault!;
    // Reject before the draft enters state, so a rejected edit leaves the last
    // accepted value in place and never reaches the writer.
    _crypto.checkSnapshotFits(vault, next, revision);
    _data = next;
    _accepted++;
    final waiter = _Waiter(_accepted);
    _waiters.add(waiter);
    _notify();
    if (immediate) {
      _debounce?.cancel();
      _debounce = null;
      unawaited(_enqueue(_flush));
    } else {
      _scheduleDebounce();
    }
    return waiter.completer.future;
  }

  void _scheduleDebounce() {
    _debounce?.cancel();
    _debounce = Timer(autosaveDebounce, () {
      _debounce = null;
      unawaited(_enqueue(_flush));
    });
  }

  /// Seals the newest accepted state and commits it until caught up or frozen.
  ///
  /// A sealed snapshot that does not cover the newest accepted edit is replaced
  /// only after the newer seal succeeds, so a seal failure never drops the last
  /// authoritative ciphertext. Once the key is gone only sealed bytes are
  /// written, which is what makes retry after lock possible.
  Future<void> _flush() async {
    try {
      while (true) {
        final vault = _vault;
        final data = _data;
        if (vault == null || data == null) {
          if (_pending != null) await _commitPending();
          return;
        }
        final behind = _sealedAt < _accepted;
        if (_pending != null && !behind) {
          await _commitPending();
          if (_pending != null) return;
          continue;
        }
        if (!behind) return;
        // Capture the watermark before the seal awaits: an edit accepted during
        // the seal is not covered by these bytes, so it must stay behind.
        final sealedUpTo = _accepted;
        final revision = _revision + 1;
        final Uint8List sealed;
        try {
          sealed = await _crypto.seal(vault, data, revision);
        } on VaultException catch (error) {
          _failure = error.code;
          _failed = true;
          _failWaiters(error);
          _notify();
          return;
        }
        _pending = sealed;
        _pendingData = data;
        _pendingRevision = revision;
        _sealedAt = sealedUpTo;
        await _commitPending();
        if (_pending != null) return;
      }
    } on VaultException {
      // _commitPending already recorded the failure and failed the waiters.
    } on Object {
      const error = VaultException(FailureCode.storage, 'seal');
      _failure = error.code;
      _failed = true;
      _failWaiters(error);
      _notify();
    }
  }

  Future<void> _commitPending() async {
    final pending = _pending;
    if (pending == null) return;
    final epoch = _epoch;
    final revision = _pendingRevision!;
    final data = _pendingData!;
    final vault = _vault;
    try {
      await _store.commit(pending);
      _revision = revision;
      _pending = null;
      _pendingData = null;
      _pendingRevision = null;
      _failed = false;
      _uncertain = false;
      _failure = null;
      if (vault != null) {
        _vault = UnlockedVault(
          envelope: pending,
          dataKey: vault.dataKey,
          data: data,
          revision: revision,
        );
      }
      if (epoch == _epoch && _phase == SessionPhase.storageError) {
        _phase = SessionPhase.unlocked;
      }
      _completeWaiters(_sealedAt);
      _notify();
    } on VaultException catch (error) {
      _failure = error.code;
      _failed = true;
      _uncertain =
          error.code == FailureCode.storage &&
          error.detail == 'commit.uncertain';
      _failWaiters(error);
      if (_phase == SessionPhase.unlocked) {
        _phase = SessionPhase.storageError;
      }
      _notify();
    }
  }

  /// After `commit.uncertain` the active generation is unknown; a read decides
  /// whether the snapshot already landed before it is written again.
  Future<void> _reconcileUncertain() async {
    final pending = _pending;
    if (pending == null) {
      _uncertain = false;
      return;
    }
    final disk = await _store.read();
    if (disk != null && listEquals(disk, pending)) {
      _revision = _pendingRevision!;
      final data = _pendingData!;
      final vault = _vault;
      _pending = null;
      _pendingData = null;
      _pendingRevision = null;
      _failed = false;
      _uncertain = false;
      _failure = null;
      if (vault != null) {
        _vault = UnlockedVault(
          envelope: pending,
          dataKey: vault.dataKey,
          data: data,
          revision: _revision,
        );
      }
      _completeWaiters(_sealedAt);
      if (_phase == SessionPhase.storageError) {
        _phase = SessionPhase.unlocked;
      }
      _notify();
      return;
    }
    _uncertain = false;
  }

  void _adopt(UnlockedVault vault, int epoch) {
    // Any waiter still outstanding here belongs to a state this adoption
    // replaces; fail it rather than leaving its Future pending forever.
    _failWaiters(const VaultException(FailureCode.busy, 'session'));
    if (epoch != _epoch) {
      _vault = null;
      _recovery = null;
      _recoveryData = null;
      _data = null;
      _pending = null;
      _pendingData = null;
      _pendingRevision = null;
      _accepted = 0;
      _sealedAt = 0;
      _failed = false;
      _uncertain = false;
      _reload = false;
      _phase = SessionPhase.locked;
      _notify();
      return;
    }
    _vault = vault;
    _revision = vault.revision;
    _data = vault.data;
    _questions = _crypto.readRecoveryQuestions(vault.envelope);
    _recovery = null;
    _recoveryData = null;
    _pending = null;
    _pendingData = null;
    _pendingRevision = null;
    _accepted = 0;
    _sealedAt = 0;
    _failed = false;
    _uncertain = false;
    _reload = false;
    _failure = null;
    _phase = SessionPhase.unlocked;
    _notify();
  }

  void _requireMutable() {
    if (!canMutate) {
      throw const VaultException(FailureCode.busy, 'session');
    }
  }

  String _newId() {
    final bytes = Uint8List(16);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = _random.nextInt(256);
    }
    return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }

  void _completeWaiters(int upTo) {
    final done = _waiters.where((waiter) => waiter.watermark <= upTo).toList();
    _waiters.removeWhere((waiter) => waiter.watermark <= upTo);
    for (final waiter in done) {
      if (!waiter.completer.isCompleted) waiter.completer.complete();
    }
  }

  void _failWaiters(VaultException error) {
    final failed = [..._waiters];
    _waiters.clear();
    for (final waiter in failed) {
      if (!waiter.completer.isCompleted) waiter.completer.completeError(error);
    }
  }

  Future<void> _enqueue(Future<void> Function() task) {
    final run = _tail.then((_) => task());
    _tail = run.then((_) {}, onError: (Object _) {});
    return run;
  }

  void _begin() {
    _busy++;
    _notify();
  }

  void _end() {
    _busy--;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }
}

class _Waiter {
  _Waiter(this.watermark);

  final int watermark;
  final Completer<void> completer = Completer<void>();
}
