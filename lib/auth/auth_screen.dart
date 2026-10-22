import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';
import '../session/note_session.dart';
import '../vault/vault_types.dart';

/// Setup, unlock and recovery, driven entirely by [NoteSession.phase].
///
/// Each form owns its controllers and drops them as soon as the session leaves
/// that phase, so no password, answer or confirmation outlives the form that
/// asked for it. Only `unlocked` shows note content; readable frozen data in
/// `storageError` is never treated as permission.
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, required this.session});

  final NoteSession session;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  _SetupFields? _setupFields;
  _UnlockFields? _unlockFields;
  _RecoveryFields? _recoveryFields;
  _NewPasswordFields? _newPasswordFields;

  bool _showingRecovery = false;
  String? _error;
  SessionPhase? _phase;

  @override
  void initState() {
    super.initState();
    _phase = widget.session.phase;
    widget.session.addListener(_dropStaleFields);
  }

  @override
  void didUpdateWidget(AuthScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      oldWidget.session.removeListener(_dropStaleFields);
      widget.session.addListener(_dropStaleFields);
      _phase = widget.session.phase;
      _dropAllFields();
    }
  }

  @override
  void dispose() {
    widget.session.removeListener(_dropStaleFields);
    _dropAllFields();
    super.dispose();
  }

  void _dropStaleFields() {
    // A message from one phase must never leak into the next form.
    if (widget.session.phase != _phase) {
      _phase = widget.session.phase;
      _error = null;
    }
    switch (widget.session.phase) {
      case SessionPhase.needsSetup:
        _dropUnlock();
        _dropRecovery();
        _dropNewPassword();
      case SessionPhase.locked:
        _dropSetup();
        _dropNewPassword();
      case SessionPhase.recovering:
        _dropSetup();
        _dropUnlock();
        _dropRecovery();
      case SessionPhase.unlocked:
      case SessionPhase.storageError:
      case SessionPhase.loading:
        _dropAllFields();
    }
  }

  void _dropAllFields() {
    _dropSetup();
    _dropUnlock();
    _dropRecovery();
    _dropNewPassword();
  }

  void _dropSetup() {
    _setupFields?.dispose();
    _setupFields = null;
  }

  void _dropUnlock() {
    _unlockFields?.dispose();
    _unlockFields = null;
  }

  void _dropRecovery() {
    _recoveryFields?.dispose();
    _recoveryFields = null;
    _showingRecovery = false;
  }

  void _dropNewPassword() {
    _newPasswordFields?.dispose();
    _newPasswordFields = null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: widget.session,
          builder: (context, _) => Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Semantics(
                      header: true,
                      child: Text(
                        l10n.appTitle,
                        style: Theme.of(context).textTheme.headlineMedium,
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(height: 24),
                    _body(l10n),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(AppLocalizations l10n) {
    switch (widget.session.phase) {
      case SessionPhase.loading:
        return Column(
          children: [
            const Center(child: CircularProgressIndicator()),
            const SizedBox(height: 16),
            Text(l10n.loadingTitle, textAlign: TextAlign.center),
          ],
        );
      case SessionPhase.needsSetup:
        return _setup(l10n);
      case SessionPhase.locked:
        return _showingRecovery ? _recovery(l10n) : _unlock(l10n);
      case SessionPhase.recovering:
        return _newPasswordForm(l10n);
      case SessionPhase.storageError:
        return _storageError(l10n);
      case SessionPhase.unlocked:
        return _unlocked(l10n);
    }
  }

  // --- shared pieces -------------------------------------------------------

  Widget _heading(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Semantics(
      header: true,
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleLarge,
        textAlign: TextAlign.center,
      ),
    ),
  );

  Widget _hint(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Text(text, style: Theme.of(context).textTheme.bodySmall),
  );

  Widget _errorText(String? message) {
    if (message == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Semantics(
        liveRegion: true,
        child: Text(
          message,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      ),
    );
  }

  Widget _secretField({
    required Key key,
    required TextEditingController controller,
    required String label,
    TextInputAction action = TextInputAction.next,
    VoidCallback? onSubmitted,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TextFormField(
      key: key,
      controller: controller,
      obscureText: true,
      enableSuggestions: false,
      autocorrect: false,
      textInputAction: action,
      onFieldSubmitted: onSubmitted == null ? null : (_) => onSubmitted(),
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
    ),
  );

  Widget _plainField({
    required Key key,
    required TextEditingController controller,
    required String label,
    TextInputAction action = TextInputAction.next,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TextFormField(
      key: key,
      controller: controller,
      textInputAction: action,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
    ),
  );

  Widget _action({
    required Key key,
    required String label,
    required Future<void> Function() onPressed,
  }) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: FilledButton(
      key: key,
      onPressed: widget.session.isBusy
          ? null
          : () {
              setState(() => _error = null);
              onPressed();
            },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(label),
      ),
    ),
  );

  void _fail(String message) => setState(() => _error = message);

  // --- setup ---------------------------------------------------------------

  Widget _setup(AppLocalizations l10n) {
    final fields = _setupFields ??= _SetupFields();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading(l10n.createPasswordTitle),
        _secretField(
          key: const ValueKey('passwordInput'),
          controller: fields.password,
          label: l10n.passwordLabel,
        ),
        _secretField(
          key: const ValueKey('confirmPasswordInput'),
          controller: fields.confirmPassword,
          label: l10n.confirmPasswordLabel,
          action: TextInputAction.done,
          onSubmitted: _submitSetup,
        ),
        _heading(l10n.recoverySectionTitle),
        _hint(l10n.setupHint),
        for (var i = 0; i < 3; i++) ...[
          _plainField(
            key: ValueKey('question${i + 1}'),
            controller: fields.questions[i],
            label: l10n.recoveryQuestionLabel(i + 1),
          ),
          _plainField(
            key: ValueKey('answer${i + 1}'),
            controller: fields.answers[i],
            label: l10n.recoveryAnswerLabel(i + 1),
          ),
        ],
        _errorText(_error),
        _action(
          key: const ValueKey('createVaultButton'),
          label: l10n.createVaultButton,
          onPressed: _submitSetup,
        ),
      ],
    );
  }

  Future<void> _submitSetup() async {
    final l10n = AppLocalizations.of(context)!;
    final fields = _setupFields;
    if (fields == null) return;
    final password = fields.password.text;
    if (!validPassword(password)) return _fail(l10n.passwordTooShort);
    if (password != fields.confirmPassword.text) {
      return _fail(l10n.passwordMismatch);
    }
    if (fields.questions.any((field) => field.text.trim().isEmpty)) {
      return _fail(l10n.questionRequired);
    }
    if (fields.answers.any((field) => field.text.trim().isEmpty)) {
      return _fail(l10n.answerRequired);
    }

    final recovery = RecoveryConfig(
      questions: [for (final field in fields.questions) field.text],
      answers: [for (final field in fields.answers) field.text],
    );
    try {
      await widget.session.setup(password, recovery);
    } on VaultException catch (error) {
      if (!mounted) return;
      _fail(
        error.code == FailureCode.credentials
            ? l10n.passwordTooShort
            : l10n.setupSaveFailed,
      );
    }
  }

  // --- unlock --------------------------------------------------------------

  Widget _unlock(AppLocalizations l10n) {
    final fields = _unlockFields ??= _UnlockFields();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading(l10n.unlockTitle),
        _secretField(
          key: const ValueKey('unlockPasswordInput'),
          controller: fields.password,
          label: l10n.passwordLabel,
          action: TextInputAction.done,
          onSubmitted: _submitUnlock,
        ),
        _errorText(_error),
        _action(
          key: const ValueKey('unlockButton'),
          label: l10n.unlockButton,
          onPressed: _submitUnlock,
        ),
        TextButton(
          key: const ValueKey('forgotPasswordButton'),
          onPressed: widget.session.isBusy ? null : _startRecovery,
          child: Text(l10n.forgotPasswordButton),
        ),
      ],
    );
  }

  Future<void> _submitUnlock() async {
    final l10n = AppLocalizations.of(context)!;
    final fields = _unlockFields;
    if (fields == null) return;
    final password = fields.password.text;
    if (!validPassword(password)) return _fail(l10n.passwordTooShort);
    try {
      await widget.session.unlock(password);
    } on VaultException catch (error) {
      if (!mounted) return;
      _fail(
        error.code == FailureCode.credentials
            ? l10n.wrongPassword
            : l10n.unlockFailed,
      );
    }
  }

  // --- recovery ------------------------------------------------------------

  void _startRecovery() => setState(() {
    _error = null;
    _dropRecovery();
    _recoveryFields = _RecoveryFields();
    _showingRecovery = true;
  });

  Widget _recovery(AppLocalizations l10n) {
    final fields = _recoveryFields ??= _RecoveryFields();
    final questions = widget.session.recoveryQuestions;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading(l10n.recoveryTitle),
        _hint(l10n.recoveryHint),
        for (var i = 0; i < questions.length; i++) ...[
          Text(questions[i], style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          _plainField(
            key: ValueKey('recoveryAnswer${i + 1}'),
            controller: fields.answers[i],
            label: l10n.recoveryAnswerLabel(i + 1),
          ),
        ],
        _errorText(_error),
        _action(
          key: const ValueKey('recoverButton'),
          label: l10n.recoverButton,
          onPressed: _submitRecovery,
        ),
        TextButton(
          key: const ValueKey('cancelRecoveryButton'),
          onPressed: widget.session.isBusy
              ? null
              : () => setState(() {
                  _error = null;
                  _dropRecovery();
                }),
          child: Text(l10n.cancelRecoveryButton),
        ),
      ],
    );
  }

  Future<void> _submitRecovery() async {
    final l10n = AppLocalizations.of(context)!;
    final fields = _recoveryFields;
    if (fields == null) return;
    if (fields.answers.any((field) => field.text.trim().isEmpty)) {
      return _fail(l10n.answerRequired);
    }
    try {
      await widget.session.beginRecovery([
        for (final field in fields.answers) field.text,
      ]);
    } on VaultException catch (error) {
      if (!mounted) return;
      _fail(
        error.code == FailureCode.credentials
            ? l10n.recoveryFailed
            : l10n.unlockFailed,
      );
    }
  }

  Widget _newPasswordForm(AppLocalizations l10n) {
    final fields = _newPasswordFields ??= _NewPasswordFields();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading(l10n.newPasswordTitle),
        _secretField(
          key: const ValueKey('newPasswordInput'),
          controller: fields.password,
          label: l10n.newPasswordLabel,
        ),
        _secretField(
          key: const ValueKey('newConfirmPasswordInput'),
          controller: fields.confirmPassword,
          label: l10n.confirmNewPasswordLabel,
        ),
        _errorText(_error),
        _action(
          key: const ValueKey('setPasswordButton'),
          label: l10n.setPasswordButton,
          onPressed: _submitNewPassword,
        ),
        TextButton(
          key: const ValueKey('cancelRecoveryButton'),
          onPressed: widget.session.isBusy ? null : () => widget.session.lock(),
          child: Text(l10n.cancelRecoveryButton),
        ),
      ],
    );
  }

  Future<void> _submitNewPassword() async {
    final l10n = AppLocalizations.of(context)!;
    final fields = _newPasswordFields;
    if (fields == null) return;
    final password = fields.password.text;
    if (!validPassword(password)) return _fail(l10n.passwordTooShort);
    if (password != fields.confirmPassword.text) {
      return _fail(l10n.passwordMismatch);
    }
    try {
      await widget.session.completeRecovery(password);
    } on VaultException catch (error) {
      if (!mounted) return;
      _fail(
        error.code == FailureCode.credentials
            ? l10n.passwordTooShort
            : l10n.recoverySaveFailed,
      );
    }
  }

  // --- errors and unlocked placeholder ------------------------------------

  Widget _storageError(AppLocalizations l10n) {
    // A load failure has no open vault to retry writing; a save failure does.
    final reload = widget.session.needsReload;
    final body = switch (widget.session.failure) {
      FailureCode.format => l10n.storageCorrupt,
      FailureCode.unsupported => l10n.storageUnsupported,
      FailureCode.limit => l10n.storageLimit,
      FailureCode.busy => l10n.storageBusy,
      _ => l10n.storageRead,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading(reload ? l10n.storageErrorTitle : l10n.saveErrorTitle),
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Text(
            reload ? body : l10n.saveErrorBody,
            textAlign: TextAlign.center,
          ),
        ),
        _errorText(_error),
        _action(
          key: const ValueKey('retryButton'),
          label: l10n.retryButton,
          onPressed: () async {
            try {
              if (reload) {
                await widget.session.load();
              } else {
                await widget.session.retrySave();
              }
            } on VaultException {
              if (!mounted) return;
              _fail(l10n.retryFailed);
            }
          },
        ),
      ],
    );
  }

  Widget _unlocked(AppLocalizations l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading(l10n.unlockedTitle),
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Text(l10n.unlockedBody, textAlign: TextAlign.center),
        ),
        _action(
          key: const ValueKey('lockNowButton'),
          label: l10n.lockNowButton,
          onPressed: () => widget.session.lock(),
        ),
      ],
    );
  }
}

/// Password, confirmation and the three recovery pairs for setup.
class _SetupFields {
  final password = TextEditingController();
  final confirmPassword = TextEditingController();
  final questions = List.generate(3, (_) => TextEditingController());
  final answers = List.generate(3, (_) => TextEditingController());

  void dispose() {
    password.dispose();
    confirmPassword.dispose();
    for (final field in [...questions, ...answers]) {
      field.dispose();
    }
  }
}

class _UnlockFields {
  final password = TextEditingController();

  void dispose() => password.dispose();
}

class _RecoveryFields {
  final answers = List.generate(3, (_) => TextEditingController());

  void dispose() {
    for (final field in answers) {
      field.dispose();
    }
  }
}

class _NewPasswordFields {
  final password = TextEditingController();
  final confirmPassword = TextEditingController();

  void dispose() {
    password.dispose();
    confirmPassword.dispose();
  }
}
