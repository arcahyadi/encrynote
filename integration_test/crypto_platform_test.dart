import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hello_flutter/vault/vault_crypto.dart';
import 'package:hello_flutter/vault/vault_types.dart';
import 'package:integration_test/integration_test.dart';

import '../test/support/fixtures.dart';

/// Runs the real v1 crypto profile on the target platform.
///
/// Usage:
///   flutter test integration_test/crypto_platform_test.dart -d macos
///   `flutter test integration_test/crypto_platform_test.dart -d DEVICE_ID`
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final crypto = VaultCrypto();

  testWidgets('v1 profile round-trips on this platform', (tester) async {
    final createWatch = Stopwatch()..start();
    final created = await crypto.createVault(
      localPassword,
      fixtureRecovery,
      fixtureData,
    );
    createWatch.stop();

    final unlockWatch = Stopwatch()..start();
    final reopened = await crypto.unlock(created.envelope, localPassword);
    unlockWatch.stop();

    expect(
      reopened.data.notes.single.markdown,
      fixtureData.notes.single.markdown,
    );

    final recoverWatch = Stopwatch()..start();
    final recovered = await crypto.recover(
      created.envelope,
      fixtureRecovery.answers,
    );
    recoverWatch.stop();
    expect(
      await recovered.dataKey.extractBytes(),
      await reopened.dataKey.extractBytes(),
    );

    final sealedWatch = Stopwatch()..start();
    final sealed = await crypto.seal(reopened, reopened.data, 2);
    sealedWatch.stop();
    final resealed = await crypto.unlock(sealed, localPassword);
    expect(resealed.revision, 2);

    // Amended header authentication must hold on the target platform too.
    final rewrapped = await crypto.rewrapPassword(resealed, 'new-pass-1234', 3);
    final afterRewrap = await crypto.unlock(rewrapped, 'new-pass-1234');
    expect(
      afterRewrap.data.notes.single.markdown,
      fixtureData.notes.single.markdown,
    );
    final recoveredAfterRewrap = await crypto.recover(
      rewrapped,
      fixtureRecovery.answers,
    );
    expect(
      recoveredAfterRewrap.data.notes.single.markdown,
      fixtureData.notes.single.markdown,
    );

    final header = jsonDecode(utf8.decode(rewrapped)) as Map<String, dynamic>;
    final questions =
        (header['recovery'] as Map<String, dynamic>)['questions']
            as List<dynamic>;
    questions[0] = 'Attacker prompt?';
    final tampered = Uint8List.fromList(utf8.encode(jsonEncode(header)));
    await expectLater(
      crypto.unlock(tampered, 'new-pass-1234'),
      throwsA(
        isA<VaultException>().having((e) => e.code, 'code', FailureCode.format),
      ),
    );

    await expectLater(
      crypto.unlock(created.envelope, 'wrong-1234'),
      throwsA(isA<VaultException>()),
    );

    // Recorded in docs/security/crypto-profile.md.
    // ignore: avoid_print
    print(
      'crypto-profile v1 create=${createWatch.elapsedMilliseconds}ms '
      'unlock=${unlockWatch.elapsedMilliseconds}ms '
      'recover=${recoverWatch.elapsedMilliseconds}ms '
      'seal=${sealedWatch.elapsedMilliseconds}ms '
      'envelope=${created.envelope.length}B',
    );
    expect(created.envelope, isA<Uint8List>());
  });
}
