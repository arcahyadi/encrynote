import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../platform/native_bridge.dart';
import 'vault_crypto.dart';
import 'vault_types.dart';

/// Owns the three vault files in the app's private directory.
///
/// Commit point: the native side reports success only after the staged
/// ciphertext is synced, the active file is replaced, and the directory
/// metadata is synced. This store never treats "bytes were written" as saved.
///
/// Failure semantics: a reported failure means the previous generation was put
/// back, so the active file is the one the caller last saw. The single
/// exception is `commit.uncertain`: the rollback itself failed, so the active
/// generation is unknown and the caller must not assume either outcome.
class VaultStore {
  VaultStore({required Directory directory, required NativeBridge native})
    : _directory = directory, // ignore: prefer_initializing_formals
      _native = native; // ignore: prefer_initializing_formals

  static const String activeName = 'vault.enc';
  static const String previousName = 'vault.previous';
  static const String stagedName = 'vault.next';

  // Mirrors the v1 envelope parser in vault_crypto; kept here so the store can
  // reject a file that is not a local vault without running any crypto.
  static const String _suiteV1 = 'argon2id-aes256gcm';

  final Directory _directory;
  final NativeBridge _native;

  Future<void> _tail = Future<void>.value();

  /// Test-only hook that holds a read open so the ordering regression can
  /// reproduce the pre-fix race deterministically. Not part of the API.
  @visibleForTesting
  Future<void> Function()? debugReadGate;

  File _file(String name) => File('${_directory.path}/$name');

  /// Returns the committed envelope, or `null` only when no vault and no
  /// recovery candidate exists. A present-but-unreadable file is an error:
  /// falling back to an older generation would silently roll back notes.
  ///
  /// Reads take a slot in the same queue as commits. Merely awaiting the queue
  /// would let a commit requested later interleave with this read and expose
  /// `vault.previous` (or a transient ENOENT) as if it were the vault.
  Future<Uint8List?> read() {
    final task = _tail.then((_) => _readFromDisk());
    _tail = task.then((_) {}, onError: (Object _) {});
    return task;
  }

  /// Stages [ciphertext], then asks the native side to replace the vault.
  ///
  /// Reads and commits share one queue, so neither can observe the other
  /// mid-replacement. A failed commit restores the previous generation; when
  /// the native rollback itself fails it reports `commit.uncertain` and the
  /// active generation is genuinely unknown.
  Future<void> commit(Uint8List ciphertext) {
    final bytes = Uint8List.fromList(ciphertext);
    final task = _tail.then((_) => _commit(bytes));
    _tail = task.then((_) {}, onError: (Object _) {});
    return task;
  }

  Future<Uint8List?> _readFromDisk() async {
    final gate = debugReadGate;
    if (gate != null) await gate();
    final active = _file(activeName);
    if (await active.exists()) return _readAndCheck(active);
    final previous = _file(previousName);
    if (await previous.exists()) return _readAndCheck(previous);
    return null;
  }

  Future<void> _commit(Uint8List bytes) async {
    _checkVaultBytes(bytes);

    final staged = _file(stagedName);
    try {
      await _directory.create(recursive: true);
      await staged.writeAsBytes(bytes, flush: true);
    } on FileSystemException {
      throw const VaultException(FailureCode.storage, 'staging');
    }

    try {
      await _native.commitVault(
        stagedPath: staged.path,
        activePath: _file(activeName).path,
        previousPath: _file(previousName).path,
      );
    } on VaultException {
      rethrow;
    } on Object {
      throw const VaultException(FailureCode.storage, 'commit');
    }
  }

  Future<Uint8List> _readAndCheck(File file) async {
    final Uint8List bytes;
    try {
      // Check the size before allocating: an anomalous multi-gigabyte file
      // must surface `limit`, not OOM the app.
      if (await file.length() > maxEnvelopeBytes) {
        throw const VaultException(FailureCode.limit, 'envelope');
      }
      bytes = await file.readAsBytes();
    } on FileSystemException {
      throw const VaultException(FailureCode.storage, 'read');
    }
    _checkVaultBytes(bytes);
    return bytes;
  }

  void _checkVaultBytes(Uint8List bytes) {
    if (bytes.isEmpty) {
      throw const VaultException(FailureCode.format, 'vault.empty');
    }
    if (bytes.length > maxEnvelopeBytes) {
      throw const VaultException(FailureCode.limit, 'envelope');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on Object {
      throw const VaultException(FailureCode.format, 'vault.json');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const VaultException(FailureCode.format, 'vault.json');
    }
    if (decoded['type'] != 'local') {
      // Matches the envelope parser: a well-formed EnCryNote file of another
      // kind (an export) is unsupported as a local vault, not corrupt.
      throw const VaultException(FailureCode.unsupported, 'vault.type');
    }
    final version = decoded['version'];
    if (version is! int) {
      throw const VaultException(FailureCode.format, 'vault.version');
    }
    if (version != 1) {
      throw const VaultException(FailureCode.unsupported, 'vault.version');
    }
    if (decoded['suite'] != _suiteV1) {
      throw const VaultException(FailureCode.unsupported, 'vault.suite');
    }
  }
}
