import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hello_flutter/platform/native_bridge.dart';
import 'package:hello_flutter/vault/vault_crypto.dart';
import 'package:hello_flutter/vault/vault_store.dart';
import 'package:hello_flutter/vault/vault_types.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import '../test/support/fixtures.dart';

/// Exercises the real native commit handler on the target platform.
///
/// Usage:
///   flutter test integration_test/storage_platform_test.dart -d macos --no-uninstall
///   flutter test integration_test/storage_platform_test.dart -d DEVICE_ID --no-uninstall
///
/// Use `--no-uninstall` on an owned or disposable target with no personal vault;
/// the test build uses the product application id and the tool uninstalls it by
/// default, deleting that package's private data. See
/// `docs/testing/native-checks.md`.
///
/// Every run writes into its own fresh subdirectory of the app's private
/// support root (`encrynote_test_<pid>_<microseconds>`) and deletes only that
/// directory. The live `vault.enc`/`vault.previous`/`vault.next` in the root are
/// never read, moved, overwritten or deleted, so a killed test run cannot damage
/// a developer's vault. A leftover test directory is inert ciphertext.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final crypto = VaultCrypto();
  final native = const MethodChannelNativeBridge();

  late Directory root;
  late Directory dir;
  late VaultStore store;
  final liveFingerprint = <String, String>{};

  File file(String name) => File('${dir.path}/$name');

  /// Size and mtime only; the live bytes are never read.
  Future<String> fingerprint(File f) async {
    if (!await f.exists()) return 'absent';
    final stat = await f.stat();
    return '${stat.size}:${stat.modified.microsecondsSinceEpoch}';
  }

  setUpAll(() async {
    root = await getApplicationSupportDirectory();
    for (final name in ['vault.enc', 'vault.previous', 'vault.next']) {
      liveFingerprint[name] = await fingerprint(File('${root.path}/$name'));
    }
    dir = Directory(
      '${root.path}/encrynote_test_${pid}_'
      '${DateTime.now().microsecondsSinceEpoch}',
    );
    await dir.create(recursive: true);
    // ignore: avoid_print
    print('storage test directory: ${dir.path}');
  });

  tearDownAll(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  setUp(() async {
    for (final name in ['vault.enc', 'vault.previous', 'vault.next']) {
      final f = file(name);
      if (await f.exists()) await f.delete();
    }
    store = VaultStore(directory: dir, native: native);
  });

  testWidgets('native commit replaces the vault and keeps the previous one', (
    tester,
  ) async {
    final created = await crypto.createVault(
      localPassword,
      fixtureRecovery,
      fixtureData,
    );
    final updated = await crypto.seal(created, fixtureData, 2);

    expect(await store.read(), isNull);
    await store.commit(created.envelope);
    expect(await store.read(), orderedEquals(created.envelope));
    expect(await file('vault.next').exists(), isFalse);

    await store.commit(updated);
    expect(await store.read(), orderedEquals(updated));
    expect(
      await file('vault.previous').readAsBytes(),
      orderedEquals(created.envelope),
    );
    final reopened = await crypto.unlock(updated, localPassword);
    expect(reopened.revision, 2);
    expect(
      reopened.data.notes.single.markdown,
      fixtureData.notes.single.markdown,
    );
  });

  testWidgets('interrupted replacement loads the previous generation', (
    tester,
  ) async {
    final created = await crypto.createVault(
      localPassword,
      fixtureRecovery,
      fixtureData,
    );
    final updated = await crypto.seal(created, fixtureData, 2);
    await store.commit(created.envelope);
    await store.commit(updated);

    // Simulate an interruption between the backup rename and the replacement.
    await file('vault.enc').delete();
    expect(await store.read(), orderedEquals(created.envelope));
    expect((await crypto.unlock(created.envelope, localPassword)).revision, 1);
  });

  testWidgets('native commit accepts a unique app-private subdirectory', (
    tester,
  ) async {
    // Positive isolation case: the private root itself is not the only accepted
    // location, and this run's own subdirectory is a valid vault directory.
    final created = await crypto.createVault(
      localPassword,
      fixtureRecovery,
      fixtureData,
    );
    await store.commit(created.envelope);
    expect(await store.read(), orderedEquals(created.envelope));
    expect(dir.path.startsWith(root.path), isTrue);
  });

  testWidgets('native handler refuses escaped and external paths', (
    tester,
  ) async {
    final created = await crypto.createVault(
      localPassword,
      fixtureRecovery,
      fixtureData,
    );
    await file('vault.next').writeAsBytes(created.envelope, flush: true);

    // A symlinked directory that resolves outside the private root must be
    // rejected even though its parent path text starts with the root.
    final escape = Link('${dir.path}/escape');
    await escape.create('${root.parent.path}/encrynote_escape_target');
    final escapeDir = Directory('${root.parent.path}/encrynote_escape_target');
    await escapeDir.create(recursive: true);

    final rejected = <String>[
      '${root.parent.path}/encrynote_outside/vault.enc',
      '${escape.path}/vault.enc',
      '${dir.path}/nested/vault.enc',
    ];
    try {
      for (final activePath in rejected) {
        await expectLater(
          native.commitVault(
            stagedPath: file('vault.next').path,
            activePath: activePath,
            previousPath: file('vault.previous').path,
          ),
          throwsA(
            isA<VaultException>().having(
              (e) => e.code,
              'code',
              FailureCode.storage,
            ),
          ),
          reason: 'activePath $activePath must be refused',
        );
        expect(await File(activePath).exists(), isFalse);
      }
    } finally {
      if (await escape.exists()) await escape.delete();
      if (await escapeDir.exists()) await escapeDir.delete(recursive: true);
    }

    // The staged bytes were never consumed and no vault appeared.
    expect(await file('vault.next').exists(), isTrue);
    expect(await store.read(), isNull);
  });

  testWidgets('a failed native commit leaves the last vault readable', (
    tester,
  ) async {
    final created = await crypto.createVault(
      localPassword,
      fixtureRecovery,
      fixtureData,
    );
    await store.commit(created.envelope);

    // The staged file is already gone after a successful commit, so the native
    // handler must fail without touching the committed vault.
    await expectLater(
      native.commitVault(
        stagedPath: file('vault.next').path,
        activePath: file('vault.enc').path,
        previousPath: file('vault.previous').path,
      ),
      throwsA(isA<VaultException>()),
    );
    expect(await store.read(), orderedEquals(created.envelope));
    expect((await crypto.unlock(created.envelope, localPassword)).revision, 1);
  });

  testWidgets('a post-replace native fault restores the previous vault', (
    tester,
  ) async {
    // Make the staged file unreadable so the post-replace file sync fails after
    // vault.enc has already been replaced. The handler must roll the previous
    // generation back, not report success and not leave the new bytes active.
    final created = await crypto.createVault(
      localPassword,
      fixtureRecovery,
      fixtureData,
    );
    final updated = await crypto.seal(created, fixtureData, 2);
    await store.commit(created.envelope);

    final staged = file('vault.next');
    await staged.writeAsBytes(updated, flush: true);
    await Process.run('chmod', ['000', staged.path]);
    addTearDown(() async {
      if (await staged.exists()) {
        await Process.run('chmod', ['600', staged.path]);
      }
    });

    await expectLater(
      native.commitVault(
        stagedPath: staged.path,
        activePath: file('vault.enc').path,
        previousPath: file('vault.previous').path,
      ),
      throwsA(
        isA<VaultException>().having(
          (e) => e.code,
          'code',
          FailureCode.storage,
        ),
      ),
    );

    // Rollback succeeded: the old generation is active again and still opens,
    // and the new bytes are no longer the active vault.
    final onDisk = await store.read();
    expect(onDisk, orderedEquals(created.envelope));
    expect(onDisk, isNot(orderedEquals(updated)));
    expect((await crypto.unlock(onDisk!, localPassword)).revision, 1);
  });

  testWidgets('the live vault names in the private root are untouched', (
    tester,
  ) async {
    // Every test above ran entirely inside this run's own subdirectory. The live
    // names in the private root are checked by size+mtime only, so this test
    // never reads a developer's vault bytes.
    expect(dir.parent.path, root.path);
    for (final name in ['vault.enc', 'vault.previous', 'vault.next']) {
      expect(
        await fingerprint(File('${root.path}/$name')),
        liveFingerprint[name],
        reason: 'the live $name must not change',
      );
    }
  });
}
