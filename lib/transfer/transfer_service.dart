import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../platform/native_bridge.dart';
import '../session/note_session.dart';
import '../vault/vault_crypto.dart';
import '../vault/vault_types.dart';

/// How far an import has progressed, so the UI can be honest about what a
/// cancel can still stop. Reading and decrypting are cancellable; the vault
/// commit is not.
enum ImportStage { idle, reading, committing }

/// Import and export of notes through the session and the native file picker.
///
/// Export prepares the whole ciphertext before the native save panel opens, so
/// the password and note plaintext are released before the OS dialog can take
/// focus. Import keeps only the opaque native handle across a lock: the handle
/// outlives the widget tree, while the bytes are read and decrypted only after
/// the session is unlocked again. A cancelled or failed batch never reaches
/// session state.
class TransferService extends ChangeNotifier {
  TransferService({
    required NoteSession session,
    required VaultCrypto crypto,
    required NativeBridge native,
  }) : _session = session, // ignore: prefer_initializing_formals
       _crypto = crypto, // ignore: prefer_initializing_formals
       _native = native; // ignore: prefer_initializing_formals

  /// The one extension an export is written under.
  static const String exportExtension = '.encrynote';

  /// The one extension accepted as a plain Markdown import.
  static const String markdownExtension = '.md';

  final NoteSession _session;
  final VaultCrypto _crypto;
  final NativeBridge _native;

  /// The session this service acts for; dialogs gate on its phase.
  NoteSession get session => _session;

  PickedImport? _pending;
  bool _disposed = false;

  /// Incremented by every cancel. An import that was cancelled while its bytes
  /// were still being read or decrypted sees the change and never commits.
  int _cancelGeneration = 0;

  /// Tokens already released, so one handle is released exactly once no matter
  /// how many paths (button, dismissal, failure, dispose) reach for it.
  final Set<String> _released = <String>{};

  ImportStage _stage = ImportStage.idle;

  /// Where the current import is; [ImportStage.committing] is not cancellable.
  ImportStage get importStage => _stage;

  /// The selection a lock interrupted, kept so an unlock can offer to resume it
  /// without reopening the picker. Holds no plaintext and no password.
  PickedImport? get pendingImport => _pending;

  /// Writes every note into a new export envelope and hands only ciphertext to
  /// the native save panel. Returns `false` when the user cancelled the save.
  ///
  /// The save panel opens only after the ciphertext exists. This frame drops its
  /// own password reference before that await, so nothing in Dart holds the
  /// password while the OS dialog has focus. Strings cannot be zeroized, so this
  /// is a best-effort reference release, not a memory-erasure claim.
  Future<bool> exportNotes(String password) async {
    final bytes = await _sealNotes(password);
    // Drops the only reference this frame keeps to the original string.
    password = '';
    return _native.saveExport(bytes, fileName: _exportFileName());
  }

  /// Flushes the last keystroke, re-checks authority, and seals the snapshot.
  ///
  /// Returns before the native panel opens, so neither the note list nor the
  /// password outlives this call's frame.
  Future<Uint8List> _sealNotes(String password) async {
    if (!validPassword(password)) {
      throw const VaultException(FailureCode.credentials, 'password.length');
    }
    // A pending write is flushed first, so the export covers the last
    // keystroke. The authority re-check inside [readNotesForExport] refuses a
    // frozen or locked session rather than exporting stale or missing data.
    await _session.flushSave();
    final notes = _session.readNotesForExport();
    return _crypto.exportNotes(notes, password);
  }

  /// Opens the picker and keeps its opaque handle. `null` means cancelled.
  Future<PickedImport?> pickImport() async {
    _requireUnlocked();
    final picked = await _native.pickImport();
    if (picked == null) return null;
    await _releasePending();
    _pending = picked;
    _notify();
    return picked;
  }

