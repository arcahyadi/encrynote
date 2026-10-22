import 'dart:async';

import 'package:flutter/material.dart';

import 'auth/auth_screen.dart';
import 'l10n/generated/app_localizations.dart';
import 'notes/notes_screen.dart';
import 'session/note_session.dart';
import 'settings/settings_screen.dart';
import 'transfer/transfer_dialogs.dart';
import 'transfer/transfer_service.dart';

/// The application shell: English-only localization, a Material theme from the
/// existing deep purple seed, and OS-driven light/dark pairing.
///
/// Routing lives here, above the auth screen, so the transfer service can offer
/// the import it was holding across a lock without rebuilding a widget that the
/// lock already disposed.
class EnCryNoteApp extends StatefulWidget {
  const EnCryNoteApp({
    super.key,
    required this.session,
    required this.transfer,
  });

  final NoteSession session;
  final TransferService transfer;

  @override
  State<EnCryNoteApp> createState() => _EnCryNoteAppState();
}

class _EnCryNoteAppState extends State<EnCryNoteApp> {
  /// The app's own navigator, so a resume dialog is shown below
  /// `MaterialApp`'s localizations rather than above them.
  final GlobalKey<NavigatorState> _navigator = GlobalKey<NavigatorState>();

  /// True while a transfer was interrupted by a lock: either a selection was
  /// already held, or the picker returned after the lock. Only then is the
  /// handle offered again, so a dialog the notes screen owns is never
  /// duplicated and a dismissed resume is never reopened in a loop.
  bool _suspended = false;
  SessionPhase? _phase;

  @override
  void initState() {
    super.initState();
    _phase = widget.session.phase;
    widget.session.addListener(_onSessionChanged);
    widget.transfer.addListener(_onTransferChanged);
  }

  @override
  void didUpdateWidget(EnCryNoteApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      oldWidget.session.removeListener(_onSessionChanged);
      widget.session.addListener(_onSessionChanged);
    }
    if (oldWidget.transfer != widget.transfer) {
      oldWidget.transfer.removeListener(_onTransferChanged);
      widget.transfer.addListener(_onTransferChanged);
    }
    _phase = widget.session.phase;
    _suspended = false;
  }

  @override
  void dispose() {
    widget.session.removeListener(_onSessionChanged);
    widget.transfer.removeListener(_onTransferChanged);
    super.dispose();
  }

  void _onTransferChanged() {
    if (!mounted) return;
    setState(() {});
    // A picker that finishes after the lock still leaves only its handle; it
    // must be offered once the vault is unlocked again.
    if (widget.session.phase != SessionPhase.unlocked &&
        widget.transfer.pendingImport != null) {
      _suspended = true;
    }
  }

  void _onSessionChanged() {
    if (!mounted) return;
    final phase = widget.session.phase;
    final previous = _phase;
    _phase = phase;
    setState(() {});
    if (phase != SessionPhase.unlocked) {
      // A lock interrupts whatever selection the service is holding.
      if (widget.transfer.pendingImport != null) _suspended = true;
      return;
    }
    if (previous == SessionPhase.unlocked || !_suspended) return;
    _suspended = false;
    if (widget.transfer.pendingImport == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.session.phase != SessionPhase.unlocked) return;
      final pending = widget.transfer.pendingImport;
      if (pending == null) return;
      final context = _navigator.currentContext;
      if (context == null) return;
      unawaited(showImportDialog(context, widget.transfer));
    });
  }

  @override
  Widget build(BuildContext context) {
    final unlocked = widget.session.phase == SessionPhase.unlocked;
    return MaterialApp(
      navigatorKey: _navigator,
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
      home: unlocked
          ? NotesScreen(session: widget.session, transfer: widget.transfer)
          : AuthScreen(session: widget.session),
      routes: {
        SettingsScreen.routeName: (_) =>
            SettingsScreen(session: widget.session),
      },
    );
  }
}
