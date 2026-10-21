import 'dart:typed_data';

import 'package:characters/characters.dart';
import 'package:cryptography/cryptography.dart';

/// Reasons a vault operation can fail. Messages never carry secrets.
enum FailureCode { credentials, format, unsupported, limit, storage, busy }

class VaultException implements Exception {
  const VaultException(this.code, [this.detail]);

  final FailureCode code;

  /// Developer-facing field name or reason; never contains user secrets.
  final String? detail;

  @override
  String toString() =>
      'VaultException(${code.name}${detail == null ? '' : ': $detail'})';
}

enum AutoLockMode {
  immediately('immediately'),
  oneMinute('oneMinute'),
  fiveMinutes('fiveMinutes'),
  tenMinutes('tenMinutes');

  const AutoLockMode(this.storageValue);

  final String storageValue;

  static AutoLockMode fromStorage(String value) {
    for (final mode in AutoLockMode.values) {
      if (mode.storageValue == value) return mode;
    }
    throw const VaultException(FailureCode.format, 'autoLock');
  }
}

/// Password rule: at least 8 visible (grapheme) characters, no trimming.
bool validPassword(String value) => value.characters.length >= 8;

final RegExp _hexId = RegExp(r'^[0-9a-f]{32}$');

class Note {
  Note({
    required this.id,
    required this.title,
    required this.markdown,
    required DateTime createdAt,
    required DateTime updatedAt,
  }) : createdAt = createdAt.toUtc(),
       updatedAt = updatedAt.toUtc() {
    if (!_hexId.hasMatch(id)) {
      throw const VaultException(FailureCode.format, 'note.id');
    }
  }

  factory Note.fromJson(Map<String, dynamic> json) => Note(
    id: json['id'] as String,
    title: json['title'] as String,
    markdown: json['markdown'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
    updatedAt: DateTime.parse(json['updatedAt'] as String),
  );

  final String id;
  final String title;
  final String markdown;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'title': title,
    'markdown': markdown,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  Note copyWith({String? title, String? markdown, DateTime? updatedAt}) => Note(
    id: id,
    title: title ?? this.title,
    markdown: markdown ?? this.markdown,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}

class VaultData {
  VaultData({required List<Note> notes, this.autoLock = AutoLockMode.oneMinute})
    : notes = List.unmodifiable(notes);

  factory VaultData.fromJson(Map<String, dynamic> json) => VaultData(
    notes: (json['notes'] as List<dynamic>)
        .map((note) => Note.fromJson(note as Map<String, dynamic>))
        .toList(),
    autoLock: AutoLockMode.fromStorage(json['autoLock'] as String),
  );

  final List<Note> notes;
  final AutoLockMode autoLock;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'autoLock': autoLock.storageValue,
    'notes': notes.map((note) => note.toJson()).toList(),
  };

  VaultData copyWith({List<Note>? notes, AutoLockMode? autoLock}) => VaultData(
    notes: notes ?? this.notes,
    autoLock: autoLock ?? this.autoLock,
  );
}

class RecoveryConfig {
  factory RecoveryConfig({
    required List<String> questions,
    required List<String> answers,
  }) {
    if (questions.length != 3 || answers.length != 3) {
      throw const VaultException(FailureCode.format, 'recovery.count');
    }
    final trimmedAnswers = answers.map((answer) => answer.trim()).toList();
    for (final question in questions) {
      if (question.trim().isEmpty) {
        throw const VaultException(FailureCode.format, 'recovery.question');
      }
    }
    for (final answer in trimmedAnswers) {
      if (answer.isEmpty) {
        throw const VaultException(FailureCode.format, 'recovery.answer');
      }
    }
    return RecoveryConfig._(
      questions: List.unmodifiable(questions),
      answers: List.unmodifiable(trimmedAnswers),
    );
  }

  const RecoveryConfig._({required this.questions, required this.answers});

  final List<String> questions;
  final List<String> answers;
}

class UnlockedVault {
  const UnlockedVault({
    required this.envelope,
    required this.dataKey,
    required this.data,
    required this.revision,
  });

  final Uint8List envelope;
  final SecretKey dataKey;
  final VaultData data;
  final int revision;
}
