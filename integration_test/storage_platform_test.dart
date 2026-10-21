import 'dart:io';
import 'dart:typed_data';

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
///   flutter test integration_test/storage_platform_test.dart -d macos
///   flutter test integration_test/storage_platform_test.dart -d DEVICE_ID
///
/// The commit target is the app's real private support directory, because the
/// native handler accepts nothing else. Any vault already there is saved and
/// restored, so running this against a development build keeps its data.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final crypto = VaultCrypto();
  final native = const MethodChannelNativeBridge();

  const names = ['vault.enc', 'vault.previous', 'vault.next'];
  late Directory dir;
  late VaultStore store;
  final saved = <String, Uint8List?>{};

  File file(String name) => File('${dir.path}/$name');

  setUpAll(() async {
    dir = await getApplicationSupportDirectory();
    for (final name in names) {
      final f = file(name);
      saved[name] = await f.exists() ? await f.readAsBytes() : null;
      if (await f.exists()) await f.delete();
    }
  });

  tearDownAll(() async {
    for (final name in names) {
      final f = file(name);
      if (await f.exists()) await f.delete();
      final bytes = saved[name];
      if (bytes != null) await f.writeAsBytes(bytes, flush: true);
    }
  });

  setUp(() async {
    for (final name in names) {
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

  testWidgets('native handler refuses paths outside the private directory', (
    tester,
  ) async {
    final created = await crypto.createVault(
      localPassword,
      fixtureRecovery,
      fixtureData,
    );
    await file('vault.next').writeAsBytes(created.envelope, flush: true);

    // A user-chosen import/export location is never a valid commit target, and
    // neither is a subdirectory of the private directory.
    final outside = <String>[
      '${dir.parent.path}/encrynote_outside/vault.enc',
      '${dir.path}/nested/vault.enc',
    ];
    for (final activePath in outside) {
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
      );
      expect(await File(activePath).exists(), isFalse);
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
}
