import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'vault_types.dart';

const int maxPayloadBytes = 8 * 1024 * 1024;
const int maxEnvelopeBytes = 16 * 1024 * 1024;
const int maxMarkdownBytes = 1024 * 1024;

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

/// Largest revision the writer will mint. The payload pre-check reserves the
/// serialized width this field can still grow by, so an accepted vault stays
/// writable when the revision crosses a decimal digit (9 -> 10).
const int _maxRevisionDigits = 10;

/// Longest possible `autoLock` storage value. A preference change is metadata
/// only, but it still grows the payload, so the pre-check reserves the same
/// headroom for it.
final int _maxAutoLockBytes = AutoLockMode.values
    .map((mode) => mode.storageValue.length)
    .reduce((a, b) => a > b ? a : b);

const String _domainPayload = 'encrynote/local-payload';
const String _domainPasswordWrap = 'encrynote/password-wrap';
const String _domainRecoveryWrap = 'encrynote/recovery-wrap';
const String _domainExport = 'encrynote/export-payload';

class VaultCrypto {
  /// [random] is only for deterministic tests; production uses [Random.secure].
  VaultCrypto({Random? random}) : _random = random ?? Random.secure();

  final Random _random;

  Future<UnlockedVault> createVault(
    String password,
    RecoveryConfig recovery,
    VaultData data,
  ) async {
    if (!validPassword(password)) {
      throw const VaultException(FailureCode.credentials, 'password.length');
    }
    final vaultId = _randomBytes(16);
    final dataKeyBytes = _randomBytes(_dataKeyLength);
    final passwordSalt = _randomBytes(_saltLength);
    final recoverySalt = _randomBytes(_saltLength);
    final header = _Header(
      vaultId: vaultId,
      passwordSalt: passwordSalt,
      recoverySalt: recoverySalt,
      questions: recovery.questions,
    );

    final nonce = _randomBytes(_nonceLength);
    final envelope = await Isolate.run(
      () => _createWorker(
        password,
        recovery.answers,
        data,
        header,
        dataKeyBytes,
        nonce,
      ),
    );

    return UnlockedVault(
      envelope: envelope,
      dataKey: SecretKeyData(dataKeyBytes),
      data: data,
      revision: 1,
    );
  }

  Future<UnlockedVault> unlock(Uint8List envelope, String password) async {
    if (!validPassword(password)) {
      throw const VaultException(FailureCode.credentials, 'password.length');
    }
    _checkEnvelopeSize(envelope);
    final opened = await Isolate.run(() => _unlockWorker(envelope, password));
    return _toVault(envelope, opened);
  }

  Future<UnlockedVault> recover(
    Uint8List envelope,
    List<String> answers,
  ) async {
    if (answers.length != 3) {
      throw const VaultException(FailureCode.credentials, 'answers.count');
    }
    final normalized = answers.map((answer) => answer.trim()).toList();
    if (normalized.any((answer) => answer.isEmpty)) {
      throw const VaultException(FailureCode.credentials, 'answers.empty');
    }
    _checkEnvelopeSize(envelope);
    final opened = await Isolate.run(
      () => _recoverWorker(envelope, normalized),
    );
    return _toVault(envelope, opened);
  }

  /// Reads the public recovery prompts without running any KDF.
  List<String> readRecoveryQuestions(Uint8List envelope) =>
      _parseEnvelope(envelope).header.questions;

  /// Seals [notes] into a standalone export envelope under [exportPassword].
  ///
  /// The export has its own fresh salt and nonce and carries no vault id,
  /// password wrapper, recovery wrapper, questions, or local key material, so
  /// the app password and recovery answers cannot open it.
  Future<Uint8List> exportNotes(List<Note> notes, String exportPassword) async {
    if (!validPassword(exportPassword)) {
      throw const VaultException(FailureCode.credentials, 'password.length');
    }
    final salt = _randomBytes(_saltLength);
    final nonce = _randomBytes(_nonceLength);
    return Isolate.run(() => _exportWorker(notes, exportPassword, salt, nonce));
  }

  /// Opens an export envelope with [exportPassword] only.
  Future<List<Note>> importExport(
    Uint8List bytes,
    String exportPassword,
  ) async {
    if (!validPassword(exportPassword)) {
      throw const VaultException(FailureCode.credentials, 'password.length');
    }
    if (bytes.length > maxEnvelopeBytes) {
      throw const VaultException(FailureCode.limit, 'envelope');
    }
    return Isolate.run(() => _importWorker(bytes, exportPassword));
  }

