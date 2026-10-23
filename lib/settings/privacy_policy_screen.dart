import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';

/// The privacy policy, read from the bundled English string.
///
/// The text ships inside the app, so the policy is readable with no network,
/// no WebView and no external link. It is pushed above Settings, which the lock
/// already closes down to the auth surface.
class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.privacyPolicyTitle)),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Text(
          l10n.privacyPolicyBody,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ),
    );
  }
}
