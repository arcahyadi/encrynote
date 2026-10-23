import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hello_flutter/l10n/generated/app_localizations.dart';
import 'package:hello_flutter/session/note_session.dart';
import 'package:hello_flutter/settings/privacy_policy_screen.dart';
import 'package:hello_flutter/settings/settings_screen.dart';
import 'package:hello_flutter/vault/vault_crypto.dart';
import 'package:hello_flutter/vault/vault_store.dart';
import 'package:hello_flutter/vault/vault_types.dart';

import '../support/fake_native_bridge.dart';
import '../support/fixtures.dart';

/// Settings shows exactly the four approved auto-lock choices.
void main() {
  final crypto = VaultCrypto();
  late Uint8List seed;
  late Directory scratchRoot;
  late Directory dir;
  late NoteSession session;
  late FakeNativeBridge native;
  var scratch = 0;

  setUpAll(() async {
    seed = (await crypto.createVault(
      localPassword,
      fixtureRecovery,
      fixtureData,
    )).envelope;
    scratchRoot = await Directory(
      '${Directory.current.path}/.dart_tool/test_scratch/settings_screen/'
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
  });

  tearDown(() {
    session.dispose();
  });

  Future<T> io<T>(WidgetTester tester, Future<T> Function() body) async {
    final value = await tester.runAsync(body);
    return value as T;
  }

  Future<void> openUnlocked(WidgetTester tester) async {
    await io(tester, () async {
      await File('${dir.path}/vault.enc').writeAsBytes(seed);
      await session.load();
      await session.unlock(localPassword);
    });
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SettingsScreen(session: session),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('offers exactly the four approved choices, default 1 minute', (
    tester,
  ) async {
    await openUnlocked(tester);

    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Auto-lock'), findsOneWidget);
    expect(find.text('Never'), findsNothing);
    // Exactly the four approved labels, in order, with no fifth choice.
    const labels = ['Immediately', '1 minute', '5 minutes', '10 minutes'];
    final options = tester
        .widgetList<RadioListTile<AutoLockMode>>(
          find.byType(RadioListTile<AutoLockMode>),
        )
        .toList();
    expect(options, hasLength(4));
    expect([for (final tile in options) (tile.title! as Text).data], labels);
    for (var i = 1; i < labels.length; i++) {
      expect(
        tester.getTopLeft(find.text(labels[i])).dy,
        greaterThan(tester.getTopLeft(find.text(labels[i - 1])).dy),
      );
    }

    final group = tester.widget<RadioGroup<AutoLockMode>>(
      find.byType(RadioGroup<AutoLockMode>),
    );
    expect(group.groupValue, AutoLockMode.oneMinute);
    expect(session.autoLock, AutoLockMode.oneMinute);
  });

  testWidgets('choosing a mode saves it on the session', (tester) async {
    await openUnlocked(tester);

    await tester.tap(find.text('10 minutes'));
    await tester.pumpAndSettle();

    expect(session.autoLock, AutoLockMode.tenMinutes);
    expect(
      tester
          .widget<RadioGroup<AutoLockMode>>(
            find.byType(RadioGroup<AutoLockMode>),
          )
          .groupValue,
      AutoLockMode.tenMinutes,
    );
  });

  testWidgets('a frozen save error makes the policy read-only', (tester) async {
    await openUnlocked(tester);

    await io(tester, () async {
      native.failNextCommit = true;
      await expectLater(
        session.saveNote(
          session.data!.notes.single.copyWith(markdown: 'frozen draft'),
        ),
        throwsA(isA<VaultException>()),
      );
    });
    await tester.pumpAndSettle();

    expect(session.phase, SessionPhase.storageError);
    expect(session.canMutate, isFalse);
    expect(
      find.text(
        'A change is not saved yet. Auto-lock stays read-only until the save '
        'succeeds.',
      ),
      findsOne,
    );

    await tester.tap(find.text('5 minutes'));
    await tester.pumpAndSettle();

    expect(session.autoLock, AutoLockMode.oneMinute);
    expect(find.textContaining('frozen draft'), findsNothing);
  });

  testWidgets('a failed policy save does not claim nothing changed', (
    tester,
  ) async {
    await openUnlocked(tester);

    native.failNextCommit = true;
    await io(tester, () async {
      // The debounce timer and the real commit only progress in the real zone.
      final save = session.setAutoLock(AutoLockMode.tenMinutes);
      await Future<void>.delayed(NoteSession.autosaveDebounce);
      await expectLater(save, throwsA(isA<VaultException>()));
    });
    await tester.pumpAndSettle();

    expect(session.autoLock, AutoLockMode.tenMinutes);
    expect(session.phase, SessionPhase.storageError);
    expect(
      find.textContaining('Nothing was changed'),
      findsNothing,
      reason: 'the new policy is already enforced in memory',
    );
    expect(
      find.text(
        'A change is not saved yet. Auto-lock stays read-only until the save '
        'succeeds.',
      ),
      findsOne,
    );
  });

  testWidgets('a locked session cannot change the saved policy', (
    tester,
  ) async {
    await io(tester, () async {
      await File('${dir.path}/vault.enc').writeAsBytes(seed);
      await session.load();
    });
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SettingsScreen(session: session),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('5 minutes'));
    await tester.pumpAndSettle();

    expect(session.autoLock, AutoLockMode.oneMinute);
    expect(find.text('Your vault is locked. Unlock to change this.'), findsOne);
  });

  testWidgets('the settings screen can open the bundled licence page', (
    tester,
  ) async {
    await openUnlocked(tester);

    await tester.tap(find.byKey(const ValueKey('licensesButton')));
    await tester.pumpAndSettle();

    // This only proves the route and page render. The text itself comes from
    // the NOTICES asset at runtime, which this widget test cannot read (the
    // test binding registers no licences); the flow test's asset check is the
    // real proof that third-party text ships.
    expect(find.text('Licenses'), findsOneWidget);
    expect(find.byType(LicensePage), findsOneWidget);
    expect(find.text('EnCryNote'), findsWidgets);
  });

  testWidgets('the privacy policy opens from settings and renders its text', (
    tester,
  ) async {
    await openUnlocked(tester);

    await tester.tap(find.byKey(const ValueKey('privacyPolicyButton')));
    await tester.pumpAndSettle();

    expect(find.byType(PrivacyPolicyScreen), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(PrivacyPolicyScreen),
        matching: find.text('Privacy policy'),
      ),
      findsOneWidget,
    );
    // The whole policy is one local string, so no route or asset can fail.
    expect(find.textContaining('Argon2id'), findsOneWidget);
    expect(find.textContaining('stikes.isfi@gmail.com'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(PrivacyPolicyScreen),
        matching: find.byType(Scrollable),
      ),
      findsOneWidget,
      reason: 'the policy must scroll on a phone',
    );
  });

  testWidgets('a lock closes the licence page and Settings down to the auth '
      'surface', (tester) async {
    await io(tester, () async {
      await File('${dir.path}/vault.enc').writeAsBytes(seed);
      await session.load();
      await session.unlock(localPassword);
    });

    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: Center(child: Text('auth surface'))),
        routes: {
          SettingsScreen.routeName: (_) => SettingsScreen(session: session),
        },
      ),
    );
    await tester.pumpAndSettle();

    navigator.currentState!.pushNamed(SettingsScreen.routeName);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('licensesButton')));
    await tester.pumpAndSettle();
    expect(find.byType(LicensePage), findsOneWidget);

    await io(tester, () => session.lock());
    await tester.pumpAndSettle();

    expect(find.byType(LicensePage), findsNothing);
    expect(
      find.text('Settings'),
      findsNothing,
      reason: 'Settings must not sit above the unlock surface',
    );
    expect(find.text('auth surface'), findsOneWidget);
  });
}