  Future<Uint8List> seal(
    UnlockedVault vault,
    VaultData data,
    int revision,
  ) async {
    if (revision < 1) {
      throw const VaultException(FailureCode.format, 'revision');
    }
    _checkEnvelopeSize(vault.envelope);
    final keyBytes = Uint8List.fromList(await vault.dataKey.extractBytes());
    final nonce = _randomBytes(_nonceLength);
    return Isolate.run(
      () => _sealWorker(keyBytes, vault.envelope, data, revision, nonce),
    );
  }

  /// Rejects [data] at [revision] when the sealed payload or the resulting
  /// envelope would exceed the v1 limits. Runs no crypto and writes nothing, so
  /// a caller can reject a draft before accepting it into session state.
  ///
  /// The envelope length is measured against [vault]'s own header and wrappers,
  /// which are the ones [seal] re-emits unchanged.
  ///
  /// The check also reserves the bounded growth of the two mutable metadata
  /// fields (`revision` digits and the `autoLock` value), so a vault accepted
  /// at this boundary can still take a later metadata-only change or a password
  /// rewrap when the revision crosses a decimal digit. The wire caps themselves
  /// do not change: this only keeps the writer away from the edge.
  void checkSnapshotFits(UnlockedVault vault, VaultData data, int revision) {
    final plain = v1PayloadBytes(data, revision);
    final reserved = plain.length + _metadataGrowth(data, revision);
    if (reserved > maxPayloadBytes) {
      throw const VaultException(FailureCode.limit, 'payload');
    }
    if (_envelopeLengthFor(vault.envelope, reserved) > maxEnvelopeBytes) {
      throw const VaultException(FailureCode.limit, 'envelope');
    }
  }

  /// Exact byte length of the envelope [seal] would emit for a payload of
  /// [plainLength] bytes, using the retained envelope's own JSON framing.
  ///
  /// AES-GCM ciphertext is the plaintext length and base64 is 4 chars per
  /// 3 bytes, so only the base64 field lengths differ from the current file.
  int _envelopeLengthFor(Uint8List envelope, int plainLength) {
    final Map<String, dynamic> map;
    try {
      map = jsonDecode(utf8.decode(envelope)) as Map<String, dynamic>;
    } on Object {
      throw const VaultException(FailureCode.format, 'envelope');
    }
    final current = map['payload'];
    if (current is! Map<String, dynamic>) {
      throw const VaultException(FailureCode.format, 'payload');
    }
    final cipherBase64 = 4 * ((plainLength + 2) ~/ 3);
    final next = <String, dynamic>{
      'nonce': 'A' * (4 * ((_nonceLength + 2) ~/ 3)),
      'ciphertext': 'A' * cipherBase64,
      'tag': 'A' * (4 * ((_tagLength + 2) ~/ 3)),
    };
    final before = utf8.encode(jsonEncode(current)).length;
    final after = utf8.encode(jsonEncode(next)).length;
    return utf8.encode(jsonEncode(map)).length - before + after;
  }

  Future<Uint8List> rewrapPassword(
    UnlockedVault vault,
    String newPassword,
    int revision,
  ) async {
    if (!validPassword(newPassword)) {
      throw const VaultException(FailureCode.credentials, 'password.length');
    }
    if (revision < 1) {
      throw const VaultException(FailureCode.format, 'revision');
    }
    _checkEnvelopeSize(vault.envelope);
    final keyBytes = Uint8List.fromList(await vault.dataKey.extractBytes());
    final salt = _randomBytes(_saltLength);
    final nonce = _randomBytes(_nonceLength);
    return Isolate.run(
      () => _rewrapWorker(
        keyBytes,
        vault.envelope,
        vault.data,
        newPassword,
        revision,
        salt,
        nonce,
      ),
    );
  }

  UnlockedVault _toVault(Uint8List envelope, _Opened opened) {
    final revision = opened.json['revision'];
    if (revision is! int || revision < 1) {
      throw const VaultException(FailureCode.format, 'payload.revision');
    }
    final VaultData data;
    try {
      data = VaultData.fromJson(opened.json);
    } on VaultException {
      rethrow;
    } on Object {
      throw const VaultException(FailureCode.format, 'payload.data');
    }
    return UnlockedVault(
      envelope: envelope,
      dataKey: SecretKeyData(opened.dataKey),
      data: data,
      revision: revision,
    );
  }

  void _checkEnvelopeSize(Uint8List envelope) {
    if (envelope.length > maxEnvelopeBytes) {
      throw const VaultException(FailureCode.limit, 'envelope');
    }
  }

