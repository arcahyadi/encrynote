import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'vault_types.dart';

const int maxPayloadBytes = 8 * 1024 * 1024;
const int maxEnvelopeBytes = 16 * 1024 * 1024;

const String _suite = 'argon2id-aes256gcm';
const int _version = 1;
const int _kdfMemory = 19456;
const int _kdfIterations = 2;
const int _kdfParallelism = 1;
const int _kdfHashLength = 32;
const int _saltLength = 16;
const int _nonceLength = 12;
const int _tagLength = 16;
const int _dataKeyLength = 32;

const String _domainPayload = 'encrynote/local-payload';
const String _domainPasswordWrap = 'encrynote/password-wrap';
const String _domainRecoveryWrap = 'encrynote/recovery-wrap';

class VaultCrypto {
  VaultCrypto({Random? random}) : _random = random ?? Random.secure();

  final Random _random;
  final AesGcm _cipher = AesGcm.with256bits();

  Future<UnlockedVault> createVault(
    String password,
    RecoveryConfig recovery,
    VaultData data,
  ) async {
    if (!validPassword(password)) {
      throw const VaultException(FailureCode.credentials, 'password.length');
    }
    final vaultId = _randomBytes(16);
    final dataKey = SecretKeyData(_randomBytes(_dataKeyLength));
    final passwordSalt = _randomBytes(_saltLength);
    final recoverySalt = _randomBytes(_saltLength);

    final passwordKey = await _deriveKey(password, passwordSalt);
    final recoveryKey = await _deriveKey(
      jsonEncode(recovery.answers),
      recoverySalt,
    );

    final header = _Header(
      vaultId: vaultId,
      passwordSalt: passwordSalt,
      recoverySalt: recoverySalt,
      questions: recovery.questions,
    );
    final passwordWrap = await _wrap(
      dataKey,
      passwordKey,
      header.passwordWrapAad(),
    );
    final recoveryWrap = await _wrap(
      dataKey,
      recoveryKey,
      header.recoveryWrapAad(),
    );
    final payload = await _sealPayload(dataKey, header, data, 1);
    final envelope = _encode(header, passwordWrap, recoveryWrap, payload);

    return UnlockedVault(
      envelope: envelope,
      dataKey: dataKey,
      data: data,
      revision: 1,
    );
  }

  Future<UnlockedVault> unlock(Uint8List envelope, String password) async {
    final parsed = _parse(envelope);
    if (!validPassword(password)) {
      throw const VaultException(FailureCode.credentials, 'password.length');
    }
    final passwordKey = await _deriveKey(password, parsed.header.passwordSalt);
    final dataKey = await _unwrap(
      parsed.passwordWrap,
      passwordKey,
      parsed.header.passwordWrapAad(),
    );
    return _open(parsed, dataKey);
  }

  Future<UnlockedVault> recover(
    Uint8List envelope,
    List<String> answers,
  ) async {
    final parsed = _parse(envelope);
    if (answers.length != 3) {
      throw const VaultException(FailureCode.credentials, 'answers.count');
    }
    final normalized = answers.map((answer) => answer.trim()).toList();
    if (normalized.any((answer) => answer.isEmpty)) {
      throw const VaultException(FailureCode.credentials, 'answers.empty');
    }
    final recoveryKey = await _deriveKey(
      jsonEncode(normalized),
      parsed.header.recoverySalt,
    );
    final dataKey = await _unwrap(
      parsed.recoveryWrap,
      recoveryKey,
      parsed.header.recoveryWrapAad(),
    );
    return _open(parsed, dataKey);
  }

  /// Reads the public recovery prompts without running any KDF.
  List<String> readRecoveryQuestions(Uint8List envelope) =>
      _parse(envelope).header.questions;

  Future<Uint8List> seal(
    UnlockedVault vault,
    VaultData data,
    int revision,
  ) async {
    final parsed = _parse(vault.envelope);
    final payload = await _sealPayload(
      vault.dataKey,
      parsed.header,
      data,
      revision,
    );
    return _encode(
      parsed.header,
      parsed.passwordWrap,
      parsed.recoveryWrap,
      payload,
    );
  }

