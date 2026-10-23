import 'dart:async';
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
///   flutter test integration_test/crypto_platform_test.dart -d macos --no-uninstall
///   `flutter test integration_test/crypto_platform_test.dart -d DEVICE_ID --no-uninstall`
///
/// Use `--no-uninstall` on an owned or disposable target with no personal vault;
/// the test build uses the product application id and the tool uninstalls it by
/// default, deleting that package's private data. See
/// `docs/testing/native-checks.md`.
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

    // The seal itself must yield the main isolate on this platform. The sampler
    // runs only while `seal` is pending: the follow-up unlock KDF and any
    // trailing delay are outside the window, so a tick here can only come from
    // the seal running elsewhere.
    final largeNote = Note(
      id: 'dddddddddddddddddddddddddddddddd',
      title: 'large',
      markdown: 'z' * (4 * 1024 * 1024),
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
    );
    var ticks = 0;
    var lastTick = DateTime.now();
    var worstGapMs = 0;
    final timer = Timer.periodic(const Duration(milliseconds: 1), (_) {
      ticks++;
      final now = DateTime.now();
      final gap = now.difference(lastTick).inMilliseconds;
      if (gap > worstGapMs) worstGapMs = gap;
      lastTick = now;
    });
    final largeWatch = Stopwatch()..start();
    final largeSealed = await crypto.seal(
      resealed,
      VaultData(notes: [largeNote]),
      3,
    );
    largeWatch.stop();
    timer.cancel();
    expect(
      ticks,
      greaterThan(0),
      reason:
          'the seal blocked the event loop on this platform '
          '(ticks=$ticks, worstGap=${worstGapMs}ms)',
    );
    final largeReopened = await crypto.unlock(largeSealed, localPassword);
    expect(largeReopened.data.notes.single.markdown.length, 4 * 1024 * 1024);

    // Recorded in docs/security/crypto-profile.md as diagnostics, not a bound.
    // ignore: avoid_print
    print(
      'crypto-profile v1 create=${createWatch.elapsedMilliseconds}ms '
      'unlock=${unlockWatch.elapsedMilliseconds}ms '
      'recover=${recoverWatch.elapsedMilliseconds}ms '
      'seal=${sealedWatch.elapsedMilliseconds}ms '
      'envelope=${created.envelope.length}B '
      'largeSeal=${largeWatch.elapsedMilliseconds}ms '
      'sealTicks=$ticks sealWorstGap=${worstGapMs}ms',
    );
    expect(created.envelope, isA<Uint8List>());
  });
}