  Uint8List _randomBytes(int length) {
    final bytes = Uint8List(length);
    for (var i = 0; i < length; i++) {
      bytes[i] = _random.nextInt(256);
    }
    return bytes;
  }
}

/// Serialized v1 payload plaintext for [data] at [revision].
///
/// Single source of truth for the bytes [seal] encrypts and for the pre-accept
/// limit checks, so a check can never describe a different snapshot than the
/// writer produces.
Uint8List v1PayloadBytes(VaultData data, int revision) {
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
  return plain;
}

/// Bytes the mutable metadata can still gain at its documented maxima.
///
/// Used by [VaultCrypto.checkSnapshotFits] to reserve headroom: JSON length
/// grows by exactly one byte per extra `revision` digit and per extra
/// `autoLock` character, and both are bounded ([_maxRevisionDigits],
/// [_maxAutoLockBytes]).
int _metadataGrowth(VaultData data, int revision) =>
    max(0, _maxRevisionDigits - revision.toString().length) +
    max(0, _maxAutoLockBytes - data.autoLock.storageValue.length);

typedef _Opened = ({Uint8List dataKey, Map<String, dynamic> json});

// Every public operation runs as a single helper-isolate call, so neither the
// KDF nor payload-sized JSON/AES-GCM work can stall the UI isolate. Only
// sendable values cross the boundary; ciphers and RNG stay inside the isolate.

Future<Uint8List> _createWorker(
  String password,
  List<String> answers,
  VaultData data,
  _Header header,
  Uint8List dataKeyBytes,
  Uint8List nonce,
) async {
  final passwordKey = await _deriveKey(password, header.passwordSalt);
  final recoveryKey = await _deriveKey(
    jsonEncode(answers),
    header.recoverySalt,
  );
  final passwordWrap = await _wrap(
    dataKeyBytes,
    passwordKey,
    header.passwordWrapAad(),
    _isolateRandomBytes(_nonceLength),
  );
  final recoveryWrap = await _wrap(
    dataKeyBytes,
    recoveryKey,
    header.recoveryWrapAad(),
    _isolateRandomBytes(_nonceLength),
  );
  final payload = await _sealPayload(
    dataKeyBytes,
    header,
    passwordWrap,
    recoveryWrap,
    data,
    1,
    nonce,
  );
  return _encodeEnvelope(header, passwordWrap, recoveryWrap, payload);
}

Future<_Opened> _unlockWorker(Uint8List envelope, String password) async {
  final parsed = _parseEnvelope(envelope);
  final key = await _deriveKey(password, parsed.header.passwordSalt);
  final dataKeyBytes = await _unwrap(
    parsed.passwordWrap,
    key,
    parsed.header.passwordWrapAad(),
  );
  final json = await _decryptPayloadJson(
    dataKeyBytes,
    parsed.payload,
    parsed.header.payloadAad(parsed.passwordWrap, parsed.recoveryWrap),
    FailureCode.format,
  );
  return (dataKey: dataKeyBytes, json: json);
}

Future<_Opened> _recoverWorker(Uint8List envelope, List<String> answers) async {
  final parsed = _parseEnvelope(envelope);
  final key = await _deriveKey(jsonEncode(answers), parsed.header.recoverySalt);
  final dataKeyBytes = await _unwrap(
    parsed.recoveryWrap,
    key,
    parsed.header.recoveryWrapAad(),
  );
  final json = await _decryptPayloadJson(
    dataKeyBytes,
    parsed.payload,
    parsed.header.payloadAad(parsed.passwordWrap, parsed.recoveryWrap),
    FailureCode.format,
  );
  return (dataKey: dataKeyBytes, json: json);
}

Future<Uint8List> _exportWorker(
  List<Note> notes,
  String exportPassword,
  Uint8List salt,
  Uint8List nonce,
) async {
  final plain = _exportPayloadBytes(notes);
  final key = await _deriveKey(exportPassword, salt);
  final header = _ExportHeader(salt: salt);
  final box = await AesGcm.with256bits().encrypt(
    plain,
    secretKey: key,
    nonce: nonce,
    aad: header.payloadAad(),
  );
  final payload = _Sealed.fromBox(box);
  final bytes = Uint8List.fromList(
    utf8.encode(
      jsonEncode(<String, dynamic>{
        'type': 'export',
        'version': _version,
        'suite': _suite,
        'kdf': _kdfJson(salt),
        'payload': payload.toJson(),
      }),
    ),
  );
  if (bytes.length > maxEnvelopeBytes) {
    throw const VaultException(FailureCode.limit, 'envelope');
  }
  return bytes;
}

