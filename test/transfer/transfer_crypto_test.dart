import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hello_flutter/vault/vault_crypto.dart';
import 'package:hello_flutter/vault/vault_types.dart';

import '../support/fixtures.dart';

Matcher _rejectedAs(FailureCode code) =>
    throwsA(isA<VaultException>().having((e) => e.code, 'code', code));

Map<String, dynamic> _json(Uint8List bytes) =>
    jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;

Uint8List _reencode(Map<String, dynamic> json) =>
    Uint8List.fromList(utf8.encode(jsonEncode(json)));

/// Transfer format tests: the export is its own envelope with its own key path.
void main() {
  final crypto = VaultCrypto();
  const exportPassword = 'export-1234';

  test('export and import round-trip every note field', () async {
    final bytes = await crypto.exportNotes(fixtureData.notes, exportPassword);
    final notes = await crypto.importExport(bytes, exportPassword);

    expect(notes, hasLength(1));
    final note = notes.single;
    expect(note.id, fixtureData.notes.single.id);
    expect(note.title, fixtureData.notes.single.title);
    expect(note.markdown, fixtureData.notes.single.markdown);
    expect(note.createdAt, fixtureData.notes.single.createdAt);
    expect(note.updatedAt, fixtureData.notes.single.updatedAt);
  });

  test('only the export password opens an export', () async {
    final bytes = await crypto.exportNotes(fixtureData.notes, exportPassword);

    await expectLater(
      crypto.importExport(bytes, localPassword),
      _rejectedAs(FailureCode.credentials),
    );
    await expectLater(
      crypto.importExport(bytes, 'wrong-1234'),
      _rejectedAs(FailureCode.credentials),
    );
    // The app password path and the recovery path never reach the payload.
    await expectLater(
      crypto.unlock(bytes, localPassword),
      _rejectedAs(FailureCode.unsupported),
    );
    await expectLater(
      crypto.recover(bytes, fixtureRecovery.answers),
      _rejectedAs(FailureCode.unsupported),
    );
    expect(
      () => crypto.readRecoveryQuestions(bytes),
      _rejectedAs(FailureCode.unsupported),
    );
  });

  test(
    'an export password equal to the app password stays export-only',
    () async {
      final created = await crypto.createVault(
        localPassword,
        fixtureRecovery,
        fixtureData,
      );
      final bytes = await crypto.exportNotes(fixtureData.notes, localPassword);

      expect(
        (await crypto.importExport(bytes, localPassword)).single.markdown,
        fixtureData.notes.single.markdown,
      );
      await expectLater(
        crypto.unlock(bytes, localPassword),
        _rejectedAs(FailureCode.unsupported),
      );
      await expectLater(
        crypto.recover(bytes, fixtureRecovery.answers),
        _rejectedAs(FailureCode.unsupported),
      );
      // The local vault still opens with its own password.
      final reopened = await crypto.unlock(created.envelope, localPassword);
      expect(reopened.data.notes.single.title, fixtureData.notes.single.title);
    },
  );

  test('export carries no local wrapper, recovery or key material', () async {
    final bytes = await crypto.exportNotes(fixtureData.notes, exportPassword);
    final json = _json(bytes);

    expect(json.keys.toSet(), {'type', 'version', 'suite', 'kdf', 'payload'});
    expect(json['type'], 'export');
    expect(json['version'], 1);
    expect(json['suite'], 'argon2id-aes256gcm');
    expect(json.containsKey('vaultId'), isFalse);
    expect(json.containsKey('passwordWrap'), isFalse);
    expect(json.containsKey('recovery'), isFalse);
    final kdf = json['kdf'] as Map<String, dynamic>;
    expect(kdf.keys.toSet(), {
      'algorithm',
      'memory',
      'iterations',
      'parallelism',
      'hashLength',
      'salt',
    });
    expect(kdf['algorithm'], 'argon2id');
    expect(kdf['memory'], 19456);
    expect(kdf['iterations'], 2);
    expect(kdf['parallelism'], 1);
    expect(kdf['hashLength'], 32);
    expect(base64Decode(kdf['salt'] as String), hasLength(16));
    expect(
      base64Decode((json['payload'] as Map)['nonce'] as String),
      hasLength(12),
    );

    // No plaintext and no local credential material inside the file.
    final text = utf8.decode(bytes);
    expect(text.contains(fixtureData.notes.single.markdown), isFalse);
    expect(text.contains('Fixture Note Title'), isFalse);
    expect(text.contains('passwordWrap'), isFalse);
    expect(text.contains(fixtureRecovery.questions.first), isFalse);
  });

  test('every export uses a fresh salt and nonce', () async {
    final first = _json(
      await crypto.exportNotes(fixtureData.notes, exportPassword),
    );
    final second = _json(
      await crypto.exportNotes(fixtureData.notes, exportPassword),
    );

    expect(
      (first['kdf'] as Map)['salt'],
      isNot((second['kdf'] as Map)['salt']),
    );
    expect(
      (first['payload'] as Map)['nonce'],
      isNot((second['payload'] as Map)['nonce']),
    );
    expect(
      (first['payload'] as Map)['ciphertext'],
      isNot((second['payload'] as Map)['ciphertext']),
    );
  });

  test('tampered ciphertext, tag or header is rejected', () async {
    final bytes = await crypto.exportNotes(fixtureData.notes, exportPassword);

    for (final field in ['ciphertext', 'tag']) {
      final json = _json(bytes);
      final payload = json['payload'] as Map<String, dynamic>;
      final raw = base64Decode(payload[field] as String);
      raw[0] ^= 0x01;
      payload[field] = base64Encode(raw);
      await expectLater(
        crypto.importExport(_reencode(json), exportPassword),
        _rejectedAs(FailureCode.credentials),
      );
    }

    // The salt is authenticated through the AAD, not just the KDF.
    final saltJson = _json(bytes);
    final kdf = saltJson['kdf'] as Map<String, dynamic>;
    final salt = base64Decode(kdf['salt'] as String);
    salt[0] ^= 0x01;
    kdf['salt'] = base64Encode(salt);
    await expectLater(
      crypto.importExport(_reencode(saltJson), exportPassword),
      _rejectedAs(FailureCode.credentials),
    );

    final typeJson = _json(bytes)..['type'] = 'local';
    await expectLater(
      crypto.importExport(_reencode(typeJson), exportPassword),
      _rejectedAs(FailureCode.unsupported),
    );
  });

  test('malformed export headers fail as VaultException', () async {
    final bytes = await crypto.exportNotes(fixtureData.notes, exportPassword);

    for (final tamper in <void Function(Map<String, dynamic>)>[
      (json) => json.remove('kdf'),
      (json) => (json['kdf'] as Map).remove('salt'),
      (json) => (json['kdf'] as Map)['memory'] = 1024,
      (json) => json['payload'] = 'nope',
      (json) => json['version'] = 2,
      (json) => json['suite'] = 'other',
    ]) {
      final json = _json(bytes);
      tamper(json);
      await expectLater(
        crypto.importExport(_reencode(json), exportPassword),
        throwsA(isA<VaultException>()),
      );
    }

    await expectLater(
      crypto.importExport(Uint8List(0), exportPassword),
      _rejectedAs(FailureCode.format),
    );
    await expectLater(
      crypto.importExport(
        Uint8List.fromList(utf8.encode('{"type":"export"}')),
        exportPassword,
      ),
      throwsA(isA<VaultException>()),
    );
  });

  test('a short export password is rejected before any crypto', () async {
    await expectLater(
      crypto.exportNotes(fixtureData.notes, 'short'),
      _rejectedAs(FailureCode.credentials),
    );
    final bytes = await crypto.exportNotes(fixtureData.notes, exportPassword);
    await expectLater(
      crypto.importExport(bytes, 'short'),
      _rejectedAs(FailureCode.credentials),
    );
  });

  test('a local vault cannot be imported as an export', () async {
    final created = await crypto.createVault(
      localPassword,
      fixtureRecovery,
      fixtureData,
    );
    await expectLater(
      crypto.importExport(created.envelope, localPassword),
      _rejectedAs(FailureCode.unsupported),
    );
  });

  test('a writer never emits an export its own reader rejects', () async {
    // A payload at the limit is rejected explicitly, never truncated.
    final huge = Note(
      id: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      title: 'huge',
      markdown: 'x' * (maxPayloadBytes + 1),
      createdAt: DateTime.utc(2026, 10, 22),
      updatedAt: DateTime.utc(2026, 10, 22),
    );
    await expectLater(
      crypto.exportNotes([huge], exportPassword),
      _rejectedAs(FailureCode.limit),
    );

    // The largest accepted payload round-trips through the same reader.
    final legal = Note(
      id: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      title: 'legal',
      markdown: 'y' * (maxPayloadBytes - 1024),
      createdAt: DateTime.utc(2026, 10, 22),
      updatedAt: DateTime.utc(2026, 10, 22),
    );
    final bytes = await crypto.exportNotes([legal], exportPassword);
    expect(bytes.length, lessThanOrEqualTo(maxEnvelopeBytes));
    final notes = await crypto.importExport(bytes, exportPassword);
    expect(notes.single.markdown.length, legal.markdown.length);
  });
}
