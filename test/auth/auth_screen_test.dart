import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hello_flutter/app.dart';
import 'package:hello_flutter/lock/privacy_signals.dart';
import 'package:hello_flutter/session/note_session.dart';
import 'package:hello_flutter/transfer/transfer_service.dart';
import 'package:hello_flutter/vault/vault_crypto.dart';
import 'package:hello_flutter/vault/vault_store.dart';
import 'package:hello_flutter/vault/vault_types.dart';

import '../support/fake_native_bridge.dart';
import '../support/fixtures.dart';

const String newPassword = 'recovered-123';

/// Setup, unlock and recovery widget tests.
///
/// Key derivation runs in a real isolate and the vault uses real files, so every
/// IO or crypto step inside a test body goes through [io]; the fake-async zone
/// of `testWidgets` would otherwise never complete those futures.
void main() {
  final crypto = VaultCrypto();
  late Uint8List seed;
  late Directory scratchRoot;
  late Directory dir;
  late FakeNativeBridge native;
  late NoteSession session;
  late TransferService transfer;
  var scratch = 0;

  setUpAll(() async {
    seed = (await crypto.createVault(
      localPassword,
      fixtureRecovery,
      fixtureData,
    )).envelope;
    scratchRoot = await Directory(
      '${Directory.current.path}/.dart_tool/test_scratch/auth_screen/'
      '${DateTime.now().microsecondsSinceEpoch}',
    ).create(recursive: true);
  });

  tearDownAll(() async {
    if (await scratchRoot.exists()) await scratchRoot.delete(recursive: true);
  });

  setUp(() async {
    scratch++;
    dir = await Directory('${scratchRoot.path}/$scratch')
        .create(recursive: true);
    native = FakeNativeBridge();
    session = NoteSession(
      crypto: crypto,
      store: VaultStore(directory: dir, native: native),
    );
    transfer = TransferService(
      session: session,
      crypto: crypto,
      native: native,
    );
  });

  tearDown(() {
    session.dispose();
    transfer.dispose();
  });

  Future<T> io<T>(WidgetTester tester, Future<T> Function() body) async {
    final value = await tester.runAsync(body);
    return value as T;
  }

  void useTallViewport(WidgetTester tester) {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(800, 1200);
    addTearDown(tester.view.reset);
  }

  Future<void> load(WidgetTester tester) => io(tester, session.load);

  Future<void> seedVault(WidgetTester tester) =>
      io(tester, () => File('${dir.path}/vault.enc').writeAsBytes(seed));

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(EnCryNoteApp(session: session, transfer: transfer));
    await tester.pump();
  }

  /// Runs [action] in the real zone and waits for [done], then paints.
  Future<void> act(
    WidgetTester tester,
    Future<void> Function() action, {
    required bool Function() done,
  }) async {
    await io(tester, () async {
      await action();
      final watch = Stopwatch()..start();
      while (!done() && watch.elapsed < const Duration(seconds: 60)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    expect(done(), isTrue, reason: 'the action did not settle in time');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> enter(WidgetTester tester, String key, String text) async {
    await tester.enterText(find.byKey(ValueKey(key)), text);
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(ValueKey(key)));
    await tester.pump();
  }

  Future<void> fillSetup(
    WidgetTester tester, {
    String password = 'password-1',
    String? confirm,
    List<String> questions = const [
      'First pet?',
      'Favorite street?',
      'First school?',
    ],
    List<String> answers = const ['Rex', 'Blue House', 'SMA 1'],
  }) async {
    await enter(tester, 'passwordInput', password);
    await enter(tester, 'confirmPasswordInput', confirm ?? password);
    for (var i = 0; i < 3; i++) {
      await enter(tester, 'question${i + 1}', questions[i]);
      await enter(tester, 'answer${i + 1}', answers[i]);
    }
    await tester.pump();
  }

  Future<void> createVault(WidgetTester tester) => act(
    tester,
    () => tapKey(tester, 'createVaultButton'),
    done: () => session.phase == SessionPhase.unlocked,
  );

  Future<void> unlockWith(WidgetTester tester, String password) async {
    await enter(tester, 'unlockPasswordInput', password);
    await act(
      tester,
      () => tapKey(tester, 'unlockButton'),
      done: () => !session.isBusy,
    );
  }

  testWidgets('fresh install shows the English setup form', (tester) async {
    useTallViewport(tester);
    await load(tester);
    await pumpApp(tester);

    expect(find.text('Create your password'), findsOneWidget);
    expect(find.text('Recovery question 1'), findsOneWidget);
    expect(find.text('Recovery question 2'), findsOneWidget);
    expect(find.text('Recovery question 3'), findsOneWidget);
    expect(find.text('Recovery question 4'), findsNothing);
    // Two password fields plus exactly three question/answer pairs.
    expect(find.byType(TextFormField), findsNWidgets(8));
    expect(find.textContaining('stored unencrypted'), findsOneWidget);
    expect(find.textContaining('.encrynote'), findsOneWidget);
    expect(find.text('EnCryNote'), findsOneWidget);
  });

  testWidgets('a password needs 8 visible characters', (tester) async {
    useTallViewport(tester);
    await load(tester);
    await pumpApp(tester);

    await fillSetup(tester, password: '1234567', confirm: '1234567');
    await tapKey(tester, 'createVaultButton');

    expect(find.text('Use at least 8 characters.'), findsOneWidget);
    expect(session.phase, SessionPhase.needsSetup);
    expect(session.holdsSensitiveState, isFalse);
    expect(
      await io(tester, () => File('${dir.path}/vault.enc').exists()),
      isFalse,
    );

    await fillSetup(tester, password: '12345678', confirm: '12345678');
    await createVault(tester);
    expect(session.phase, SessionPhase.unlocked);
  });

  testWidgets('password length counts graphemes, not code units', (
    tester,
  ) async {
    useTallViewport(tester);
    await load(tester);
    await pumpApp(tester);

    const family = '👨‍👩‍👧‍👦';
    await fillSetup(tester, password: family * 7, confirm: family * 7);
    await tapKey(tester, 'createVaultButton');
    expect(find.text('Use at least 8 characters.'), findsOneWidget);
    expect(session.phase, SessionPhase.needsSetup);

    // Eight combining sequences: 16 code units, 8 graphemes.
    final combining = 'e\u0301' * 8;
    await fillSetup(tester, password: combining, confirm: combining);
    await createVault(tester);
    expect(session.phase, SessionPhase.unlocked);
  });

  testWidgets('the password confirmation must match', (tester) async {
    useTallViewport(tester);
    await load(tester);
    await pumpApp(tester);

    await fillSetup(tester, password: 'password-1', confirm: 'password-2');
    await tapKey(tester, 'createVaultButton');

    expect(find.text('The passwords do not match.'), findsOneWidget);
    expect(session.phase, SessionPhase.needsSetup);
    expect(
      await io(tester, () => File('${dir.path}/vault.enc').exists()),
      isFalse,
    );
  });

  testWidgets('all three question and answer pairs are required', (
    tester,
  ) async {
    useTallViewport(tester);
    await load(tester);
    await pumpApp(tester);

    await fillSetup(
      tester,
      questions: const ['First pet?', '', 'First school?'],
    );
    await tapKey(tester, 'createVaultButton');
    expect(find.text('Enter a question.'), findsOneWidget);
    expect(session.phase, SessionPhase.needsSetup);

    await fillSetup(tester, answers: const ['Rex', '   ', 'SMA 1']);
    await tapKey(tester, 'createVaultButton');
    expect(find.text('Enter an answer.'), findsOneWidget);
    expect(
      await io(tester, () => File('${dir.path}/vault.enc').exists()),
      isFalse,
    );

    // Free-form text is accepted; only emptiness is rejected.
    await fillSetup(
      tester,
      questions: const [
        'What did I eat in 2011?',
        'Nomor sepatu?',
        '¿Ciudad favorita?',
      ],
      answers: const ['  nasi goreng  ', '42', 'Banjarmasin'],
    );
    await createVault(tester);
    expect(session.phase, SessionPhase.unlocked);
  });

  testWidgets('setup unlocks, drops the password fields and can lock again', (
    tester,
  ) async {
    useTallViewport(tester);
    await load(tester);
    await pumpApp(tester);

    await fillSetup(tester);
    await createVault(tester);

    expect(find.byKey(const ValueKey('notesScreen')), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(find.text('password-1'), findsNothing);
    expect(find.byKey(const ValueKey('passwordInput')), findsNothing);

    await act(
      tester,
      () => tapKey(tester, 'lockNowButton'),
      done: () => session.phase == SessionPhase.locked,
    );
    expect(find.text('Unlock EnCryNote'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(
      session.holdsSensitiveState,
      isFalse,
      reason: 'the locked screen keeps no key or plaintext',
    );
    expect(find.byKey(const ValueKey('notesScreen')), findsNothing);
  });

  testWidgets('a lock during setup drops the live password fields', (
    tester,
  ) async {
    useTallViewport(tester);
    await load(tester);
    await pumpApp(tester);
    await fillSetup(tester);

    // A real lock can arrive while the setup commit is in flight.
    native.holdAt = CommitStage.fileSync;
    await io(tester, () async {
      final setup = session.setup('password-1', fixtureRecovery);
      await native.entered.future;
      await session.lock();
      native.release();
      await setup;
    });
    await tester.pumpAndSettle();

    expect(session.phase, SessionPhase.locked);
    expect(session.holdsSensitiveState, isFalse);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('passwordInput')), findsNothing);
    expect(find.text('Unlock EnCryNote'), findsOneWidget);
  });

  testWidgets('recovery can be cancelled back to unlock', (tester) async {
    useTallViewport(tester);
    await seedVault(tester);
    await load(tester);
    await pumpApp(tester);

    await tapKey(tester, 'forgotPasswordButton');
    expect(find.text('Recover your vault'), findsOneWidget);
    await tapKey(tester, 'cancelRecoveryButton');
    expect(find.text('Unlock EnCryNote'), findsOneWidget);
    expect(find.text('Recover your vault'), findsNothing);

    // The cancelled answers are gone, so recovery starts empty.
    await tapKey(tester, 'forgotPasswordButton');
    final answer = tester.widget<TextFormField>(
      find.byKey(const ValueKey('recoveryAnswer1')),
    );
    expect(answer.controller!.text, isEmpty);
    expect(session.phase, SessionPhase.locked);
  });

  testWidgets('cancelling a new password returns to the locked screen', (
    tester,
  ) async {
    useTallViewport(tester);
    await seedVault(tester);
    await load(tester);
    await pumpApp(tester);

    await tapKey(tester, 'forgotPasswordButton');
    for (var i = 0; i < 3; i++) {
      await enter(tester, 'recoveryAnswer${i + 1}', fixtureRecovery.answers[i]);
    }
    await act(
      tester,
      () => tapKey(tester, 'recoverButton'),
      done: () => session.phase == SessionPhase.recovering,
    );
    expect(find.text('Create a new password'), findsOneWidget);

    await act(
      tester,
      () => tapKey(tester, 'cancelRecoveryButton'),
      done: () => session.phase == SessionPhase.locked,
    );
    expect(find.text('Unlock EnCryNote'), findsOneWidget);
    expect(find.text('Create a new password'), findsNothing);

    await unlockWith(tester, localPassword);
    expect(session.phase, SessionPhase.unlocked);
  });

  testWidgets('a same-phase lock drops typed recovery answers', (tester) async {
    useTallViewport(tester);
    await seedVault(tester);
    await load(tester);
    await pumpApp(tester);

    await tapKey(tester, 'forgotPasswordButton');
    await enter(tester, 'recoveryAnswer1', fixtureRecovery.answers.first);
    await enter(tester, 'recoveryAnswer2', 'typed answer');
    await enter(tester, 'recoveryAnswer3', 'another answer');

    // An Immediately blur locks while the phase is already `locked`; the
    // local form must not keep the answers the user typed.
    await act(tester, () => session.lock(), done: () => !session.isBusy);
    await tester.pumpAndSettle();

    expect(session.phase, SessionPhase.locked);
    expect(find.text('Recover your vault'), findsNothing);
    expect(find.text('Unlock EnCryNote'), findsOneWidget);

    await tapKey(tester, 'forgotPasswordButton');
    for (var i = 0; i < 3; i++) {
      final field = tester.widget<TextFormField>(
        find.byKey(ValueKey('recoveryAnswer${i + 1}')),
      );
      expect(field.controller!.text, isEmpty);
    }
  });

  testWidgets('a same-phase lock drops a typed unlock password', (
    tester,
  ) async {
    useTallViewport(tester);
    await seedVault(tester);
    await load(tester);
    await pumpApp(tester);

    await enter(tester, 'unlockPasswordInput', localPassword);
    await act(tester, () => session.lock(), done: () => !session.isBusy);
    await tester.pumpAndSettle();

    final field = tester.widget<TextFormField>(
      find.byKey(const ValueKey('unlockPasswordInput')),
    );
    expect(field.controller!.text, isEmpty);
    expect(session.phase, SessionPhase.locked);
  });

  testWidgets('the leaving signal drops typed secrets without a session lock', (
    tester,
  ) async {
    useTallViewport(tester);
    await seedVault(tester);
    await load(tester);
    final activity = PrivacySignal();
    final leavings = PrivacySignal();
    addTearDown(activity.dispose);
    addTearDown(leavings.dispose);
    await tester.pumpWidget(
      PrivacySignals(
        activity: activity,
        leavings: leavings,
        child: EnCryNoteApp(session: session, transfer: transfer),
      ),
    );
    await tester.pump();

    await tapKey(tester, 'forgotPasswordButton');
    for (var i = 0; i < 3; i++) {
      await enter(tester, 'recoveryAnswer${i + 1}', 'typed answer');
    }
    final generation = session.lockGeneration;

    leavings.report();
    await tester.pump();

    expect(
      session.lockGeneration,
      generation,
      reason: 'an already-locked form has no key or write to flush',
    );
    expect(find.text('Recover your vault'), findsNothing);
    await tapKey(tester, 'forgotPasswordButton');
    for (var i = 0; i < 3; i++) {
      final field = tester.widget<TextFormField>(
        find.byKey(ValueKey('recoveryAnswer${i + 1}')),
      );
      expect(field.controller!.text, isEmpty);
    }
  });

  testWidgets('an unlocked session can open Settings', (tester) async {
    useTallViewport(tester);
    await seedVault(tester);
    await load(tester);
    await pumpApp(tester);
    await unlockWith(tester, localPassword);

    await tester.tap(find.byKey(const ValueKey('settingsButton')));
    await tester.pumpAndSettle();

    expect(find.text('Auto-lock'), findsOneWidget);
    expect(find.text('1 minute'), findsOneWidget);
    expect(find.text('Never'), findsNothing);
  });

  testWidgets('the keyboard submit unlocks and creates the vault', (
    tester,
  ) async {
    useTallViewport(tester);
    await load(tester);
    await pumpApp(tester);

    await fillSetup(tester);
    await tester.tap(find.byKey(const ValueKey('confirmPasswordInput')));
    await tester.pump();
    await act(tester, () async {
      await tester.testTextInput.receiveAction(TextInputAction.done);
    }, done: () => session.phase == SessionPhase.unlocked);
    expect(find.byKey(const ValueKey('notesScreen')), findsOneWidget);

    await act(
      tester,
      () => tapKey(tester, 'lockNowButton'),
      done: () => session.phase == SessionPhase.locked,
    );
    // The vault was created with the setup password, not the fixture one.
    await enter(tester, 'unlockPasswordInput', 'password-1');
    await tester.tap(find.byKey(const ValueKey('unlockPasswordInput')));
    await tester.pump();
    await act(tester, () async {
      await tester.testTextInput.receiveAction(TextInputAction.done);
    }, done: () => session.phase == SessionPhase.unlocked);
    expect(find.byKey(const ValueKey('notesScreen')), findsOneWidget);
  });

  testWidgets('a wrong password is rejected and offers no setup form', (
    tester,
  ) async {
    useTallViewport(tester);
    await seedVault(tester);
    await load(tester);
    await pumpApp(tester);

    expect(find.text('Create your password'), findsNothing);
    await unlockWith(tester, 'wrong-password');

    expect(find.text('That password is incorrect.'), findsOneWidget);
    expect(session.phase, SessionPhase.locked);
    expect(find.text('Create your password'), findsNothing);
    expect(find.byKey(const ValueKey('notesScreen')), findsNothing);

    await unlockWith(tester, localPassword);
    expect(session.phase, SessionPhase.unlocked);
    expect(find.byKey(const ValueKey('notesScreen')), findsOneWidget);
  });

  testWidgets('recovery sets a new password without showing notes', (
    tester,
  ) async {
    useTallViewport(tester);
    await seedVault(tester);
    await load(tester);
    await pumpApp(tester);

    await tapKey(tester, 'forgotPasswordButton');
    for (final question in fixtureRecovery.questions) {
      expect(find.text(question), findsOneWidget);
    }
    expect(find.textContaining('case-sensitive'), findsOneWidget);
    expect(find.textContaining('.encrynote'), findsOneWidget);

    for (var i = 0; i < 3; i++) {
      await enter(tester, 'recoveryAnswer${i + 1}', 'wrong');
    }
    await act(
      tester,
      () => tapKey(tester, 'recoverButton'),
      done: () => !session.isBusy,
    );
    expect(find.text('One or more answers are incorrect.'), findsOneWidget);
    expect(session.phase, SessionPhase.locked);
    expect(find.text('Create your password'), findsNothing);

    // Answers are trimmed at the edges, so surrounding spaces still verify.
    for (var i = 0; i < 3; i++) {
      await enter(
        tester,
        'recoveryAnswer${i + 1}',
        ' ${fixtureRecovery.answers[i]} ',
      );
    }
    await act(
      tester,
      () => tapKey(tester, 'recoverButton'),
      done: () => session.phase == SessionPhase.recovering,
    );

    expect(find.text('Create a new password'), findsOneWidget);
    expect(find.byKey(const ValueKey('notesScreen')), findsNothing);
    expect(find.textContaining('Fixture Markdown Body'), findsNothing);

    await enter(tester, 'newPasswordInput', newPassword);
    await enter(tester, 'newConfirmPasswordInput', newPassword);
    await act(
      tester,
      () => tapKey(tester, 'setPasswordButton'),
      done: () => session.phase == SessionPhase.unlocked,
    );
    expect(find.byKey(const ValueKey('notesScreen')), findsOneWidget);

    // The old password no longer opens the vault; the new one does.
    await act(
      tester,
      () => tapKey(tester, 'lockNowButton'),
      done: () => session.phase == SessionPhase.locked,
    );
    await unlockWith(tester, localPassword);
    expect(find.text('That password is incorrect.'), findsOneWidget);
    await unlockWith(tester, newPassword);
    expect(session.phase, SessionPhase.unlocked);
  });

  testWidgets('a failed setup save keeps the form filled and retryable', (
    tester,
  ) async {
    useTallViewport(tester);
    await load(tester);
    await pumpApp(tester);

    await fillSetup(tester);
    native.failAt = CommitStage.replace;
    await act(
      tester,
      () => tapKey(tester, 'createVaultButton'),
      done: () => !session.isBusy && session.failure != null,
    );

    expect(session.phase, SessionPhase.needsSetup);
    expect(
      find.text(
        'EnCryNote could not save the new vault. '
        'Nothing was changed; try again.',
      ),
      findsOneWidget,
    );
    // Password and confirmation both keep their text after the failure.
    expect(find.text('password-1'), findsNWidgets(2));
    expect(find.text('Blue House'), findsOneWidget);
    expect(find.byKey(const ValueKey('notesScreen')), findsNothing);

    await createVault(tester);
    expect(session.phase, SessionPhase.unlocked);
    expect(
      await io(tester, () => File('${dir.path}/vault.enc').exists()),
      isTrue,
    );
  });

  testWidgets('a corrupt vault shows an error and recovers on retry', (
    tester,
  ) async {
    useTallViewport(tester);
    await io(
      tester,
      () => File('${dir.path}/vault.enc').writeAsString('not a vault'),
    );
    await io(
      tester,
      () => expectLater(session.load(), throwsA(isA<VaultException>())),
    );
    await pumpApp(tester);

    expect(find.text('Your vault could not be opened'), findsOneWidget);
    expect(
      find.text('The vault file is damaged or is not an EnCryNote vault.'),
      findsOneWidget,
    );
    expect(find.text('Create your password'), findsNothing);
    expect(find.byKey(const ValueKey('notesScreen')), findsNothing);

    await seedVault(tester);
    await act(
      tester,
      () => tapKey(tester, 'retryButton'),
      done: () => session.phase == SessionPhase.locked,
    );

    expect(find.text('Unlock EnCryNote'), findsOneWidget);
    expect(session.recoveryQuestions, fixtureRecovery.questions);
  });

  testWidgets('a retry that still fails stays on the error screen', (
    tester,
  ) async {
    useTallViewport(tester);
    await io(
      tester,
      () => File('${dir.path}/vault.enc').writeAsString('not a vault'),
    );
    await io(
      tester,
      () => expectLater(session.load(), throwsA(isA<VaultException>())),
    );
    await pumpApp(tester);

    await act(
      tester,
      () => tapKey(tester, 'retryButton'),
      done: () => !session.isBusy,
    );

    expect(find.text('Your vault could not be opened'), findsOneWidget);
    expect(
      find.text('That did not work. Nothing was changed; try again.'),
      findsOneWidget,
    );
    expect(find.text('Create your password'), findsNothing);
    expect(find.byKey(const ValueKey('notesScreen')), findsNothing);
  });

  testWidgets('a failed save offers a save retry, not a reload', (
    tester,
  ) async {
    useTallViewport(tester);
    await seedVault(tester);
    await load(tester);
    await pumpApp(tester);
    await unlockWith(tester, localPassword);
    expect(session.phase, SessionPhase.unlocked);

    final edited = fixtureData.notes.single.copyWith(markdown: 'edited body');
    await io(tester, () async {
      // The real commit and its debounce timer only progress in the real zone.
      native.failAt = CommitStage.backup;
      await expectLater(
        session.saveNote(edited),
        throwsA(isA<VaultException>()),
      );
    });
    await tester.pump();

    expect(session.phase, SessionPhase.storageError);
    expect(find.text('Your last change is not saved yet'), findsOneWidget);
    expect(find.byKey(const ValueKey('notesScreen')), findsNothing);
    expect(find.textContaining('edited body'), findsNothing);

    await act(
      tester,
      () => tapKey(tester, 'retryButton'),
      done: () => session.phase == SessionPhase.unlocked,
    );
    expect(find.byKey(const ValueKey('notesScreen')), findsOneWidget);
    expect(session.data!.notes.single.markdown, 'edited body');
  });

  testWidgets('loading shows progress before the vault opens', (tester) async {
    useTallViewport(tester);
    await pumpApp(tester);

    expect(find.text('Opening your vault...'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Create your password'), findsNothing);

    await load(tester);
    await tester.pump();
    expect(find.text('Create your password'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('English labels remain on an unsupported OS locale', (
    tester,
  ) async {
    useTallViewport(tester);
    tester.platformDispatcher.localesTestValue = const [Locale('id', 'ID')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);

    await load(tester);
    await pumpApp(tester);

    expect(find.text('Create your password'), findsOneWidget);
    expect(find.text('Recovery question 1'), findsOneWidget);
    expect(find.text('Buat kata sandi'), findsNothing);
  });

  testWidgets('theme follows the OS light and dark setting', (tester) async {
    useTallViewport(tester);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

    await load(tester);
    await pumpApp(tester);

    expect(
      Theme.of(tester.element(find.text('Create your password'))).brightness,
      Brightness.dark,
    );

    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.text('Create your password'))).brightness,
      Brightness.light,
    );
  });

  testWidgets('a narrow screen with the keyboard open does not overflow', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(360, 640);
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.reset);

    await load(tester);
    await pumpApp(tester);
    expect(tester.takeException(), isNull);

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('createVaultButton')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey('createVaultButton')));
    await tester.pump();
    expect(find.text('Use at least 8 characters.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
