import 'dart:async';

import 'package:flutter/services.dart';

import '../vault/vault_types.dart';

/// An opaque native handle for one file the user chose in the OS picker.
///
/// The token names a grant the native side holds for the current selection; it
/// is not a path, so no code path can read an arbitrary file with it.
class PickedImport {
  const PickedImport({required this.token, required this.name, this.length});

  final String token;

  /// The chosen file's base name, used as a Markdown note title.
  final String name;

  /// Reported size in bytes when the platform knows it.
  final int? length;
}

/// The single native boundary for replacing the vault on disk, privacy, window
/// focus, and file access to what the user picked.
///
/// The native side owns the durability-critical part: it validates that all
/// three paths are canonical siblings inside the OS-provided private app
/// directory, keeps the previous generation, replaces the active file, and
/// syncs file and directory metadata before reporting success.
abstract interface class NativeBridge {
  Future<void> commitVault({
    required String stagedPath,
    required String activePath,
    required String previousPath,
  });

  /// `true` when the app window gained input focus, `false` when it lost it.
  Stream<bool> get focusChanges;

  /// Covers the native surface with an opaque view, or removes that cover.
  Future<void> setPrivacyShield(bool visible);

  /// Opens the OS open-file picker. `null` means the user cancelled.
  Future<PickedImport?> pickImport();

  /// Streams the picked file, refusing more than [maxBytes] without a known
  /// length. The token must still be held by [pickImport].
  Future<Uint8List> readImport(String token, {required int maxBytes});

  /// Drops the native grant for [token]; safe to call once per pick.
  Future<void> releaseImport(String token);

  /// Shows the OS save panel and writes [bytes] to the chosen file.
  ///
  /// `false` means the user cancelled; a thrown [VaultException] means the save
  /// failed and no file was written.
  Future<bool> saveExport(Uint8List bytes, {required String fileName});
}

class MethodChannelNativeBridge implements NativeBridge {
  const MethodChannelNativeBridge({
    MethodChannel channel = const MethodChannel('encrynote/platform'),
    EventChannel focusChannel = const EventChannel('encrynote/focus'),
  }) : _channel = channel, // ignore: prefer_initializing_formals
       _focusChannel = focusChannel; // ignore: prefer_initializing_formals

  final MethodChannel _channel;
  final EventChannel _focusChannel;

  @override
  Stream<bool> get focusChanges => _focusChannel
      .receiveBroadcastStream()
      .where((event) => event is bool)
      .cast<bool>();

  @override
  Future<void> commitVault({
    required String stagedPath,
    required String activePath,
    required String previousPath,
  }) async {
    try {
      await _channel.invokeMethod<void>('commitVault', <String, String>{
        'stagedPath': stagedPath,
        'activePath': activePath,
        'previousPath': previousPath,
      });
    } on PlatformException catch (error) {
      throw VaultException(FailureCode.storage, error.message ?? error.code);
    } on MissingPluginException {
      throw const VaultException(FailureCode.storage, 'commit.unavailable');
    }
  }

  @override
  Future<void> setPrivacyShield(bool visible) async {
    try {
      await _channel.invokeMethod<void>('setPrivacyShield', visible);
    } on PlatformException catch (error) {
      throw VaultException(FailureCode.storage, error.message ?? error.code);
    } on MissingPluginException {
      throw const VaultException(FailureCode.storage, 'shield.unavailable');
    }
  }

  @override
  Future<PickedImport?> pickImport() async {
    try {
      final result = await _channel.invokeMapMethod<String, Object?>(
        'pickImport',
      );
      if (result == null) return null;
      final token = result['token'] as String?;
      final name = result['name'] as String?;
      if (token == null || name == null) {
        throw const VaultException(FailureCode.storage, 'pick.result');
      }
      final length = result['length'];
      return PickedImport(
        token: token,
        name: name,
        length: length is int ? length : null,
      );
    } on PlatformException catch (error) {
      throw VaultException(FailureCode.storage, error.message ?? error.code);
    } on MissingPluginException {
      throw const VaultException(FailureCode.storage, 'pick.unavailable');
    }
  }

  @override
  Future<Uint8List> readImport(String token, {required int maxBytes}) async {
    try {
      final bytes = await _channel.invokeMethod<Uint8List>(
        'readImport',
        <String, Object?>{'token': token, 'maxBytes': maxBytes},
      );
      if (bytes == null) {
        throw const VaultException(FailureCode.storage, 'read.empty');
      }
      return bytes;
    } on PlatformException catch (error) {
      throw VaultException(_failure(error), error.message ?? error.code);
    } on MissingPluginException {
      throw const VaultException(FailureCode.storage, 'read.unavailable');
    }
  }

  @override
  Future<void> releaseImport(String token) async {
    try {
      await _channel.invokeMethod<void>('releaseImport', token);
    } on PlatformException {
      // A grant that cannot be dropped is already unusable to Dart; nothing to
      // report to a user who did not ask for this call.
    } on MissingPluginException {
      // Same: the platform owns the grant, not the session.
    }
  }

  @override
  Future<bool> saveExport(Uint8List bytes, {required String fileName}) async {
    try {
      return await _channel.invokeMethod<bool>('saveExport', <String, Object?>{
            'bytes': bytes,
            'fileName': fileName,
          }) ??
          false;
    } on PlatformException catch (error) {
      throw VaultException(_failure(error), error.message ?? error.code);
    } on MissingPluginException {
      throw const VaultException(FailureCode.storage, 'save.unavailable');
    }
  }

  /// Native read/save failures are classified by the code the bridge sends, so
  /// an oversized stream still surfaces as [FailureCode.limit].
  FailureCode _failure(PlatformException error) => switch (error.code) {
    'limit' => FailureCode.limit,
    'format' => FailureCode.format,
    'unsupported' => FailureCode.unsupported,
    _ => FailureCode.storage,
  };
}