  Future<Uint8List> rewrapPassword(
    UnlockedVault vault,
    String newPassword,
    int revision,
  ) async {
    if (!validPassword(newPassword)) {
      throw const VaultException(FailureCode.credentials, 'password.length');
    }
    final parsed = _parse(vault.envelope);
    final salt = _randomBytes(_saltLength);
    final key = await _deriveKey(newPassword, salt);
    final header = parsed.header.withPasswordSalt(salt);
    final passwordWrap = await _wrap(
      vault.dataKey,
      key,
      header.passwordWrapAad(),
    );
    final payload = await _sealPayload(
      vault.dataKey,
      header,
      vault.data,
      revision,
    );
    return _encode(header, passwordWrap, parsed.recoveryWrap, payload);
  }

  Future<UnlockedVault> _open(_ParsedEnvelope parsed, SecretKey dataKey) async {
    final plain = await _decrypt(
      parsed.payload,
      dataKey,
      parsed.header.payloadAad(),
      FailureCode.format,
    );
    if (plain.length > maxPayloadBytes) {
      throw const VaultException(FailureCode.limit, 'payload');
    }
    final Map<String, dynamic> json;
    try {
      json = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
    } on Object {
      throw const VaultException(FailureCode.format, 'payload');
    }
    final revision = json['revision'];
    if (revision is! int || revision < 1) {
      throw const VaultException(FailureCode.format, 'payload.revision');
    }
    final VaultData data;
    try {
      data = VaultData.fromJson(json);
    } on VaultException {
      rethrow;
    } on Object {
      throw const VaultException(FailureCode.format, 'payload.data');
    }
    return UnlockedVault(
      envelope: parsed.bytes,
      dataKey: dataKey,
      data: data,
      revision: revision,
    );
  }

  Future<_Sealed> _sealPayload(
    SecretKey dataKey,
    _Header header,
    VaultData data,
    int revision,
  ) async {
    if (revision < 1) {
      throw const VaultException(FailureCode.format, 'revision');
    }
    final plain = Uint8List.fromList(
      utf8.encode(
        jsonEncode(<String, dynamic>{'revision': revision, ...data.toJson()}),
      ),
    );
    if (plain.length > maxPayloadBytes) {
      throw const VaultException(FailureCode.limit, 'payload');
    }
    final box = await _cipher.encrypt(
      plain,
      secretKey: dataKey,
      nonce: _randomBytes(_nonceLength),
      aad: header.payloadAad(),
    );
    return _Sealed.fromBox(box);
  }

  Future<_Sealed> _wrap(
    SecretKey dataKey,
    SecretKey wrappingKey,
    List<int> aad,
  ) async {
    final raw = await dataKey.extractBytes();
    final box = await _cipher.encrypt(
      raw,
      secretKey: wrappingKey,
      nonce: _randomBytes(_nonceLength),
      aad: aad,
    );
    return _Sealed.fromBox(box);
  }

  Future<SecretKey> _unwrap(
    _Sealed sealed,
    SecretKey wrappingKey,
    List<int> aad,
  ) async {
    final raw = await _decrypt(
      sealed,
      wrappingKey,
      aad,
      FailureCode.credentials,
    );
    if (raw.length != _dataKeyLength) {
      throw const VaultException(FailureCode.format, 'wrappedKey.length');
    }
    return SecretKeyData(raw);
  }

  Future<Uint8List> _decrypt(
    _Sealed sealed,
    SecretKey key,
    List<int> aad,
    FailureCode failure,
  ) async {
    try {
      final plain = await _cipher.decrypt(
        SecretBox(sealed.ciphertext, nonce: sealed.nonce, mac: Mac(sealed.tag)),
        secretKey: key,
        aad: aad,
      );
      return Uint8List.fromList(plain);
    } on SecretBoxAuthenticationError {
      throw VaultException(failure, 'authentication');
    } on Object {
      throw VaultException(failure, 'decrypt');
    }
  }

