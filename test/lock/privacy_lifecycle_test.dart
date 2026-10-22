import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hello_flutter/app.dart';
import 'package:hello_flutter/platform/native_bridge.dart';
import 'package:hello_flutter/platform/privacy_lifecycle.dart';
import 'package:hello_flutter/session/note_session.dart';
import 'package:hello_flutter/vault/vault_crypto.dart';
import 'package:hello_flutter/vault/vault_store.dart';
import 'package:hello_flutter/vault/vault_types.dart';

import '../support/fake_native_bridge.dart';
import '../support/fixtures.dart';

/// Native focus, Flutter lifecycle and the privacy shield around the app.
///
/// Real key derivation and file IO run through [io]; everything that is only
/// widget state runs in the fake-async zone.
void main() {
  final crypto = VaultCrypto();
  late Uint8List seed;
  late Directory scratchRoot;
  late Directory dir;
  late FakeNativeBridge native;
  late NoteSession session;
  // Controllable clocks: pumping fake time alone does not move the real clock
  // the lifecycle would otherwise use.
  late DateTime now;
  late Duration elapsed;
  var scratch = 0;

  setUpAll(() async {
    seed = (await crypto.createVault(
      localPassword,
      fixtureRecovery,
      fixtureData,
    )).envelope;
    scratchRoot = await Directory(
      '${Directory.current.path}/.dart_tool/test_scratch/privacy_lifecycle/'
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
    now = DateTime.utc(2026, 10, 22, 12);
    elapsed = Duration.zero;
    native = FakeNativeBridge();
    session = NoteSession(
      crypto: crypto,
      store: VaultStore(directory: dir, native: native),
    );
  });

  tearDown(() {
    session.dispose();
  });

  Future<T> io<T>(WidgetTester tester, Future<T> Function() body) async {
    final value = await tester.runAsync(body);
    return value as T;
  }

  Future<void> loadLocked(WidgetTester tester) async {
    await io(tester, () async {
      await File('${dir.path}/vault.enc').writeAsBytes(seed);
      await session.load();
    });
  }

  Future<void> unlock(WidgetTester tester) async {
    await loadLocked(tester);
    await io(tester, () => session.unlock(localPassword));
    expect(session.phase, SessionPhase.unlocked);
  }

  /// Delivers a native focus event in the real zone so a lock's file IO can
  /// finish, then paints the result.
  /// Emits a native focus event from the widget zone, then alternates real IO
  /// turns with fake-zone pumps until [done] or the frame budget runs out.
  Future<void> settle(WidgetTester tester, {bool Function()? done}) async {
    for (var i = 0; i < 200; i++) {
      if (done != null && done()) break;
      await tester.pump(const Duration(milliseconds: 10));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2)),
      );
    }
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> blur(WidgetTester tester, {bool Function()? done}) async {
    native.emitFocus(false);
    await settle(tester, done: done);
  }

  Future<void> refocus(WidgetTester tester) async {
    native.emitFocus(true);
    await settle(tester);
  }

  /// Moves both injected clocks and lets the armed timer fire.
  Future<void> tick(WidgetTester tester, Duration duration) async {
    now = now.add(duration);
    elapsed += duration;
    await tester.pump(duration);
  }

  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(800, 1200);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      PrivacyLifecycle(
        session: session,
        native: native,
        now: () => now,
        elapsed: () => elapsed,
        child: EnCryNoteApp(session: session),
      ),
    );
    await tester.pump();
  }

  testWidgets(
    'immediately locks on focus loss and shields until a safe frame',
    (tester) async {
      await unlock(tester);
      await io(tester, () => session.setAutoLock(AutoLockMode.immediately));
      await pumpApp(tester);
      expect(find.text('Your vault is unlocked'), findsOneWidget);

      await blur(tester);
      expect(native.shieldVisible, isTrue);
      expect(session.phase, SessionPhase.locked);
      expect(find.text('Your vault is unlocked'), findsNothing);

      await refocus(tester);
      expect(native.shieldVisible, isFalse);
      expect(find.text('Unlock EnCryNote'), findsOneWidget);
      expect(native.events, [
        'shield:true',
        'shield:false',
      ], reason: 'the shield is installed and only removed after the lock');
      expect(find.text('Your vault is unlocked'), findsNothing);
    },
  );

  testWidgets('foreground inactivity locks at the armed deadline', (
    tester,
  ) async {
    await unlock(tester);
    await pumpApp(tester);

    // No blur and no input: only the armed timer can enforce this.
    await tick(tester, const Duration(seconds: 59));
    expect(session.phase, SessionPhase.unlocked);

    await tick(tester, const Duration(seconds: 1));
    await settle(tester, done: () => session.phase == SessionPhase.locked);

    expect(session.phase, SessionPhase.locked);
    expect(session.data, isNull);
    expect(native.shieldVisible, isFalse);
    expect(find.text('Unlock EnCryNote'), findsOneWidget);
  });

  testWidgets('typed activity restarts the armed deadline', (tester) async {
    await unlock(tester);
    await io(tester, () async {
      await session.lock();
      await session.beginRecovery(fixtureRecovery.answers);
    });
    await pumpApp(tester);

    await tick(tester, const Duration(seconds: 40));
    await tester.enterText(find.byKey(const ValueKey('newPasswordInput')), 'x');
    await tester.pump();
    await tick(tester, const Duration(seconds: 40));
    expect(
      session.phase,
      SessionPhase.recovering,
      reason: 'typing 40s in restarts the 1-minute window',
    );

    await tick(tester, const Duration(seconds: 20));
    await settle(tester, done: () => session.phase == SessionPhase.locked);
    expect(session.phase, SessionPhase.locked);
  });

  testWidgets('a timed mode keeps the session through a short blur', (
    tester,
  ) async {
    await unlock(tester);
    await pumpApp(tester);

    native.emitFocus(false);
    await tester.pump();
    expect(native.shieldVisible, isTrue);
    expect(session.phase, SessionPhase.unlocked);

    await refocus(tester);
    expect(native.shieldVisible, isFalse);
    expect(session.phase, SessionPhase.unlocked);
    expect(find.text('Your vault is unlocked'), findsOneWidget);
  });

  testWidgets('the Flutter lifecycle alone shields and locks', (tester) async {
    await unlock(tester);
    await io(tester, () => session.setAutoLock(AutoLockMode.immediately));
    await pumpApp(tester);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    await tester.pump();
    expect(native.shieldVisible, isTrue);
    expect(session.phase, SessionPhase.locked);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(native.shieldVisible, isFalse);
    expect(find.text('Unlock EnCryNote'), findsOneWidget);
  });

  testWidgets('a frozen save error still locks on focus loss', (tester) async {
    await unlock(tester);
    await io(tester, () async {
      await session.setAutoLock(AutoLockMode.immediately);
      native.failNextCommit = true;
      await expectLater(
        session.saveNote(
          session.data!.notes.single.copyWith(markdown: 'frozen draft'),
        ),
        throwsA(isA<VaultException>()),
      );
    });
    await pumpApp(tester);
    expect(session.phase, SessionPhase.storageError);
    expect(session.holdsSensitiveState, isTrue);
    expect(find.textContaining('frozen draft'), findsNothing);

    await blur(tester, done: () => !session.holdsSensitiveState);

    expect(session.phase, SessionPhase.locked);
    expect(session.holdsSensitiveState, isFalse);
    expect(session.data, isNull);
  });

  testWidgets('recovery locks with the saved policy without note access', (
    tester,
  ) async {
    await unlock(tester);
    await io(tester, () => session.setAutoLock(AutoLockMode.immediately));
    await io(tester, () async {
      await session.lock();
      await session.beginRecovery(fixtureRecovery.answers);
    });
    expect(session.phase, SessionPhase.recovering);
    expect(session.data, isNull);
    expect(session.autoLock, AutoLockMode.immediately);

    await pumpApp(tester);
    expect(find.text('Create a new password'), findsOneWidget);

    await blur(tester);

    expect(session.phase, SessionPhase.locked);
    expect(session.data, isNull);
    expect(find.text('Create a new password'), findsNothing);
    expect(find.text('Unlock EnCryNote'), findsOneWidget);
  });

  testWidgets('an Immediately blur drops typed secrets on a locked form', (
    tester,
  ) async {
    await unlock(tester);
    await io(tester, () => session.setAutoLock(AutoLockMode.immediately));
    await io(tester, session.lock);
    await pumpApp(tester);
    expect(find.text('Unlock EnCryNote'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('unlockPasswordInput')),
      localPassword,
    );
    await tester.pump();

    await blur(tester);
    await refocus(tester);

    expect(session.phase, SessionPhase.locked);
    final field = tester.widget<TextFormField>(
      find.byKey(const ValueKey('unlockPasswordInput')),
    );
    expect(
      field.controller!.text,
      isEmpty,
      reason: 'a one-tap unlock after leaving must not be possible',
    );
  });

  testWidgets('an Immediately blur drops typed recovery answers', (
    tester,
  ) async {
    await unlock(tester);
    await io(tester, () => session.setAutoLock(AutoLockMode.immediately));
    await io(tester, session.lock);
    await pumpApp(tester);

    await tester.tap(find.byKey(const ValueKey('forgotPasswordButton')));
    await tester.pump();
    for (var i = 0; i < 3; i++) {
      await tester.enterText(
        find.byKey(ValueKey('recoveryAnswer${i + 1}')),
        fixtureRecovery.answers[i],
      );
    }
    await tester.pump();

    await blur(tester);
    await refocus(tester);

    expect(session.phase, SessionPhase.locked);
    expect(find.text('Recover your vault'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('forgotPasswordButton')));
    await tester.pump();
    for (var i = 0; i < 3; i++) {
      final field = tester.widget<TextFormField>(
        find.byKey(ValueKey('recoveryAnswer${i + 1}')),
      );
      expect(field.controller!.text, isEmpty);
    }
  });

  testWidgets('a leaving on a setup form drops typed secrets', (tester) async {
    await io(tester, session.load);
    await pumpApp(tester);
    expect(find.text('Create your password'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('passwordInput')),
      'typed-secret-1',
    );
    await tester.pump();

    await blur(tester);
    await refocus(tester);

    final field = tester.widget<TextFormField>(
      find.byKey(const ValueKey('passwordInput')),
    );
    expect(
      field.controller!.text,
      isEmpty,
      reason: 'setup has no saved policy and cold start is always locked',
    );
  });

  testWidgets('a timed mode keeps typed secrets on a locked form', (
    tester,
  ) async {
    await loadLocked(tester);
    await pumpApp(tester);

    await tester.enterText(
      find.byKey(const ValueKey('unlockPasswordInput')),
      'typed-secret-1',
    );
    await tester.pump();

    await blur(tester);
    await refocus(tester);

    final field = tester.widget<TextFormField>(
      find.byKey(const ValueKey('unlockPasswordInput')),
    );
    expect(
      field.controller!.text,
      'typed-secret-1',
      reason: 'a timed mode is not an Immediately leaving',
    );
  });

  testWidgets('a locked session does not re-run the lock pipeline', (
    tester,
  ) async {
    await loadLocked(tester);
    await pumpApp(tester);
    final generation = session.lockGeneration;

    await blur(tester);
    expect(
      session.lockGeneration,
      generation,
      reason: 'a session with nothing to flush has no lock work to repeat',
    );

    await refocus(tester);
    expect(native.shieldVisible, isFalse);
    expect(session.phase, SessionPhase.locked);
  });

  testWidgets('soft-keyboard typing holds a keyed form open', (tester) async {
    await unlock(tester);
    await io(tester, () async {
      await session.lock();
      await session.beginRecovery(fixtureRecovery.answers);
    });
    expect(session.phase, SessionPhase.recovering);
    await pumpApp(tester);
    expect(find.text('Create a new password'), findsOneWidget);

    // One tap focuses the field; everything after arrives as IME input on the
    // text-input channel, which no pointer or HardwareKeyboard handler sees.
    await tester.tap(find.byKey(const ValueKey('newPasswordInput')));
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      tester.testTextInput.enterText('new-password-$i');
      await tick(tester, const Duration(seconds: 11));
    }

    expect(
      session.phase,
      SessionPhase.recovering,
      reason: '60+ seconds of typing is user activity, not inactivity',
    );
    expect(session.holdsSensitiveState, isTrue);
    expect(native.shieldVisible, isFalse);
    expect(find.text('Create a new password'), findsOneWidget);
  });

  testWidgets('a blur during the resume checks cannot leave the cover up', (
    tester,
  ) async {
    await unlock(tester);
    await pumpApp(tester);

    native.emitFocus(false);
    native.emitFocus(true);
    // A second blur/focus pair arrives before the first checks finish.
    native.emitFocus(false);
    native.emitFocus(true);
    await settle(tester);

    expect(native.shieldVisible, isFalse);
    expect(session.phase, SessionPhase.unlocked);
    expect(find.text('Your vault is unlocked'), findsOneWidget);
  });

  testWidgets('a native shield failure hides the notes by locking', (
    tester,
  ) async {
    await unlock(tester);
    await pumpApp(tester);
    native.failShield = true;

    await blur(tester, done: () => session.phase == SessionPhase.locked);

    expect(session.phase, SessionPhase.locked);
    expect(session.data, isNull);
    expect(find.text('Unlock EnCryNote'), findsOneWidget);
  });

  testWidgets('a stale cover from a previous isolate is cleared at startup', (
    tester,
  ) async {
    await unlock(tester);
    // The previous isolate shielded, then restarted while the app was in front.
    await io(tester, () => native.setPrivacyShield(true));
    final before = native.shieldCalls;
    await pumpApp(tester);

    expect(native.shieldCalls, greaterThan(before));
    expect(native.shieldVisible, isFalse);
    expect(session.phase, SessionPhase.unlocked);
  });

  testWidgets('a focus gain clears a shield this widget did not set', (
    tester,
  ) async {
    await unlock(tester);
    await pumpApp(tester);
    // Native covered the window before Flutter started listening.
    await io(tester, () => native.setPrivacyShield(true));
    expect(native.shieldVisible, isTrue);

    await refocus(tester);

    expect(native.shieldVisible, isFalse);
    expect(session.phase, SessionPhase.unlocked);
    expect(find.text('Your vault is unlocked'), findsOneWidget);
  });

  testWidgets('an unlock finishing while away locks again at once', (
    tester,
  ) async {
    await unlock(tester);
    await io(tester, () => session.setAutoLock(AutoLockMode.immediately));
    await pumpApp(tester);

    await blur(tester, done: () => session.phase == SessionPhase.locked);
    expect(session.phase, SessionPhase.locked);

    // The password arrived from a hardware keyboard after the blur.
    await io(tester, () => session.unlock(localPassword));
    await settle(tester, done: () => session.phase == SessionPhase.locked);

    expect(session.phase, SessionPhase.locked);
    expect(session.data, isNull);
    expect(native.shieldVisible, isTrue);
    expect(find.text('Your vault is unlocked'), findsNothing);
  });

  testWidgets('a resume during an in-flight Immediately lock shows no notes', (
    tester,
  ) async {
    await unlock(tester);
    await io(tester, () => session.setAutoLock(AutoLockMode.immediately));
    await pumpApp(tester);

    // Blur and return in the same frame: the lock's flush is still running.
    native.emitFocus(false);
    native.emitFocus(true);
    await settle(tester, done: () => native.shieldVisible == false);

    expect(session.phase, SessionPhase.locked);
    expect(native.shieldVisible, isFalse);
    expect(find.text('Your vault is unlocked'), findsNothing);
    expect(find.textContaining('Fixture Markdown Body'), findsNothing);
    expect(find.text('Unlock EnCryNote'), findsOneWidget);
  });

  testWidgets('a late focus event cannot lower a newer shield', (tester) async {
    await unlock(tester);
    await io(tester, () => session.setAutoLock(AutoLockMode.immediately));
    await pumpApp(tester);

    native.emitFocus(false);
    native.emitFocus(true);
    native.emitFocus(false);
    await settle(tester);

    expect(native.shieldVisible, isTrue);
    expect(session.phase, SessionPhase.locked);
    expect(find.text('Your vault is unlocked'), findsNothing);

    await refocus(tester);
    expect(native.shieldVisible, isFalse);
    expect(find.text('Unlock EnCryNote'), findsOneWidget);
  });

  testWidgets('a resume that never paints leaves the cover up, not stuck', (
    tester,
  ) async {
    await unlock(tester);
    await pumpApp(tester);

    // Minimized/occluded: the engine stops producing frames, so the resume
    // cannot get a painted frame. It must give up and keep the cover.
    await tester.binding.setSurfaceSize(const Size(1, 1));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    tester.binding.scheduleFrame();
    native.emitFocus(false);
    await tester.pump();
    native.emitFocus(true);
    await tester.pump(
      PrivacyLifecycle.frameWait + const Duration(milliseconds: 1),
    );

    expect(native.shieldVisible, isTrue);

    // Frames resume: the next focus gain can uncover normally.
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    await refocus(tester);
    expect(native.shieldVisible, isFalse);
  });

  testWidgets('a non-VaultException shield error does not poison the queue', (
    tester,
  ) async {
    await unlock(tester);
    await pumpApp(tester);

    native.throwRawOnShield = true;
    await blur(tester);
    await refocus(tester);
    // A later hide must still reach the bridge after that failure.
    native.throwRawOnShield = false;
    await refocus(tester);
    await settle(tester);

    expect(session.phase, SessionPhase.locked);
    expect(
      native.shieldCalls,
      greaterThan(2),
      reason: 'the queue kept accepting calls after the failure',
    );
  });

  testWidgets('the bridge maps the shield call and focus stream', (
    tester,
  ) async {
    const method = MethodChannel('encrynote/platform');
    const focus = EventChannel('encrynote/focus');
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(method, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(method, null));

    final received = <bool>[];
    messenger.setMockStreamHandler(
      focus,
      MockStreamHandler.inline(
        onListen: (arguments, events) => events.success(true),
      ),
    );
    addTearDown(() => messenger.setMockStreamHandler(focus, null));

    const bridge = MethodChannelNativeBridge();
    await bridge.setPrivacyShield(true);
    await bridge.setPrivacyShield(false);
    await bridge.focusChanges.first.then(received.add);

    expect(calls.map((call) => call.method), [
      'setPrivacyShield',
      'setPrivacyShield',
    ]);
    expect(calls.map((call) => call.arguments), [true, false]);
    expect(received, [true]);
  });

  testWidgets('pointer and key activity never locks a focused session', (
    tester,
  ) async {
    await unlock(tester);
    await io(tester, () => session.setAutoLock(AutoLockMode.immediately));
    await pumpApp(tester);

    await tester.tap(find.text('Your vault is unlocked'));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.pump();

    expect(session.phase, SessionPhase.unlocked);
    expect(native.shieldVisible, isFalse);
  });
}
