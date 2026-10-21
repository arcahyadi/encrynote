import 'package:hello_flutter/vault/vault_types.dart';

/// Synthetic vault fixtures shared by the vault, session and transfer tests.
const String localPassword = 'local-1234';

final VaultData fixtureData = VaultData(
  notes: [
    Note(
      id: '0123456789abcdef0123456789abcdef',
      title: 'Fixture Note Title',
      markdown: '# Fixture Markdown Body\n\nciphertext-marker-42\n',
      createdAt: DateTime.utc(2026, 10, 22, 9, 30),
      updatedAt: DateTime.utc(2026, 10, 22, 10, 15),
    ),
  ],
);

final RecoveryConfig fixtureRecovery = RecoveryConfig(
  questions: const ['First pet name?', 'Favorite street?', 'First school?'],
  answers: const ['Rex', 'Blue House', 'SMA 1'],
);