  Future<SecretKey> _deriveKey(String value, Uint8List salt) async {
    final bytes = await Isolate.run(() async {
      final algorithm = Argon2id(
        parallelism: _kdfParallelism,
        memory: _kdfMemory,
        iterations: _kdfIterations,
        hashLength: _kdfHashLength,
      );
      final key = await algorithm.deriveKey(
        secretKey: SecretKey(utf8.encode(value)),
        nonce: salt,
      );
      return Uint8List.fromList(await key.extractBytes());
    });
    return SecretKeyData(bytes);
  }

  Uint8List _randomBytes(int length) {
    final bytes = Uint8List(length);
    for (var i = 0; i < length; i++) {
      bytes[i] = _random.nextInt(256);
    }
    return bytes;
  }

  Uint8List _encode(
    _Header header,
    _Sealed passwordWrap,
    _Sealed recoveryWrap,
    _Sealed payload,
  ) {
    final map = <String, dynamic>{
      'type': 'local',
      'version': _version,
      'suite': _suite,
      'vaultId': _hex(header.vaultId),
      'kdf': _kdfJson(header.passwordSalt),
      'passwordWrap': passwordWrap.toJson(),
      'recovery': <String, dynamic>{
        'questions': header.questions,
        'kdf': _kdfJson(header.recoverySalt),
        'wrap': recoveryWrap.toJson(),
      },
      'payload': payload.toJson(),
    };
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(map)));
    if (bytes.length > maxEnvelopeBytes) {
      throw const VaultException(FailureCode.limit, 'envelope');
    }
    return bytes;
  }

  Map<String, dynamic> _kdfJson(Uint8List salt) => <String, dynamic>{
    'algorithm': 'argon2id',
    'memory': _kdfMemory,
    'iterations': _kdfIterations,
    'parallelism': _kdfParallelism,
    'hashLength': _kdfHashLength,
    'salt': base64Encode(salt),
  };

  _ParsedEnvelope _parse(Uint8List envelope) {
    if (envelope.length > maxEnvelopeBytes) {
      throw const VaultException(FailureCode.limit, 'envelope');
    }
    final Map<String, dynamic> json;
    try {
      json = jsonDecode(utf8.decode(envelope)) as Map<String, dynamic>;
    } on Object {
      throw const VaultException(FailureCode.format, 'envelope');
    }
    if (json['type'] != 'local') {
      throw const VaultException(FailureCode.unsupported, 'type');
    }
    if (json['version'] != _version || json['suite'] != _suite) {
      throw const VaultException(FailureCode.unsupported, 'suite');
    }
    final vaultId = _fromHex(json['vaultId']);
    final passwordSalt = _kdfSalt(json['kdf']);
    final recovery = json['recovery'];
    if (recovery is! Map<String, dynamic>) {
      throw const VaultException(FailureCode.format, 'recovery');
    }
    final recoverySalt = _kdfSalt(recovery['kdf']);
    final questions = recovery['questions'];
    if (questions is! List ||
        questions.length != 3 ||
        questions.any((question) => question is! String)) {
      throw const VaultException(FailureCode.format, 'questions');
    }
    return _ParsedEnvelope(
      bytes: envelope,
      header: _Header(
        vaultId: vaultId,
        passwordSalt: passwordSalt,
        recoverySalt: recoverySalt,
        questions: List<String>.unmodifiable(questions.cast<String>()),
      ),
      passwordWrap: _Sealed.parse(json['passwordWrap']),
      recoveryWrap: _Sealed.parse(recovery['wrap']),
      payload: _Sealed.parse(json['payload']),
    );
  }

  Uint8List _kdfSalt(Object? json) {
    if (json is! Map<String, dynamic>) {
      throw const VaultException(FailureCode.format, 'kdf');
    }
    // Only the v1 profile is accepted, checked before any derivation.
    if (json['algorithm'] != 'argon2id' ||
        json['memory'] != _kdfMemory ||
        json['iterations'] != _kdfIterations ||
        json['parallelism'] != _kdfParallelism ||
        json['hashLength'] != _kdfHashLength) {
      throw const VaultException(FailureCode.unsupported, 'kdf.profile');
    }
    return _base64(json['salt'], _saltLength, 'kdf.salt');
  }

  Uint8List _fromHex(Object? value) {
    if (value is! String || !RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) {
      throw const VaultException(FailureCode.format, 'vaultId');
    }
    return Uint8List.fromList([
      for (var i = 0; i < 32; i += 2)
        int.parse(value.substring(i, i + 2), radix: 16),
    ]);
  }

  String _hex(Uint8List bytes) =>
      bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

  Uint8List _base64(Object? value, int length, String field) {
    if (value is! String) {
      throw VaultException(FailureCode.format, field);
    }
    final Uint8List bytes;
    try {
      bytes = base64Decode(value);
    } on FormatException {
      throw VaultException(FailureCode.format, field);
    }
    if (bytes.length != length) {
      throw VaultException(FailureCode.format, field);
    }
    return bytes;
  }
}

