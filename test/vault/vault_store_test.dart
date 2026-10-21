import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hello_flutter/vault/vault_crypto.dart';
import 'package:hello_flutter/vault/vault_store.dart';
import 'package:hello_flutter/vault/vault_types.dart';

import '../support/fake_native_bridge.dart';
import '../support/fixtures.dart';

Matcher _rejectedAs(FailureCode code) =>
    throwsA(isA<VaultException>().having((e) => e.code, 'code', code));

/// Store tests keep scratch files inside the project and only delete the
/// directory this test created.
void main() {
  final crypto = VaultCrypto();
  late Directory dir;
  late FakeNativeBridge native;
  late VaultStore store;
  var scratch = 0;

  setUp(() async {
    scratch++;
    dir = await Directory(
      '${Directory.current.path}/.dart_tool/test_scratch/vault_store/'
      '${DateTime.now().microsecondsSinceEpoch}_$scratch',
    ).create(recursive: true);
    native = FakeNativeBridge();
    store = VaultStore(directory: dir, native: native);
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  File file(String name) => File('${dir.path}/$name');

  test('staged bytes are encrypted', () async {
    final created = await crypto.createVault(
      localPassword,
      fixtureRecovery,
      fixtureData,
    );
    await store.commit(created.envelope);

    final active = await file('vault.enc').readAsBytes();
    expect(active, orderedEquals(created.envelope));
    final text = utf8.decode(active);
    expect(text, isNot(contains(fixtureData.notes.single.title)));
    expect(text, isNot(contains('ciphertext-marker-42')));
    expect(
      await file('vault.next').exists(),
      isFalse,
      reason: 'staging is consumed by the commit',
    );
    expect(await file('vault.previous').exists(), isFalse);
  });

  test('failure keeps last committed vault', () async {
    final created = await crypto.createVault(
      localPassword,
      fixtureRecovery,
      fixtureData,
    );
    final updated = await crypto.seal(created, fixtureData, 2);
    await store.commit(created.envelope);

    native.failNextCommit = true;
    await expectLater(store.commit(updated), throwsA(isA<VaultException>()));

    expect(await store.read(), orderedEquals(created.envelope));
    expect(
      await file('vault.enc').readAsBytes(),
      orderedEquals(created.envelope),
    );
  });

  test('retry after a failed commit succeeds', () async {
    final created = await crypto.createVault(
      localPassword,
      fixtureRecovery,
      fixtureData,
    );
    final updated = await crypto.seal(created, fixtureData, 2);
    await store.commit(created.envelope);

    native.failAt = CommitStage.replace;
    await expectLater(store.commit(updated), throwsA(isA<VaultException>()));
    await store.commit(updated);
    expect(await store.read(), orderedEquals(updated));
  });

  test('missing primary with previous restores a candidate', () async {
    final created = await crypto.createVault(
      localPassword,
      fixtureRecovery,
      fixtureData,
    );
    final updated = await crypto.seal(created, fixtureData, 2);
    await store.commit(created.envelope);
    await store.commit(updated);
    expect(
      await file('vault.previous').readAsBytes(),
      orderedEquals(created.envelope),
    );

    // Interrupted replacement: the old generation is still the newest complete
    // vault, so it is loaded instead of starting an empty install.
    await file('vault.enc').delete();
    expect(await store.read(), orderedEquals(created.envelope));
  });

  test('truncated primary is not a new install', () async {
    final created = await crypto.createVault(
      localPassword,
      fixtureRecovery,
      fixtureData,
    );
    await store.commit(created.envelope);
    final cut = created.envelope.sublist(0, created.envelope.length ~/ 2);
    await file('vault.enc').writeAsBytes(cut, flush: true);

    await expectLater(store.read(), _rejectedAs(FailureCode.format));
  });

  test(
    'corrupt primary is an error even when a previous generation exists',
    () async {
      final created = await crypto.createVault(
        localPassword,
        fixtureRecovery,
        fixtureData,
      );
      final updated = await crypto.seal(created, fixtureData, 2);
      await store.commit(created.envelope);
      await store.commit(updated);
      await file('vault.enc').writeAsBytes(const <int>[0x7b], flush: true);

      // Falling back here would silently roll back the newest committed notes.
      await expectLater(store.read(), _rejectedAs(FailureCode.format));
    },
  );

  test('wrong password never tries previous wrappers', () async {
    final created = await crypto.createVault(
      'old-pass-1234',
      fixtureRecovery,
      fixtureData,
    );
    await store.commit(created.envelope);
    final rewrapped = await crypto.rewrapPassword(created, 'new-pass-1234', 2);
    await store.commit(rewrapped);
    expect(
      await file('vault.previous').readAsBytes(),
      orderedEquals(created.envelope),
      reason: 'the old generation is on disk but must not be offered',
    );

    final bytes = (await store.read())!;
    expect(bytes, isNot(orderedEquals(created.envelope)));
    await expectLater(
      crypto.unlock(bytes, 'old-pass-1234'),
      _rejectedAs(FailureCode.credentials),
    );
    final opened = await crypto.unlock(bytes, 'new-pass-1234');
    expect(opened.revision, 2);
  });

  for (final stage in CommitStage.values) {
    test('commit failure at ${stage.name} never leaves an empty vault', () async {
      final created = await crypto.createVault(
        localPassword,
        fixtureRecovery,
        fixtureData,
      );
      final updated = await crypto.seal(created, fixtureData, 2);
      await store.commit(created.envelope);

      native.failAt = stage;
      await expectLater(store.commit(updated), throwsA(isA<VaultException>()));

      final recovered = await store.read();
      expect(recovered, isNotNull);
      expect(recovered!, isNotEmpty);
      if (stage == CommitStage.sync) {
        // The replacement already happened; only its durability is unverified,
        // so the store reports the failure and the new bytes stay readable.
        expect(recovered, orderedEquals(updated));
      } else {
        expect(recovered, orderedEquals(created.envelope));
      }
    });
  }

  test(
    'empty, oversized and non-local bytes are refused before staging',
    () async {
      final created = await crypto.createVault(
        localPassword,
        fixtureRecovery,
        fixtureData,
      );
      await expectLater(
        store.commit(Uint8List(0)),
        _rejectedAs(FailureCode.format),
      );
      await expectLater(
        store.commit(Uint8List(maxEnvelopeBytes + 1)),
        _rejectedAs(FailureCode.limit),
      );
      await expectLater(
        store.commit(
          Uint8List.fromList(utf8.encode('{"type":"export","version":1}')),
        ),
        _rejectedAs(FailureCode.unsupported),
      );

      expect(native.commitCount, 0);
      expect(await file('vault.next').exists(), isFalse);
      expect(
        await store.read(),
        isNull,
        reason: 'reading never creates a vault',
      );
      await store.commit(created.envelope);
      expect(await store.read(), orderedEquals(created.envelope));
    },
  );

  test(
    'a newer envelope version reads as unsupported, not as no vault',
    () async {
      final created = await crypto.createVault(
        localPassword,
        fixtureRecovery,
        fixtureData,
      );
      await store.commit(created.envelope);
      final map =
          jsonDecode(utf8.decode(created.envelope)) as Map<String, dynamic>;
      map['version'] = 2;
      await file('vault.enc')
          .writeAsBytes(utf8.encode(jsonEncode(map)), flush: true);

      await expectLater(store.read(), _rejectedAs(FailureCode.unsupported));
    },
  );

  test('concurrent commits leave the last requested vault', () async {
    final first = await crypto.createVault(
      localPassword,
      fixtureRecovery,
      fixtureData,
    );
    final second = await crypto.seal(first, fixtureData, 2);

    await Future.wait([store.commit(first.envelope), store.commit(second)]);
    expect(await store.read(), orderedEquals(second));
  });

  test('a fresh directory reads as null and read does not create it', () async {
    final missing = Directory('${dir.path}/nested');
    final fresh = VaultStore(directory: missing, native: native);
    expect(await fresh.read(), isNull);
    expect(await missing.exists(), isFalse);
    expect(native.commitCount, 0);
  });

  test('commit passes the three sibling paths to the bridge', () async {
    final created = await crypto.createVault(
      localPassword,
      fixtureRecovery,
      fixtureData,
    );
    await store.commit(created.envelope);

    final call = native.calls.single;
    expect(call.activePath, '${dir.path}/vault.enc');
    expect(call.stagedPath, '${dir.path}/vault.next');
    expect(call.previousPath, '${dir.path}/vault.previous');
  });
}
