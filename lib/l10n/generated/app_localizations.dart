import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'generated/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[Locale('en')];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'EnCryNote'**
  String get appTitle;

  /// No description provided for @loadingTitle.
  ///
  /// In en, this message translates to:
  /// **'Opening your vault...'**
  String get loadingTitle;

  /// No description provided for @createPasswordTitle.
  ///
  /// In en, this message translates to:
  /// **'Create your password'**
  String get createPasswordTitle;

  /// No description provided for @passwordLabel.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get passwordLabel;

  /// No description provided for @confirmPasswordLabel.
  ///
  /// In en, this message translates to:
  /// **'Confirm password'**
  String get confirmPasswordLabel;

  /// No description provided for @recoverySectionTitle.
  ///
  /// In en, this message translates to:
  /// **'Recovery questions'**
  String get recoverySectionTitle;

  /// No description provided for @recoveryQuestionLabel.
  ///
  /// In en, this message translates to:
  /// **'Recovery question {index}'**
  String recoveryQuestionLabel(int index);

  /// No description provided for @recoveryAnswerLabel.
  ///
  /// In en, this message translates to:
  /// **'Answer {index}'**
  String recoveryAnswerLabel(int index);

  /// No description provided for @setupHint.
  ///
  /// In en, this message translates to:
  /// **'Your recovery questions are stored unencrypted in the vault file and can be read while it is locked, so do not put secrets in them. Answers are case-sensitive after trimming outer spaces. Recovery cannot open .encrynote export files.'**
  String get setupHint;

  /// No description provided for @createVaultButton.
  ///
  /// In en, this message translates to:
  /// **'Create vault'**
  String get createVaultButton;

  /// No description provided for @unlockTitle.
  ///
  /// In en, this message translates to:
  /// **'Unlock EnCryNote'**
  String get unlockTitle;

  /// No description provided for @unlockButton.
  ///
  /// In en, this message translates to:
  /// **'Unlock'**
  String get unlockButton;

  /// No description provided for @forgotPasswordButton.
  ///
  /// In en, this message translates to:
  /// **'Forgot password?'**
  String get forgotPasswordButton;

  /// No description provided for @passwordTooShort.
  ///
  /// In en, this message translates to:
  /// **'Use at least 8 characters.'**
  String get passwordTooShort;

  /// No description provided for @passwordMismatch.
  ///
  /// In en, this message translates to:
  /// **'The passwords do not match.'**
  String get passwordMismatch;

  /// No description provided for @questionRequired.
  ///
  /// In en, this message translates to:
  /// **'Enter a question.'**
  String get questionRequired;

  /// No description provided for @answerRequired.
  ///
  /// In en, this message translates to:
  /// **'Enter an answer.'**
  String get answerRequired;

  /// No description provided for @wrongPassword.
  ///
  /// In en, this message translates to:
  /// **'That password is incorrect.'**
  String get wrongPassword;

  /// No description provided for @setupSaveFailed.
  ///
  /// In en, this message translates to:
  /// **'EnCryNote could not save the new vault. Nothing was changed; try again.'**
  String get setupSaveFailed;

  /// No description provided for @unlockFailed.
  ///
  /// In en, this message translates to:
  /// **'The vault could not be unlocked. Try again.'**
  String get unlockFailed;

  /// No description provided for @recoveryTitle.
  ///
  /// In en, this message translates to:
  /// **'Recover your vault'**
  String get recoveryTitle;

  /// No description provided for @recoveryHint.
  ///
  /// In en, this message translates to:
  /// **'Answers are case-sensitive after trimming outer spaces. Recovery cannot open .encrynote export files.'**
  String get recoveryHint;

  /// No description provided for @recoverButton.
  ///
  /// In en, this message translates to:
  /// **'Recover vault'**
  String get recoverButton;

  /// No description provided for @recoveryFailed.
  ///
  /// In en, this message translates to:
  /// **'One or more answers are incorrect.'**
  String get recoveryFailed;

  /// No description provided for @newPasswordTitle.
  ///
  /// In en, this message translates to:
  /// **'Create a new password'**
  String get newPasswordTitle;

  /// No description provided for @newPasswordLabel.
  ///
  /// In en, this message translates to:
  /// **'New password'**
  String get newPasswordLabel;

  /// No description provided for @confirmNewPasswordLabel.
  ///
  /// In en, this message translates to:
  /// **'Confirm new password'**
  String get confirmNewPasswordLabel;

  /// No description provided for @setPasswordButton.
  ///
  /// In en, this message translates to:
  /// **'Save new password'**
  String get setPasswordButton;

  /// No description provided for @recoverySaveFailed.
  ///
  /// In en, this message translates to:
  /// **'EnCryNote could not save the new password. Nothing was changed; try again.'**
  String get recoverySaveFailed;

  /// No description provided for @cancelRecoveryButton.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancelRecoveryButton;

  /// No description provided for @storageErrorTitle.
  ///
  /// In en, this message translates to:
  /// **'Your vault could not be opened'**
  String get storageErrorTitle;

  /// No description provided for @storageCorrupt.
  ///
  /// In en, this message translates to:
  /// **'The vault file is damaged or is not an EnCryNote vault.'**
  String get storageCorrupt;

  /// No description provided for @storageUnsupported.
  ///
  /// In en, this message translates to:
  /// **'This vault was written by a newer or different version of EnCryNote.'**
  String get storageUnsupported;

  /// No description provided for @storageLimit.
  ///
  /// In en, this message translates to:
  /// **'The vault file is too large to open.'**
  String get storageLimit;

  /// No description provided for @storageRead.
  ///
  /// In en, this message translates to:
  /// **'The vault file could not be read. Check the disk and try again.'**
  String get storageRead;

  /// No description provided for @storageBusy.
  ///
  /// In en, this message translates to:
  /// **'The vault is still in use. Try again in a moment.'**
  String get storageBusy;

  /// No description provided for @retryButton.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get retryButton;

  /// No description provided for @saveErrorTitle.
  ///
  /// In en, this message translates to:
  /// **'Your last change is not saved yet'**
  String get saveErrorTitle;

  /// No description provided for @saveErrorBody.
  ///
  /// In en, this message translates to:
  /// **'EnCryNote is keeping the change and will not accept new edits until it is saved. Retry the save now.'**
  String get saveErrorBody;

  /// No description provided for @retryFailed.
  ///
  /// In en, this message translates to:
  /// **'That did not work. Nothing was changed; try again.'**
  String get retryFailed;

  /// No description provided for @notesTitle.
  ///
  /// In en, this message translates to:
  /// **'Notes'**
  String get notesTitle;

  /// No description provided for @lockNowButton.
  ///
  /// In en, this message translates to:
  /// **'Lock now'**
  String get lockNowButton;

  /// No description provided for @newNoteButton.
  ///
  /// In en, this message translates to:
  /// **'New note'**
  String get newNoteButton;

  /// No description provided for @untitledNote.
  ///
  /// In en, this message translates to:
  /// **'Untitled note'**
  String get untitledNote;

  /// No description provided for @selectNoteHint.
  ///
  /// In en, this message translates to:
  /// **'Select a note to read or edit it.'**
  String get selectNoteHint;

  /// No description provided for @noNotesTitle.
  ///
  /// In en, this message translates to:
  /// **'No notes yet'**
  String get noNotesTitle;

  /// No description provided for @noNotesBody.
  ///
  /// In en, this message translates to:
  /// **'Create your first note with New note.'**
  String get noNotesBody;

  /// No description provided for @noteTitleLabel.
  ///
  /// In en, this message translates to:
  /// **'Title'**
  String get noteTitleLabel;

  /// No description provided for @writeTab.
  ///
  /// In en, this message translates to:
  /// **'Write'**
  String get writeTab;

  /// No description provided for @previewTab.
  ///
  /// In en, this message translates to:
  /// **'Preview'**
  String get previewTab;

  /// No description provided for @savedLabel.
  ///
  /// In en, this message translates to:
  /// **'Saved'**
  String get savedLabel;

  /// No description provided for @noteTooLarge.
  ///
  /// In en, this message translates to:
  /// **'This note is too large to save.'**
  String get noteTooLarge;

  /// No description provided for @noteSaveFailed.
  ///
  /// In en, this message translates to:
  /// **'This note could not be saved. Try again.'**
  String get noteSaveFailed;

  /// No description provided for @imageUnavailableOffline.
  ///
  /// In en, this message translates to:
  /// **'Image not available offline.'**
  String get imageUnavailableOffline;

  /// No description provided for @deleteNoteButton.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get deleteNoteButton;

  /// No description provided for @deleteNoteTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete note?'**
  String get deleteNoteTitle;

  /// No description provided for @deleteNoteBody.
  ///
  /// In en, this message translates to:
  /// **'Delete \"{title}\"? This cannot be undone.'**
  String deleteNoteBody(String title);

  /// No description provided for @deleteNoteBodyUntitled.
  ///
  /// In en, this message translates to:
  /// **'Delete this untitled note? This cannot be undone.'**
  String get deleteNoteBodyUntitled;

  /// No description provided for @cancelButton.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancelButton;

  /// No description provided for @backToNotesTooltip.
  ///
  /// In en, this message translates to:
  /// **'Back to notes'**
  String get backToNotesTooltip;

  /// No description provided for @settingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// No description provided for @settingsButton.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsButton;

  /// No description provided for @autoLockTitle.
  ///
  /// In en, this message translates to:
  /// **'Auto-lock'**
  String get autoLockTitle;

  /// No description provided for @autoLockImmediately.
  ///
  /// In en, this message translates to:
  /// **'Immediately'**
  String get autoLockImmediately;

  /// No description provided for @autoLockOneMinute.
  ///
  /// In en, this message translates to:
  /// **'1 minute'**
  String get autoLockOneMinute;

  /// No description provided for @autoLockFiveMinutes.
  ///
  /// In en, this message translates to:
  /// **'5 minutes'**
  String get autoLockFiveMinutes;

  /// No description provided for @autoLockTenMinutes.
  ///
  /// In en, this message translates to:
  /// **'10 minutes'**
  String get autoLockTenMinutes;

  /// No description provided for @settingsLockedHint.
  ///
  /// In en, this message translates to:
  /// **'Your vault is locked. Unlock to change this.'**
  String get settingsLockedHint;

  /// No description provided for @settingsFrozenHint.
  ///
  /// In en, this message translates to:
  /// **'A change is not saved yet. Auto-lock stays read-only until the save succeeds.'**
  String get settingsFrozenHint;

  /// No description provided for @settingsSaveFailed.
  ///
  /// In en, this message translates to:
  /// **'The new auto-lock time is in effect but is not saved yet. It will apply again once the save succeeds.'**
  String get settingsSaveFailed;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
