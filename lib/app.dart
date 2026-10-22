import 'package:flutter/material.dart';

import 'auth/auth_screen.dart';
import 'l10n/generated/app_localizations.dart';
import 'session/note_session.dart';
import 'settings/settings_screen.dart';

/// The application shell: English-only localization, a Material theme from the
/// existing deep purple seed, and OS-driven light/dark pairing.
class EnCryNoteApp extends StatelessWidget {
  const EnCryNoteApp({super.key, required this.session});

  final NoteSession session;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      onGenerateTitle: (context) => AppLocalizations.of(context)!.appTitle,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.dark,
        ),
      ),
      themeMode: ThemeMode.system,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: AuthScreen(session: session),
      routes: {
        SettingsScreen.routeName: (_) => SettingsScreen(session: session),
      },
    );
  }
}
