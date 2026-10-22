import 'dart:async';

import 'package:flutter/services.dart';

import '../vault/vault_types.dart';

/// The single native boundary for replacing the vault on disk, privacy, and
/// window focus.
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
}
