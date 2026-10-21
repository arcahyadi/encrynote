import 'dart:io';

import 'package:hello_flutter/platform/native_bridge.dart';
import 'package:hello_flutter/vault/vault_types.dart';

/// Stages of a native commit, in the order the native handler performs them.
enum CommitStage { backup, replace, sync }

typedef CommitCall = ({
  String stagedPath,
  String activePath,
  String previousPath,
});

/// In-memory [NativeBridge] that mirrors the native commit sequence with plain
/// `dart:io` renames, so store tests can break one stage at a time.
class FakeNativeBridge implements NativeBridge {
  /// Fails the next commit at [stage]; the failing stage does not take effect.
  CommitStage? failAt;

  /// Shorthand for `failAt = CommitStage.backup`, used by the brief's snippet.
  bool failNextCommit = false;

  int commitCount = 0;
  final List<CommitCall> calls = [];

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

    final failure = failAt ?? (failNextCommit ? CommitStage.backup : null);
    failAt = null;
    failNextCommit = false;

    if (failure == CommitStage.backup) {
      throw const VaultException(FailureCode.storage, 'commit.backup');
    }
    final active = File(activePath);
    if (await active.exists()) await active.rename(previousPath);
    if (failure == CommitStage.replace) {
      throw const VaultException(FailureCode.storage, 'commit.replace');
    }
    await File(stagedPath).rename(activePath);
    if (failure == CommitStage.sync) {
      throw const VaultException(FailureCode.storage, 'commit.sync');
    }
  }
}