Future<List<Note>> _importWorker(Uint8List bytes, String exportPassword) async {
  final parsed = _parseExport(bytes);
  final key = await _deriveKey(exportPassword, parsed.header.salt);
  final plain = await _decrypt(
    parsed.payload,
    key,
    parsed.header.payloadAad(),
    FailureCode.credentials,
  );
  if (plain.length > maxPayloadBytes) {
    throw const VaultException(FailureCode.limit, 'payload');
  }
  final List<dynamic> jsonNotes;
  try {
    final json = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
    jsonNotes = json['notes'] as List<dynamic>;
  } on Object {
    throw const VaultException(FailureCode.format, 'payload');
  }
  try {
    return [
      for (final note in jsonNotes) Note.fromJson(note as Map<String, dynamic>),
    ];
  } on VaultException {
    rethrow;
  } on Object {
    throw const VaultException(FailureCode.format, 'payload.note');
  }
}

/// Serialized export plaintext: notes only, no revision or auto-lock.
Uint8List _exportPayloadBytes(List<Note> notes) {
  final plain = Uint8List.fromList(
    utf8.encode(
      jsonEncode(<String, dynamic>{
        'notes': notes.map((note) => note.toJson()).toList(),
      }),
    ),
  );
  if (plain.length > maxPayloadBytes) {
    throw const VaultException(FailureCode.limit, 'payload');
  }
  return plain;
}

/// Parses and validates an export header; decodes no payload and runs no KDF.
_ParsedExport _parseExport(Uint8List bytes) {
  if (bytes.isEmpty) {
    throw const VaultException(FailureCode.format, 'export.empty');
  }
  if (bytes.length > maxEnvelopeBytes) {
    throw const VaultException(FailureCode.limit, 'envelope');
  }
  final Map<String, dynamic> json;
  try {
    json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  } on Object {
    throw const VaultException(FailureCode.format, 'export.json');
  }
  if (json['type'] != 'export') {
    throw const VaultException(FailureCode.unsupported, 'type');
  }
  if (json['version'] != _version || json['suite'] != _suite) {
    throw const VaultException(FailureCode.unsupported, 'suite');
  }
  return _ParsedExport(
    header: _ExportHeader(salt: _kdfSalt(json['kdf'])),
    payload: _Sealed.parse(json['payload']),
  );
}

class _ExportHeader {
  const _ExportHeader({required this.salt});

  final Uint8List salt;

  /// Binds the format marker and the KDF salt to the ciphertext, so a rewritten
  /// header fails authentication instead of silently deriving another key.
  List<int> payloadAad() => utf8.encode(
    jsonEncode([_domainExport, _version, _suite, base64Encode(salt)]),
  );
}

class _ParsedExport {
  const _ParsedExport({required this.header, required this.payload});

  final _ExportHeader header;
  final _Sealed payload;
}

/// Verifies the key against the existing envelope, then re-seals the payload./// Both steps authenticate the full retained header, so a mismatched key or a
/// tampered header fails closed before any bytes are produced.
Future<Uint8List> _sealWorker(
  Uint8List dataKeyBytes,
  Uint8List envelope,
  VaultData data,
  int revision,
  Uint8List nonce,
) async {
  final parsed = _parseEnvelope(envelope);
  await _verifyKey(parsed, dataKeyBytes);
  final payload = await _sealPayload(
    dataKeyBytes,
    parsed.header,
    parsed.passwordWrap,
    parsed.recoveryWrap,
    data,
    revision,
    nonce,
  );
  return _encodeEnvelope(
    parsed.header,
    parsed.passwordWrap,
    parsed.recoveryWrap,
    payload,
  );
}

Future<Uint8List> _rewrapWorker(
  Uint8List dataKeyBytes,
  Uint8List envelope,
  VaultData data,
  String newPassword,
  int revision,
  Uint8List salt,
  Uint8List nonce,
) async {
  final parsed = _parseEnvelope(envelope);
  await _verifyKey(parsed, dataKeyBytes);
  final key = await _deriveKey(newPassword, salt);
  final header = parsed.header.withPasswordSalt(salt);
  final passwordWrap = await _wrap(
    dataKeyBytes,
    key,
    header.passwordWrapAad(),
    _isolateRandomBytes(_nonceLength),
  );
  final payload = await _sealPayload(
    dataKeyBytes,
    header,
    passwordWrap,
    parsed.recoveryWrap,
    data,
    revision,
    nonce,
  );
  return _encodeEnvelope(header, passwordWrap, parsed.recoveryWrap, payload);
}