class _Header {
  const _Header({
    required this.vaultId,
    required this.passwordSalt,
    required this.recoverySalt,
    required this.questions,
  });

  final Uint8List vaultId;
  final Uint8List passwordSalt;
  final Uint8List recoverySalt;
  final List<String> questions;

  _Header withPasswordSalt(Uint8List salt) => _Header(
    vaultId: vaultId,
    passwordSalt: salt,
    recoverySalt: recoverySalt,
    questions: questions,
  );

  List<int> payloadAad() => _aad([_domainPayload, _version, _suite, _hexId]);

  List<int> passwordWrapAad() =>
      _aad([_domainPasswordWrap, _version, _suite, _hexId]);

  List<int> recoveryWrapAad() =>
      _aad([_domainRecoveryWrap, _version, _suite, _hexId, questions]);

  String get _hexId =>
      vaultId.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

  static List<int> _aad(List<Object> parts) => utf8.encode(jsonEncode(parts));
}

class _Sealed {
  _Sealed._({required this.nonce, required this.ciphertext, required this.tag});

  factory _Sealed.fromBox(SecretBox box) => _Sealed._(
    nonce: Uint8List.fromList(box.nonce),
    ciphertext: Uint8List.fromList(box.cipherText),
    tag: Uint8List.fromList(box.mac.bytes),
  );

  factory _Sealed.parse(Object? json) {
    if (json is! Map<String, dynamic>) {
      throw const VaultException(FailureCode.format, 'sealed');
    }
    final nonce = _decode(json['nonce'], _nonceLength, 'nonce');
    final tag = _decode(json['tag'], _tagLength, 'tag');
    final ciphertext = _decode(json['ciphertext'], null, 'ciphertext');
    return _Sealed._(nonce: nonce, ciphertext: ciphertext, tag: tag);
  }

  final Uint8List nonce;
  final Uint8List ciphertext;
  final Uint8List tag;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'nonce': base64Encode(nonce),
    'ciphertext': base64Encode(ciphertext),
    'tag': base64Encode(tag),
  };

  static Uint8List _decode(Object? value, int? length, String field) {
    if (value is! String) {
      throw VaultException(FailureCode.format, field);
    }
    final Uint8List bytes;
    try {
      bytes = base64Decode(value);
    } on FormatException {
      throw VaultException(FailureCode.format, field);
    }
    if (length != null && bytes.length != length) {
      throw VaultException(FailureCode.format, field);
    }
    if (bytes.isEmpty || bytes.length > maxEnvelopeBytes) {
      throw VaultException(FailureCode.limit, field);
    }
    return bytes;
  }
}

class _ParsedEnvelope {
  const _ParsedEnvelope({
    required this.bytes,
    required this.header,
    required this.passwordWrap,
    required this.recoveryWrap,
    required this.payload,
  });

  final Uint8List bytes;
  final _Header header;
  final _Sealed passwordWrap;
  final _Sealed recoveryWrap;
  final _Sealed payload;
}
