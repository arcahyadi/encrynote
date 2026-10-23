import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';
import '../session/note_session.dart';
import '../vault/vault_types.dart';

/// The four approved auto-lock choices, saved through [NoteSession].
///
/// Only an editable session may change the preference; a locked or recovering
/// one shows the saved value read-only instead of pretending it can save.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.session});

  static const String routeName = '/settings';

  final NoteSession session;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String? _error;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_onSessionChanged);
  }

  @override
  void didUpdateWidget(SettingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      oldWidget.session.removeListener(_onSessionChanged);
      widget.session.addListener(_onSessionChanged);
    }
  }

  @override
  void dispose() {
    widget.session.removeListener(_onSessionChanged);
    super.dispose();
  }

  /// Settings is opened from the unlocked notes surface; once the vault is no
  /// longer unlocked it must not sit above the auth screen.
  void _onSessionChanged() {
    if (_closing || !mounted || widget.session.phase == SessionPhase.unlocked) {
      return;
    }
    _closing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final navigator = Navigator.of(context);
      if (navigator.canPop()) navigator.pop();
    });
  }

  static const List<AutoLockMode> _modes = [
    AutoLockMode.immediately,
    AutoLockMode.oneMinute,
    AutoLockMode.fiveMinutes,
    AutoLockMode.tenMinutes,
  ];

  String _label(AppLocalizations l10n, AutoLockMode mode) => switch (mode) {
    AutoLockMode.immediately => l10n.autoLockImmediately,
    AutoLockMode.oneMinute => l10n.autoLockOneMinute,
    AutoLockMode.fiveMinutes => l10n.autoLockFiveMinutes,
    AutoLockMode.tenMinutes => l10n.autoLockTenMinutes,
  };

  Future<void> _choose(AutoLockMode? mode) async {
    if (mode == null || !widget.session.canMutate) return;
    setState(() => _error = null);
    try {
      await widget.session.setAutoLock(mode);
    } on VaultException {
      if (!mounted) return;
      setState(() => _error = AppLocalizations.of(context)!.settingsSaveFailed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsTitle)),
      body: ListenableBuilder(
        listenable: widget.session,
        builder: (context, _) {
          final editable = widget.session.canMutate;
          final error = _error;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Semantics(
                header: true,
                child: Text(
                  l10n.autoLockTitle,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              const SizedBox(height: 8),
              RadioGroup<AutoLockMode>(
                groupValue: widget.session.autoLock,
                onChanged: editable ? _choose : (_) {},
                child: Column(
                  children: [
                    for (final mode in _modes)
                      RadioListTile<AutoLockMode>(
                        key: ValueKey('autoLock:${mode.storageValue}'),
                        value: mode,
                        enabled: editable,
                        title: Text(_label(l10n, mode)),
                      ),
                  ],
                ),
              ),
              if (!editable)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    widget.session.phase == SessionPhase.storageError
                        ? l10n.settingsFrozenHint
                        : l10n.settingsLockedHint,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      error,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ),
              const Divider(height: 32),
              ListTile(
                key: const ValueKey('licensesButton'),
                leading: const Icon(Icons.description_outlined),
                title: Text(l10n.settingsLicensesButton),
                // The standard Flutter page reads LicenseRegistry, which the
                // engine fills from the bundled NOTICES asset, so every shipped
                // dependency's text is readable inside the app.
                onTap: () => showLicensePage(
                  context: context,
                  applicationName: l10n.appTitle,
                  applicationVersion: '1.0.0',
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