/// Proves [dataKeyBytes] belongs to [parsed] before any re-emit.
Future<void> _verifyKey(_ParsedEnvelope parsed, Uint8List dataKeyBytes) async {
  await _decryptPayloadJson(
    dataKeyBytes,
    parsed.payload,
    parsed.header.payloadAad(parsed.passwordWrap, parsed.recoveryWrap),
    FailureCode.format,
  );
}

Future<_Sealed> _sealPayload(
  Uint8List dataKeyBytes,
  _Header header,
  _Sealed passwordWrap,
  _Sealed recoveryWrap,
  VaultData data,
  int revision,
  Uint8List nonce,
) async {
  final plain = v1PayloadBytes(data, revision);
  final box = await AesGcm.with256bits().encrypt(
    plain,
    secretKey: SecretKeyData(dataKeyBytes),
    nonce: nonce,
    aad: header.payloadAad(passwordWrap, recoveryWrap),
  );
  return _Sealed.fromBox(box);
}

Future<_Sealed> _wrap(
  Uint8List dataKeyBytes,
  SecretKey wrappingKey,
  List<int> aad,
  Uint8List nonce,
) async {
  final box = await AesGcm.with256bits().encrypt(
    dataKeyBytes,
    secretKey: wrappingKey,
    nonce: nonce,
    aad: aad,
  );
  return _Sealed.fromBox(box);
}

Future<Uint8List> _unwrap(
  _Sealed sealed,
  SecretKey wrappingKey,
  List<int> aad,
) async {
  final raw = await _decrypt(sealed, wrappingKey, aad, FailureCode.credentials);
  if (raw.length != _dataKeyLength) {
    throw const VaultException(FailureCode.format, 'wrappedKey.length');
  }
  return raw;
}

Future<Uint8List> _decrypt(
  _Sealed sealed,
  SecretKey key,
  List<int> aad,
  FailureCode failure,
) async {
  try {
    final plain = await AesGcm.with256bits().decrypt(
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

Future<Map<String, dynamic>> _decryptPayloadJson(
  Uint8List dataKeyBytes,
  _Sealed sealed,
  List<int> aad,
  FailureCode failure,
) async {
  final plain = await _decrypt(
    sealed,
    SecretKeyData(dataKeyBytes),
    aad,
    failure,
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
  return json;
}

Future<SecretKey> _deriveKey(String value, Uint8List salt) async {
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
  return SecretKeyData(await key.extractBytes());
}

/// Used inside helper isolates, where the instance RNG cannot cross.
Uint8List _isolateRandomBytes(int length) {
  final random = Random.secure();
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = random.nextInt(256);
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
  if (value is! String || !_hexIdPattern.hasMatch(value)) {
    throw const VaultException(FailureCode.format, 'vaultId');
  }
  return Uint8List.fromList([
    for (var i = 0; i < 32; i += 2)
      int.parse(value.substring(i, i + 2), radix: 16),
  ]);
}

final RegExp _hexIdPattern = RegExp(r'^[0-9a-f]{32}$');

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

Uint8List _encodeEnvelope(
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

/// Parses and validates the envelope header; decodes no payload and runs no KDF.
_ParsedEnvelope _parseEnvelope(Uint8List envelope) {
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

  /// Binds the public header and both wrappers to the payload, so no open or
  /// re-emit path can accept a header the writer never authenticated.
  List<int> payloadAad(_Sealed passwordWrap, _Sealed recoveryWrap) => _aad([
    _domainPayload,
    _version,
    _suite,
    _hexId,
    base64Encode(passwordSalt),
    base64Encode(recoverySalt),
    questions,
    passwordWrap.nonceBase64,
    passwordWrap.ciphertextBase64,
    passwordWrap.tagBase64,
    recoveryWrap.nonceBase64,
    recoveryWrap.ciphertextBase64,
    recoveryWrap.tagBase64,
  ]);

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

  String get nonceBase64 => base64Encode(nonce);
  String get ciphertextBase64 => base64Encode(ciphertext);
  String get tagBase64 => base64Encode(tag);

  Map<String, dynamic> toJson() => <String, dynamic>{
    'nonce': nonceBase64,
    'ciphertext': ciphertextBase64,
    'tag': tagBase64,
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
    required this.header,
    required this.passwordWrap,
    required this.recoveryWrap,
    required this.payload,
  });

  final _Header header;
  final _Sealed passwordWrap;
  final _Sealed recoveryWrap;
  final _Sealed payload;
}
