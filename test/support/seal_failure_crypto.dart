import 'dart:typed_data';

import 'package:hello_flutter/vault/vault_crypto.dart';
import 'package:hello_flutter/vault/vault_types.dart';

/// Test-only crypto whose seal can fail on demand, so the frozen-save and
/// lock-after-seal-failure paths can be driven deterministically.
class SealFailureCrypto extends VaultCrypto {
  bool failSeal = false;
  int sealAttempts = 0;

  @override
  Future<Uint8List> seal(UnlockedVault vault, VaultData data, int revision) {
    sealAttempts++;
    if (failSeal) {
      throw const VaultException(FailureCode.storage, 'seal.test');
    }
    return super.seal(vault, data, revision);
  }
}
