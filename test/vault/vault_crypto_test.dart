import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hello_flutter/vault/vault_crypto.dart';
import 'package:hello_flutter/vault/vault_types.dart';

import '../support/fixtures.dart';

Uint8List _withTamperedByte(Uint8List envelope, String base64Field) {
  final map = jsonDecode(utf8.decode(envelope)) as Map<String, dynamic>;
  final payload = map['payload'] as Map<String, dynamic>;
  final bytes = base64Decode(payload[base64Field] as String);
  bytes[0] ^= 0x01;
  payload[base64Field] = base64Encode(bytes);
  return Uint8List.fromList(utf8.encode(jsonEncode(map)));
}

void main() {
  final crypto = VaultCrypto();

  test('password length uses visible characters, no trimming', () {
    expect(validPassword('1234567'), isFalse);
    expect(validPassword('12345678'), isTrue);
    expect(validPassword('👨‍👩‍👧‍👦1234567'), isTrue);
    expect(validPassword('        '), isTrue);
    expect(validPassword(' 123456 '), isTrue);
    expect(validPassword(''), isFalse);
  });

  test('password and recovery unlock the same note', () async {
    final created = await crypto.createVault(
      localPassword,
      fixtureRecovery,
      fixtureData,
    );
    final reopened = await crypto.unlock(created.envelope, localPassword);
    expect(
      reopened.data.notes.single.markdown,
      fixtureData.notes.single.markdown,
    );
    expect(reopened.data.notes.single.title, fixtureData.notes.single.title);
    expect(
      reopened.data.notes.single.createdAt,
      fixtureData.notes.single.createdAt,
    );
    expect(reopened.revision, 1);

    final recovered = await crypto.recover(
      created.envelope,
      fixtureRecovery.answers,
    );
    expect(
      await recovered.dataKey.extractBytes(),
      await reopened.dataKey.extractBytes(),
    );
    expect(
      recovered.data.notes.single.markdown,
      fixtureData.notes.single.markdown,
    );

    await expectLater(
      crypto.unlock(created.envelope, 'wrong-1234'),
      throwsA(isA<VaultException>()),
    );
  });

  test('password is not trimmed and is case sensitive', () async {
    const padded = ' Local-1234 ';
    final created = await crypto.createVault(
      padded,
      fixtureRecovery,
      fixtureData,
    );
    await expectLater(
      crypto.unlock(created.envelope, 'Local-1234'),
      throwsA(isA<VaultException>()),
    );
    final unlocked = await crypto.unlock(created.envelope, padded);
    expect(
      unlocked.data.notes.single.markdown,
      fixtureData.notes.single.markdown,
    );
  });

  test('recovery answers trim only edges and stay case sensitive', () async {
    final recovery = RecoveryConfig(
      questions: fixtureRecovery.questions,
      answers: const ['  Rex  ', 'Blue House', 'SMA 1'],
    );
    final created = await crypto.createVault(
      localPassword,
      recovery,
      fixtureData,
    );
    final recovered = await crypto.recover(created.envelope, const [
      'Rex',
      ' Blue House ',
      'SMA 1',
    ]);
    expect(
      recovered.data.notes.single.markdown,
      fixtureData.notes.single.markdown,
    );
    await expectLater(
      crypto.recover(created.envelope, const ['rex', 'Blue House', 'SMA 1']),
      throwsA(isA<VaultException>()),
    );
  });

  test('ambiguous answer concatenations derive different keys', () async {
    final first = await crypto.createVault(
      localPassword,
      RecoveryConfig(
        questions: fixtureRecovery.questions,
        answers: const ['ab', 'c', 'd'],
      ),
      fixtureData,
    );
    await expectLater(
      crypto.recover(first.envelope, const ['a', 'bc', 'd']),
      throwsA(isA<VaultException>()),
    );
    await expectLater(
      crypto.recover(first.envelope, const ['a', 'b', 'cd']),
      throwsA(isA<VaultException>()),
    );
  });

  test('wrong answers reveal no partial success', () async {
    final created = await crypto.createVault(
      localPassword,
      fixtureRecovery,
      fixtureData,
    );
    final wrong = [
      [fixtureRecovery.answers[0], fixtureRecovery.answers[1], 'nope'],
      ['nope', fixtureRecovery.answers[1], fixtureRecovery.answers[2]],
      ['nope', 'nope', 'nope'],
      fixtureRecovery.answers.sublist(0, 2),
    ];
    for (final answers in wrong) {
      await expectLater(
        crypto.recover(created.envelope, answers),
        throwsA(isA<VaultException>()),
      );
    }
  });

  test('export profile cannot be parsed as local', () async {
    final created = await crypto.createVault(
      localPassword,
      fixtureRecovery,
      fixtureData,
    );
    final local =
        jsonDecode(utf8.decode(created.envelope)) as Map<String, dynamic>;
    final exported = Map<String, dynamic>.from(local)..['type'] = 'export';
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(exported)));
    await expectLater(
      crypto.unlock(bytes, localPassword),
      throwsA(
        isA<VaultException>().having(
          (e) => e.code,
          'code',
          FailureCode.unsupported,
        ),
      ),
    );
    expect(
      () => crypto.readRecoveryQuestions(bytes),
      throwsA(isA<VaultException>()),
    );
  });

  test('tampered header or tag is rejected', () async {
    final created = await crypto.createVault(
      localPassword,
      fixtureRecovery,
      fixtureData,
    );
    await expectLater(
      crypto.unlock(
        _withTamperedByte(created.envelope, 'ciphertext'),
        localPassword,
      ),
      throwsA(isA<VaultException>()),
    );
    await expectLater(
      crypto.unlock(_withTamperedByte(created.envelope, 'tag'), localPassword),
      throwsA(isA<VaultException>()),
    );

    final header =
        jsonDecode(utf8.decode(created.envelope)) as Map<String, dynamic>;
    header['vaultId'] = 'ffeeddccbbaa99887766554433221100';
    final tamperedHeader = Uint8List.fromList(utf8.encode(jsonEncode(header)));
    await expectLater(
      crypto.unlock(tamperedHeader, localPassword),
      throwsA(isA<VaultException>()),
    );
    await expectLater(
      crypto.recover(tamperedHeader, fixtureRecovery.answers),
      throwsA(isA<VaultException>()),
    );
  });

  test('ciphertext contains no fixture plaintext markers', () async {
    final created = await crypto.createVault(
      localPassword,
      fixtureRecovery,
      fixtureData,
    );
    final asLatin = latin1.decode(created.envelope, allowInvalid: true);
    for (final marker in [
      'Fixture Note Title',
      'Fixture Markdown Body',
      'ciphertext-marker-42',
      'Rex',
      'Blue House',
      localPassword,
    ]) {
      expect(asLatin.contains(marker), isFalse, reason: 'leaked: $marker');
    }
    // Recovery questions are intentionally public header text.
    final questions = crypto.readRecoveryQuestions(created.envelope);
    expect(questions, fixtureRecovery.questions);
  });

  test('seal uses a fresh nonce each time', () async {
    final created = await crypto.createVault(
      localPassword,
      fixtureRecovery,
      fixtureData,
    );
    final unlocked = await crypto.unlock(created.envelope, localPassword);
    final first = await crypto.seal(unlocked, fixtureData, 2);
    final second = await crypto.seal(unlocked, fixtureData, 2);
    expect(first, isNot(equals(second)));
    final firstNonce =
        (jsonDecode(utf8.decode(first))
                as Map<String, dynamic>)['payload']['nonce']
            as String;
    final secondNonce =
        (jsonDecode(utf8.decode(second))
                as Map<String, dynamic>)['payload']['nonce']
            as String;
    expect(firstNonce, isNot(secondNonce));

    final sealed = await crypto.unlock(first, localPassword);
    expect(sealed.revision, 2);
  });

  test('rewrapPassword keeps notes and retires the old password', () async {
    final created = await crypto.createVault(
      localPassword,
      fixtureRecovery,
      fixtureData,
    );
    final unlocked = await crypto.unlock(created.envelope, localPassword);
    final rewrapped = await crypto.rewrapPassword(unlocked, 'new-pass-1234', 2);
    final reopened = await crypto.unlock(rewrapped, 'new-pass-1234');
    expect(
      reopened.data.notes.single.markdown,
      fixtureData.notes.single.markdown,
    );
    await expectLater(
      crypto.unlock(rewrapped, localPassword),
      throwsA(isA<VaultException>()),
    );
    final recovered = await crypto.recover(rewrapped, fixtureRecovery.answers);
    expect(
      recovered.data.notes.single.markdown,
      fixtureData.notes.single.markdown,
    );
  });

  test('unsupported KDF profile is rejected before derivation', () async {
    final created = await crypto.createVault(
      localPassword,
      fixtureRecovery,
      fixtureData,
    );
    final header =
        jsonDecode(utf8.decode(created.envelope)) as Map<String, dynamic>;
    (header['kdf'] as Map<String, dynamic>)['memory'] = 1048576;
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(header)));
    final stopwatch = Stopwatch()..start();
    await expectLater(
      crypto.unlock(bytes, localPassword),
      throwsA(
        isA<VaultException>().having(
          (e) => e.code,
          'code',
          FailureCode.unsupported,
        ),
      ),
    );
    stopwatch.stop();
    expect(stopwatch.elapsedMilliseconds, lessThan(1000));
    expect(
      () => crypto.readRecoveryQuestions(bytes),
      throwsA(isA<VaultException>()),
    );
  });

  test('oversized envelope is rejected before parsing', () async {
    final created = await crypto.createVault(
      localPassword,
      fixtureRecovery,
      fixtureData,
    );
    final oversized = Uint8List(created.envelope.length + 17 * 1024 * 1024);
    oversized.setRange(0, created.envelope.length, created.envelope);
    await expectLater(
      crypto.unlock(oversized, localPassword),
      throwsA(
        isA<VaultException>().having((e) => e.code, 'code', FailureCode.limit),
      ),
    );
  });

  test('malformed header shapes fail as VaultException', () async {
    final created = await crypto.createVault(
      localPassword,
      fixtureRecovery,
      fixtureData,
    );
    final header =
        jsonDecode(utf8.decode(created.envelope)) as Map<String, dynamic>;
    header['recovery'] = 'not-a-map';
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(header)));
    await expectLater(
      crypto.unlock(bytes, localPassword),
      throwsA(isA<VaultException>()),
    );
    expect(
      () => crypto.readRecoveryQuestions(bytes),
      throwsA(isA<VaultException>()),
    );
  });

  test('writer never exceeds reader limits', () async {
    final created = await crypto.createVault(
      localPassword,
      fixtureRecovery,
      fixtureData,
    );
    final unlocked = await crypto.unlock(created.envelope, localPassword);
    final oversizedNote = Note(
      id: 'ffffffffffffffffffffffffffffffff',
      title: 'big',
      markdown: 'x' * (8 * 1024 * 1024 + 1),
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
    );
    await expectLater(
      crypto.seal(unlocked, VaultData(notes: [oversizedNote]), 2),
      throwsA(
        isA<VaultException>().having((e) => e.code, 'code', FailureCode.limit),
      ),
    );

    final nearLimit = Note(
      id: 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
      title: 'near',
      markdown: 'y' * (1024 * 1024),
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
    );
    final sealed = await crypto.seal(
      unlocked,
      VaultData(notes: [nearLimit]),
      3,
    );
    expect(sealed.length, lessThan(16 * 1024 * 1024));
    final reopened = await crypto.unlock(sealed, localPassword);
    expect(reopened.data.notes.single.markdown.length, 1024 * 1024);
  });

  test('vault types enforce the documented format', () {
    expect(
      () => Note(
        id: 'not-hex',
        title: 't',
        markdown: '',
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      ).toJson(),
      throwsA(isA<VaultException>()),
    );
    expect(
      () => RecoveryConfig(
        questions: const ['a', 'b'],
        answers: const ['x', 'y'],
      ),
      throwsA(isA<VaultException>()),
    );
    expect(
      () => RecoveryConfig(
        questions: const ['a', 'b', 'c'],
        answers: const ['x', '  ', 'z'],
      ),
      throwsA(isA<VaultException>()),
    );
    final note = Note(
      id: '0123456789abcdef0123456789abcdef',
      title: 't',
      markdown: 'm',
      createdAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
      updatedAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
    );
    expect(note.toJson()['createdAt'], '2026-01-02T03:04:05.000Z');
    expect(Note.fromJson(note.toJson()).markdown, 'm');
  });
}