  /// Imports [picked] as one atomic batch of new notes.
  ///
  /// On any failure the existing notes are untouched, the handle is released,
  /// and nothing from the batch is left for an autosave retry. A cancel that
  /// lands while the bytes are still being read or decrypted stops the batch
  /// before it reaches the session.
  Future<void> importPicked(
    PickedImport picked, {
    String? exportPassword,
  }) async {
    _requireUnlocked();
    final generation = _cancelGeneration;
    try {
      _setStage(ImportStage.reading);
      final notes = await _readNotes(picked, exportPassword);
      if (generation != _cancelGeneration) {
        throw const VaultException(FailureCode.busy, 'import.cancelled');
      }
      _requireUnlocked();
      // From here the batch is one vault commit; cancelling would be a lie.
      _setStage(ImportStage.committing);
      await _session.appendImported(notes);
    } finally {
      _setStage(ImportStage.idle);
      await _release(picked.token);
      if (_pending?.token == picked.token) {
        _pending = null;
        _notify();
      }
    }
  }

  /// Drops the pending handle without reading or changing anything.
  ///
  /// A commit already in progress is not cancellable, so this is a no-op then;
  /// the caller's UI disables the action at that point instead of pretending.
  Future<void> cancelImport() async {
    if (_stage == ImportStage.committing) return;
    _cancelGeneration++;
    await _releasePending();
    _notify();
  }

  Future<List<Note>> _readNotes(
    PickedImport picked,
    String? exportPassword,
  ) async {
    final isExport = picked.name.toLowerCase().endsWith(exportExtension);
    final isMarkdown = picked.name.toLowerCase().endsWith(markdownExtension);
    if (!isExport && !isMarkdown) {
      throw const VaultException(FailureCode.unsupported, 'import.extension');
    }
    // An export is refused before reading when no export password was given;
    // the app password and recovery answers are never tried here.
    if (isExport &&
        (exportPassword == null || !validPassword(exportPassword))) {
      throw const VaultException(FailureCode.credentials, 'password.length');
    }
    final limit = isExport ? maxEnvelopeBytes : maxMarkdownBytes;
    final bytes = await _native.readImport(picked.token, maxBytes: limit);
    if (bytes.length > limit) {
      throw const VaultException(FailureCode.limit, 'import.size');
    }
    if (isExport) {
      return _crypto.importExport(bytes, exportPassword!);
    }
    return [_markdownNote(picked.name, bytes)];
  }

  /// One plain Markdown file as a new note: title from the base name, source
  /// kept byte-for-byte apart from an optional UTF-8 BOM.
  Note _markdownNote(String name, Uint8List bytes) {
    final String text;
    try {
      var start = 0;
      if (bytes.length >= 3 &&
          bytes[0] == 0xEF &&
          bytes[1] == 0xBB &&
          bytes[2] == 0xBF) {
        start = 3;
      }
      text = utf8.decode(bytes.sublist(start));
    } on FormatException {
      throw const VaultException(FailureCode.format, 'markdown.utf8');
    }
    final base = name.split(RegExp(r'[/\\]')).last;
    final dot = base.lastIndexOf('.');
    // A name that is only an extension has no title of its own.
    final title = (dot < 0 ? base : base.substring(0, dot)).trim();
    final now = DateTime.now().toUtc();
    return Note(
      id: '0' * 32,
      title: title.isEmpty ? 'Untitled' : title,
      markdown: text,
      createdAt: now,
      updatedAt: now,
    );
  }

  /// A stable, path-free base name; the native panel owns the location.
  String _exportFileName() {
    final stamp = DateTime.now().toUtc();
    String two(int value) => value.toString().padLeft(2, '0');
    return 'encrynote-${stamp.year}${two(stamp.month)}${two(stamp.day)}'
        '-${two(stamp.hour)}${two(stamp.minute)}${two(stamp.second)}'
        '$exportExtension';
  }

  Future<void> _releasePending() async {
    final pending = _pending;
    _pending = null;
    if (pending != null) await _release(pending.token);
  }

  void _setStage(ImportStage stage) {
    if (_stage == stage) return;
    _stage = stage;
    _notify();
  }

  /// Releases one token at most once, whichever path asks first.
  Future<void> _release(String token) async {
    if (!_released.add(token)) return;
    try {
      await _native.releaseImport(token);
    } on Object {
      // The platform owns the grant; a failed release cannot resurrect notes.
    }
  }

  void _requireUnlocked() {
    if (!_session.canMutate) {
      throw const VaultException(FailureCode.busy, 'session');
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    final pending = _pending;
    _pending = null;
    if (pending != null && _released.add(pending.token)) {
      // Best effort: the native side also drops grants when the app goes away.
      _native.releaseImport(pending.token).catchError((Object _) {});
    }
    super.dispose();
  }
}
