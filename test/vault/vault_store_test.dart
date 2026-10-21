import 'dart:async';
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

  test('a read during a replacement never returns the older generation', () async {
    final created = await crypto.createVault(
      localPassword,
      fixtureRecovery,
      fixtureData,
    );
    final updated = await crypto.seal(created, fixtureData, 2);
    await store.commit(created.envelope);

    // Deterministic M-1 regression. A read is started first and held open inside
    // the store; a commit requested afterwards must queue behind it instead of
    // reaching the window where vault.enc has moved to vault.previous. Without
    // the shared queue the read resumes in that window and silently returns the
    // older generation.
    final gateEntered = Completer<void>();
    final gateRelease = Completer<void>();
    var gateCalls = 0;
    store.debugReadGate = () async {
      if (gateCalls++ > 0) return;
      gateEntered.complete();
      await gateRelease.future;
    };

    final readResult = store.read();
    await gateEntered.future;

    final commitsBefore = native.commitCount;
    final commitResult = store.commit(updated);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(
      native.commitCount,
      commitsBefore,
      reason: 'the commit must queue behind the in-flight read',
    );

    gateRelease.complete();
    expect(await readResult, orderedEquals(created.envelope));
    await commitResult;
    expect(await store.read(), orderedEquals(updated));
  });

  test('a read that starts mid-replacement waits for the replacement', () async {
    final created = await crypto.createVault(
      localPassword,
      fixtureRecovery,
      fixtureData,
    );
    final updated = await crypto.seal(created, fixtureData, 2);
    await store.commit(created.envelope);

    // Hold the commit in the window where vault.enc is gone and the staged file
    // has not been renamed yet, then read: the read must wait and see the new
    // generation, never the previous one.
    native.holdAt = CommitStage.backupSync;
    final commitResult = store.commit(updated);
    await native.entered.future;
    expect(await file('vault.enc').exists(), isFalse);

    final readResult = store.read();
    native.release();
    await commitResult;

    expect(await readResult, orderedEquals(updated));
  });

  test('a read queued after a commit sees that commit', () async {
    final created = await crypto.createVault(
      localPassword,
      fixtureRecovery,
      fixtureData,
    );
    final updated = await crypto.seal(created, fixtureData, 2);
    await store.commit(created.envelope);

    native.holdAt = CommitStage.fileSync;
    final commitResult = store.commit(updated);
    await native.entered.future;
    final readResult = store.read();
    native.release();
    await commitResult;

    expect(await readResult, orderedEquals(updated));
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
    test(
      'commit failure at ${stage.name} leaves the old vault active',
      () async {
        final created = await crypto.createVault(
          localPassword,
          fixtureRecovery,
          fixtureData,
        );
        final updated = await crypto.seal(created, fixtureData, 2);
        await store.commit(created.envelope);

        native.failAt = stage;
        await expectLater(
          store.commit(updated),
          throwsA(isA<VaultException>()),
        );

        // Every stage, including the ones after the replacement, must put the
        // previous generation back rather than leave a failed commit half-applied.
        expect(await store.read(), orderedEquals(created.envelope));
        expect(
          await file('vault.enc').readAsBytes(),
          orderedEquals(created.envelope),
        );
        expect(
          (await crypto.unlock(created.envelope, localPassword)).revision,
          1,
        );
      },
    );
  }

  for (final stage in [CommitStage.fileSync, CommitStage.dirSync]) {
    test(
      'post-replace fault at ${stage.name} does not change credentials',
      () async {
        final created = await crypto.createVault(
          'old-pass-1234',
          fixtureRecovery,
          fixtureData,
        );
        final rewrapped = await crypto.rewrapPassword(
          created,
          'new-pass-1234',
          2,
        );
        await store.commit(created.envelope);

        native.failAt = stage;
        await expectLater(
          store.commit(rewrapped),
          throwsA(isA<VaultException>()),
        );

        // Task 3 reports a failed credential commit and keeps the old password.
        // The bytes on disk must agree, or the user is locked out of the notes.
        final onDisk = (await store.read())!;
        expect(onDisk, orderedEquals(created.envelope));
        final opened = await crypto.unlock(onDisk, 'old-pass-1234');
        expect(opened.revision, 1);
        await expectLater(
          crypto.unlock(onDisk, 'new-pass-1234'),
          _rejectedAs(FailureCode.credentials),
        );
      },
    );
  }

  test(
    'an unrollbackable post-replace fault reports uncertain, not success',
    () async {
      final created = await crypto.createVault(
        localPassword,
        fixtureRecovery,
        fixtureData,
      );
      final updated = await crypto.seal(created, fixtureData, 2);
      await store.commit(created.envelope);

      native.failAt = CommitStage.dirSync;
      native.rollbackFails = true;
      await expectLater(
        store.commit(updated),
        throwsA(
          isA<VaultException>()
              .having((e) => e.code, 'code', FailureCode.storage)
              .having((e) => e.detail, 'detail', 'commit.uncertain'),
        ),
      );

      // The bytes are not rolled back and must not be claimed as the old vault:
      // whatever is readable is a complete envelope, and the caller is told the
      // outcome is uncertain.
      final readable = await store.read();
      expect(readable, isNotNull);
      await crypto.unlock(readable!, localPassword);
    },
  );

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

  test('an oversize active file is rejected without reading it', () async {
    final created = await crypto.createVault(
      localPassword,
      fixtureRecovery,
      fixtureData,
    );
    await store.commit(created.envelope);

    // Sparse file: allocating it would be the failure this guards against, so
    // only its length is written.
    final raf = await file('vault.enc').open(mode: FileMode.write);
    await raf.truncate(maxEnvelopeBytes + 1);
    await raf.close();

    await expectLater(store.read(), _rejectedAs(FailureCode.limit));
  });

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
