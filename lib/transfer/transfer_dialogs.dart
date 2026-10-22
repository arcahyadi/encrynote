import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';
import '../lock/privacy_signals.dart';
import '../platform/native_bridge.dart';
import '../session/note_session.dart';
import '../transfer/transfer_service.dart';
import '../vault/vault_types.dart';

/// Asks for a new export password, then saves only the prepared ciphertext.
///
/// The fields are dropped as soon as the export starts, so the native save
/// panel never opens with a password in a widget or a note body in this tree.
Future<void> showExportDialog(BuildContext context, TransferService service) =>
    showDialog<void>(
      context: context,
      builder: (_) => _ExportDialog(service: service),
    );

/// Continues the import of a file the user already chose.
///
/// Opening the picker is the only step that needs a fresh selection; a handle
/// kept across a lock is imported again without asking for the file twice.
Future<void> showImportDialog(BuildContext context, TransferService service) =>
    showDialog<void>(
      context: context,
      builder: (_) => _ImportDialog(service: service),
    );

/// Shared behaviour: the dialog lives only while the vault is unlocked, so a
/// lock takes its fields and its captured file name off the screen.
abstract class _GatedDialogState<T extends StatefulWidget> extends State<T> {
  NoteSession get session;

  bool _closing = false;

  @override
  void initState() {
    super.initState();
    session.addListener(_closeIfLocked);
  }

  @override
  void dispose() {
    session.removeListener(_closeIfLocked);
    super.dispose();
  }

  void _closeIfLocked() {
    if (_closing || !mounted || session.phase == SessionPhase.unlocked) return;
    _closing = true;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).pop();
    });
  }

  bool get open => !_closing && session.phase == SessionPhase.unlocked;
}

class _ExportDialog extends StatefulWidget {
  const _ExportDialog({required this.service});

  final TransferService service;

  @override
  State<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends _GatedDialogState<_ExportDialog> {
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  String? _error;
  bool _working = false;

  @override
  NoteSession get session => widget.service.session;

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context)!;
    if (!open || _working) return;
    final password = _password.text;
    if (!validPassword(password)) {
      setState(() => _error = l10n.passwordTooShort);
      return;
    }
    if (password != _confirm.text) {
      setState(() => _error = l10n.passwordMismatch);
      return;
    }
    // Nothing in this tree may keep the password or a note body while the
    // native panel is open; the export itself only carries ciphertext.
    _dropFields();
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final saved = await widget.service.exportNotes(password);
      if (!mounted) return;
      if (!saved) {
        _finish();
        return;
      }
      _finish();
    } on VaultException {
      if (!mounted) return;
      setState(() {
        _working = false;
        _error = l10n.exportFailed;
      });
    }
  }

  void _dropFields() {
    _password.clear();
    _confirm.clear();
  }

  void _finish() {
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (!open) return const SizedBox.shrink();
    return AlertDialog(
      title: Text(l10n.exportDialogTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!_working) ...[
              TextField(
                key: const ValueKey('exportPasswordInput'),
                controller: _password,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                onChanged: (_) => PrivacySignals.reportActivity(context),
                decoration: InputDecoration(
                  labelText: l10n.exportPasswordLabel,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('confirmExportPasswordInput'),
                controller: _confirm,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                onSubmitted: (_) => _submit(),
                onChanged: (_) => PrivacySignals.reportActivity(context),
                decoration: InputDecoration(
                  labelText: l10n.confirmExportPasswordLabel,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                l10n.exportNoRecoveryWarning,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              Text(
                l10n.importMarkdownWarning,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ],
            ] else
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('cancelExportButton'),
          onPressed: _working ? null : _finish,
          child: Text(l10n.cancelButton),
        ),
        FilledButton(
          key: const ValueKey('confirmExportButton'),
          onPressed: _working ? null : _submit,
          child: Text(l10n.exportButton),
        ),
      ],
    );
  }
}

class _ImportDialog extends StatefulWidget {
  const _ImportDialog({required this.service});

  final TransferService service;

  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends _GatedDialogState<_ImportDialog> {
  final _password = TextEditingController();
  PickedImport? _picked;
  bool _needsPassword = false;
  bool _picking = false;
  bool _working = false;
  String? _error;

  @override
  NoteSession get session => widget.service.session;

  @override
  void initState() {
    super.initState();
    _picked = widget.service.pendingImport;
    _needsPassword =
        _picked?.name.toLowerCase().endsWith(TransferService.exportExtension) ??
        false;
    if (_picked == null) _pick();
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final picked = await widget.service.pickImport();
      if (!mounted) return;
      if (picked == null) {
        _finish();
        return;
      }
      setState(() {
        _picked = picked;
        _needsPassword = picked.name.toLowerCase().endsWith(
          TransferService.exportExtension,
        );
        _picking = false;
        _error = null;
      });
    } on VaultException {
      if (!mounted) return;
      setState(() {
        _picking = false;
        _error = AppLocalizations.of(context)!.importFailed;
      });
    }
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context)!;
    final picked = _picked;
    if (!open || _working || picked == null) return;
    final password = _needsPassword ? _password.text : null;
    if (_needsPassword && !validPassword(password!)) {
      setState(() => _error = l10n.passwordTooShort);
      return;
    }
    _password.clear();
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await widget.service.importPicked(picked, exportPassword: password);
      _finish();
    } on VaultException catch (error) {
      if (!mounted) return;
      setState(() {
        _working = false;
        _error = switch (error.code) {
          FailureCode.credentials => l10n.importWrongPassword,
          FailureCode.limit => l10n.importLimit,
          FailureCode.unsupported => l10n.importUnsupported,
          _ => l10n.importFailed,
        };
        // A failed batch released its handle; the user must pick again.
        _picked = widget.service.pendingImport;
      });
    }
  }

  void _cancel() {
    if (_working) return;
    // Cancelling drops the native grant and changes no note.
    widget.service.cancelImport();
    _finish();
  }

  void _finish() {
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (!open) return const SizedBox.shrink();
    final picked = _picked;
    return AlertDialog(
      title: Text(l10n.importDialogTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_picking)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (picked != null) ...[
              Text(
                picked.name.split(RegExp(r'[/\\]')).last,
                key: const ValueKey('importFileName'),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              if (!_needsPassword)
                Text(
                  l10n.importMarkdownWarning,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              if (_needsPassword)
                TextField(
                  key: const ValueKey('importPasswordInput'),
                  controller: _password,
                  obscureText: true,
                  enableSuggestions: false,
                  autocorrect: false,
                  onSubmitted: (_) => _submit(),
                  onChanged: (_) => PrivacySignals.reportActivity(context),
                  decoration: InputDecoration(
                    labelText: l10n.exportPasswordLabel,
                    border: const OutlineInputBorder(),
                  ),
                ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Semantics(
                liveRegion: true,
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('cancelImportButton'),
          onPressed: _working ? null : _cancel,
          child: Text(l10n.cancelButton),
        ),
        FilledButton(
          key: const ValueKey('confirmImportButton'),
          onPressed: _working || picked == null ? null : _submit,
          child: Text(l10n.importButton),
        ),
      ],
    );
  }
}
