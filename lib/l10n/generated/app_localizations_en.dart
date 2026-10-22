// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'EnCryNote';

  @override
  String get loadingTitle => 'Opening your vault...';

  @override
  String get createPasswordTitle => 'Create your password';

  @override
  String get passwordLabel => 'Password';

  @override
  String get confirmPasswordLabel => 'Confirm password';

  @override
  String get recoverySectionTitle => 'Recovery questions';

  @override
  String recoveryQuestionLabel(int index) {
    return 'Recovery question $index';
  }

  @override
  String recoveryAnswerLabel(int index) {
    return 'Answer $index';
  }

  @override
  String get setupHint =>
      'Your recovery questions are stored unencrypted in the vault file and can be read while it is locked, so do not put secrets in them. Answers are case-sensitive after trimming outer spaces. Recovery cannot open .encrynote export files.';

  @override
  String get createVaultButton => 'Create vault';

  @override
  String get unlockTitle => 'Unlock EnCryNote';

  @override
  String get unlockButton => 'Unlock';

  @override
  String get forgotPasswordButton => 'Forgot password?';

  @override
  String get passwordTooShort => 'Use at least 8 characters.';

  @override
  String get passwordMismatch => 'The passwords do not match.';

  @override
  String get questionRequired => 'Enter a question.';

  @override
  String get answerRequired => 'Enter an answer.';

  @override
  String get wrongPassword => 'That password is incorrect.';

  @override
  String get setupSaveFailed =>
      'EnCryNote could not save the new vault. Nothing was changed; try again.';

  @override
  String get unlockFailed => 'The vault could not be unlocked. Try again.';

  @override
  String get recoveryTitle => 'Recover your vault';

  @override
  String get recoveryHint =>
      'Answers are case-sensitive after trimming outer spaces. Recovery cannot open .encrynote export files.';

  @override
  String get recoverButton => 'Recover vault';

  @override
  String get recoveryFailed => 'One or more answers are incorrect.';

  @override
  String get newPasswordTitle => 'Create a new password';

  @override
  String get newPasswordLabel => 'New password';

  @override
  String get confirmNewPasswordLabel => 'Confirm new password';

  @override
  String get setPasswordButton => 'Save new password';

  @override
  String get recoverySaveFailed =>
      'EnCryNote could not save the new password. Nothing was changed; try again.';

  @override
  String get cancelRecoveryButton => 'Cancel';

  @override
  String get storageErrorTitle => 'Your vault could not be opened';

  @override
  String get storageCorrupt =>
      'The vault file is damaged or is not an EnCryNote vault.';

  @override
  String get storageUnsupported =>
      'This vault was written by a newer or different version of EnCryNote.';

  @override
  String get storageLimit => 'The vault file is too large to open.';

  @override
  String get storageRead =>
      'The vault file could not be read. Check the disk and try again.';

  @override
  String get storageBusy => 'The vault is still in use. Try again in a moment.';

  @override
  String get retryButton => 'Retry';

  @override
  String get saveErrorTitle => 'Your last change is not saved yet';

  @override
  String get saveErrorBody =>
      'EnCryNote is keeping the change and will not accept new edits until it is saved. Retry the save now.';

  @override
  String get retryFailed =>
      'That did not work. Nothing was changed; try again.';

  @override
  String get unlockedTitle => 'Your vault is unlocked';

  @override
  String get unlockedBody => 'Your notes will appear here.';

  @override
  String get lockNowButton => 'Lock now';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get settingsButton => 'Settings';

  @override
  String get autoLockTitle => 'Auto-lock';

  @override
  String get autoLockImmediately => 'Immediately';

  @override
  String get autoLockOneMinute => '1 minute';

  @override
  String get autoLockFiveMinutes => '5 minutes';

  @override
  String get autoLockTenMinutes => '10 minutes';

  @override
  String get settingsLockedHint =>
      'Your vault is locked. Unlock to change this.';

  @override
  String get settingsFrozenHint =>
      'A change is not saved yet. Auto-lock stays read-only until the save succeeds.';

  @override
  String get settingsSaveFailed =>
      'The new auto-lock time is in effect but is not saved yet. It will apply again once the save succeeds.';
}
