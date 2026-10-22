import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hello_flutter/app.dart';
import 'package:hello_flutter/lock/privacy_signals.dart';
import 'package:hello_flutter/l10n/generated/app_localizations.dart';
import 'package:hello_flutter/notes/notes_screen.dart';
import 'package:hello_flutter/session/note_session.dart';
import 'package:hello_flutter/transfer/transfer_service.dart';
import 'package:hello_flutter/vault/vault_crypto.dart';
import 'package:hello_flutter/vault/vault_store.dart';
import 'package:hello_flutter/vault/vault_types.dart';

import '../support/fake_native_bridge.dart';
import '../support/fixtures.dart';
import '../support/seal_failure_crypto.dart';

/// The real notes surface: list, CRUD, autosave, layout and lock behaviour.
///
/// Crypto and file IO run through [io]; only widget state runs in the fake
/// async zone. Every test that types settles the session debounce and commit so
/// no timer or isolate outlives the test.
void main() {
  final crypto = VaultCrypto();
  late Uint8List seed;
  late Uint8List emptySeed;
  late Directory scratchRoot;
  late Directory dir;
  late FakeNativeBridge native;
  late NoteSession session;
  late TransferService transfer;
  late SealFailureCrypto sealCrypto;
  late NoteSession sealSession;
  late TransferService sealTransfer;
  var scratch = 0;

  setUpAll(() async {
    seed = (await crypto.createVault(
      localPassword,
      fixtureRecovery,
      fixtureData,
    )).envelope;
    emptySeed = (await crypto.createVault(
      localPassword,
      fixtureRecovery,
      VaultData(notes: const []),
    )).envelope;
    scratchRoot = await Directory(
      '${Directory.current.path}/.dart_tool/test_scratch/notes_screen/'
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
    // Built here so its store queue lives in the real zone.
    sealCrypto = SealFailureCrypto();
    sealSession = NoteSession(
      crypto: sealCrypto,
      store: VaultStore(directory: dir, native: native),
    );
    transfer = TransferService(
      session: session,
      crypto: crypto,
      native: native,
    );
    sealTransfer = TransferService(
      session: sealSession,
      crypto: sealCrypto,
      native: native,
    );
  });

  tearDown(() {
    session.dispose();
    sealSession.dispose();
    transfer.dispose();
    sealTransfer.dispose();
  });

  Future<T> io<T>(WidgetTester tester, Future<T> Function() body) async {
    final value = await tester.runAsync(body);
    return value as T;
  }

  Future<void> openVault(WidgetTester tester, {bool empty = false}) async {
    await io(tester, () async {
      await File('${dir.path}/vault.enc')
          .writeAsBytes(empty ? emptySeed : seed);
      await session.load();
      await session.unlock(localPassword);
    });
    expect(session.phase, SessionPhase.unlocked);
  }

  Future<void> openSealVault(WidgetTester tester) async {
    await io(tester, () async {
      await File('${dir.path}/vault.enc').writeAsBytes(seed);
      await sealSession.load();
      await sealSession.unlock(localPassword);
    });
    expect(sealSession.phase, SessionPhase.unlocked);
  }

  void useSize(WidgetTester tester, Size size) {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
  }

  Future<void> pumpNotes(
    WidgetTester tester, {
    Size size = const Size(800, 1200),
    double textScale = 1,
    Brightness brightness = Brightness.light,
  }) async {
    useSize(tester, size);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.deepPurple,
            brightness: brightness,
          ),
        ),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: NotesScreen(session: session, transfer: transfer),
      ),
    );
    await tester.pump();
  }

  Future<void> pumpApp(
    WidgetTester tester, {
    Size size = const Size(800, 1200),
  }) async {
    useSize(tester, size);
    await tester.pumpWidget(EnCryNoteApp(session: session, transfer: transfer));
    await tester.pump();
  }

  /// Fires the session debounce, then lets the real seal and commit land.
  Future<void> settleSave(WidgetTester tester, {int? commits}) async {
    final before = commits ?? native.commitCount;
    await tester.pump(
      NoteSession.autosaveDebounce + const Duration(milliseconds: 1),
    );
    for (var i = 0; i < 200; i++) {
      if (native.commitCount > before) break;
      await io(
        tester,
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    for (var i = 0; i < 10; i++) {
      await io(
        tester,
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
  }

  Note noteTitled(String title) =>
      session.data!.notes.firstWhere((note) => note.title == title);

  Future<void> createNote(
    WidgetTester tester,
    String title,
    String body,
  ) async {
    await tester.tap(find.byKey(const ValueKey('newNoteButton')));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('titleInput')), title);
    await tester.enterText(find.byKey(const ValueKey('markdownInput')), body);
    await tester.pump();
    await settleSave(tester);
  }

  Future<void> openFixtureNote(WidgetTester tester) async {
    await tester.tap(
      find.byKey(ValueKey('noteTile:${fixtureData.notes.single.id}')),
    );
    await tester.pump();
  }

  testWidgets('creating notes lists the newest update first', (tester) async {
    await openVault(tester, empty: true);
    await pumpNotes(tester);

    expect(find.text('No notes yet'), findsOneWidget);
    expect(find.text('Create your first note with New note.'), findsOneWidget);

    await createNote(tester, 'First note', 'First body');
    await tester.pump(const Duration(milliseconds: 2));
    await createNote(tester, 'Second note', 'Second body');

    expect(session.data!.notes, hasLength(2));
    expect(
      find.byKey(ValueKey('noteTile:${noteTitled('First note').id}')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey('noteTile:${noteTitled('Second note').id}')),
      findsOneWidget,
    );
    final secondTop = tester
        .getTopLeft(
          find.byKey(ValueKey('noteTile:${noteTitled('Second note').id}')),
        )
        .dy;
    final firstTop = tester
        .getTopLeft(
          find.byKey(ValueKey('noteTile:${noteTitled('First note').id}')),
        )
        .dy;
    expect(
      secondTop,
      lessThan(firstTop),
      reason: 'the most recently updated note is listed first',
    );
    expect(find.text('No notes yet'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('editing autosaves after the session debounce', (tester) async {
    await openVault(tester);
    await pumpNotes(tester);
    await openFixtureNote(tester);

    final commits = native.commitCount;
    await tester.enterText(
      find.byKey(const ValueKey('titleInput')),
      'Edited title',
    );
    await tester.enterText(
      find.byKey(const ValueKey('markdownInput')),
      '# Edited body',
    );
    await tester.pump();

    expect(session.data!.notes.single.title, 'Edited title');
    expect(native.commitCount, commits, reason: 'the debounce has not run yet');
    expect(find.text('Saved'), findsNothing);

    await settleSave(tester, commits: commits);

    expect(native.commitCount, greaterThan(commits));
    expect(session.data!.notes.single.markdown, '# Edited body');
    expect(find.text('Saved'), findsOneWidget);
  });

  testWidgets('delete needs confirmation and cancel keeps the note', (
    tester,
  ) async {
    await openVault(tester);
    await pumpNotes(tester);
    await openFixtureNote(tester);

    await tester.tap(find.byKey(const ValueKey('deleteNoteButton')));
    await tester.pump();
    expect(find.text('Delete note?'), findsOneWidget);
    expect(find.text(fixtureData.notes.single.title), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('cancelDeleteButton')));
    await tester.pump();

    expect(find.text('Delete note?'), findsNothing);
    expect(session.data!.notes, hasLength(1));
    expect(
      find.byKey(ValueKey('noteTile:${fixtureData.notes.single.id}')),
      findsOneWidget,
    );
  });

  testWidgets('confirming delete removes the note and clears the editor', (
    tester,
  ) async {
    await openVault(tester);
    await pumpNotes(tester);
    await openFixtureNote(tester);

    await tester.tap(find.byKey(const ValueKey('deleteNoteButton')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('confirmDeleteButton')));
    await tester.pump();
    await settleSave(tester);

    expect(session.data!.notes, isEmpty);
    expect(find.text('Delete note?'), findsNothing);
    expect(find.byKey(const ValueKey('markdownInput')), findsNothing);
    expect(find.text('No notes yet'), findsOneWidget);
  });

  testWidgets('Write and Preview share one source', (tester) async {
    await openVault(tester, empty: true);
    await pumpNotes(tester);
    await createNote(tester, 'Markdown', '# A heading\n\n**Important**');

    await tester.tap(find.text('Preview'));
    await tester.pump();
    expect(find.text('A heading'), findsOneWidget);
    expect(find.text('Important'), findsOneWidget);
    expect(find.byKey(const ValueKey('markdownInput')), findsNothing);

    await tester.tap(find.text('Write'));
    await tester.pump();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('markdownInput')))
          .controller!
          .text,
      '# A heading\n\n**Important**',
    );
    expect(session.data!.notes.single.markdown, '# A heading\n\n**Important**');
  });

  testWidgets('a save error replaces the notes surface with retry', (
    tester,
  ) async {
    await openVault(tester);
    await pumpApp(tester);
    expect(find.byKey(const ValueKey('notesScreen')), findsOneWidget);
    await openFixtureNote(tester);

    native.failNextCommit = true;
    await tester.enterText(
      find.byKey(const ValueKey('markdownInput')),
      '# Unsaved',
    );
    await tester.pump();
    await settleSave(tester);

    expect(session.phase, SessionPhase.storageError);
    expect(session.canMutate, isFalse);
    expect(find.text('Your last change is not saved yet'), findsOneWidget);
    expect(find.text('Saved'), findsNothing);
    expect(find.byKey(const ValueKey('markdownInput')), findsNothing);
    expect(find.byKey(const ValueKey('newNoteButton')), findsNothing);
  });

  testWidgets('locking disposes the editor and flushes the last keystroke', (
    tester,
  ) async {
    await openVault(tester);
    await pumpApp(tester);
    await openFixtureNote(tester);

    await tester.enterText(
      find.byKey(const ValueKey('titleInput')),
      'Locked draft title',
    );
    await tester.enterText(
      find.byKey(const ValueKey('markdownInput')),
      '# Locked draft body',
    );
    await tester.pump();

    await io(tester, session.lock);
    await tester.pump();

    expect(session.phase, SessionPhase.locked);
    expect(find.text('Unlock EnCryNote'), findsOneWidget);
    expect(find.byKey(const ValueKey('notesScreen')), findsNothing);
    expect(find.text('Locked draft title'), findsNothing);
    expect(find.textContaining('Locked draft body'), findsNothing);
    expect(find.byKey(const ValueKey('markdownInput')), findsNothing);

    await io(tester, () => session.unlock(localPassword));
    await tester.pump();

    expect(
      session.data!.notes.single.markdown,
      '# Locked draft body',
      reason: 'the last keystroke was sealed before the key was dropped',
    );
    expect(find.text('Locked draft title'), findsOneWidget);
    await openFixtureNote(tester);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('markdownInput')))
          .controller!
          .text,
      '# Locked draft body',
      reason: 'the source round-trips through the encrypted file',
    );
  });

  testWidgets('a delete dialog cannot outlive the unlocked session', (
    tester,
  ) async {
    await openVault(tester);
    await pumpApp(tester);
    await openFixtureNote(tester);

    await tester.tap(find.byKey(const ValueKey('deleteNoteButton')));
    await tester.pump();
    expect(find.text('Delete note?'), findsOneWidget);

    await io(tester, session.lock);
    await tester.pump();

    expect(find.text('Delete note?'), findsNothing);
    expect(find.text(fixtureData.notes.single.title), findsNothing);
    expect(find.text('Unlock EnCryNote'), findsOneWidget);
  });

  testWidgets('a frozen save drops the delete dialog and the editor', (
    tester,
  ) async {
    await openVault(tester);
    await pumpApp(tester);
    await openFixtureNote(tester);

    await tester.enterText(
      find.byKey(const ValueKey('markdownInput')),
      '# Frozen while confirming',
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('deleteNoteButton')));
    await tester.pump();
    expect(find.text('Delete note?'), findsOneWidget);

    // The pending debounce lands while the confirmation is open.
    native.failNextCommit = true;
    await settleSave(tester);
    expect(session.phase, SessionPhase.storageError);
    expect(find.text('Delete note?'), findsNothing);
    expect(find.text('Your last change is not saved yet'), findsOneWidget);
    expect(find.byKey(const ValueKey('markdownInput')), findsNothing);
    expect(find.textContaining('Frozen while confirming'), findsNothing);
    expect(find.text('Saved'), findsNothing);
  });

  testWidgets('narrow screens navigate between list and editor', (
    tester,
  ) async {
    await openVault(tester);
    await pumpNotes(tester, size: const Size(360, 640));

    expect(find.byKey(const ValueKey('notesScreen')), findsOneWidget);
    expect(find.byKey(const ValueKey('markdownInput')), findsNothing);
    expect(find.text(fixtureData.notes.single.title), findsOneWidget);

    await openFixtureNote(tester);
    expect(find.byKey(const ValueKey('markdownInput')), findsOneWidget);
    expect(find.text(fixtureData.notes.single.title), findsWidgets);
    expect(
      find.byKey(ValueKey('noteTile:${fixtureData.notes.single.id}')),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey('editorBackButton')));
    await tester.pump();
    expect(find.byKey(const ValueKey('markdownInput')), findsNothing);
    expect(
      find.byKey(ValueKey('noteTile:${fixtureData.notes.single.id}')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('wide screens keep the list beside the editor from 720', (
    tester,
  ) async {
    await openVault(tester);
    for (final width in [720.0, 1100.0]) {
      await tester.pumpWidget(const SizedBox());
      await pumpNotes(tester, size: Size(width, 900));

      expect(
        find.byKey(ValueKey('noteTile:${fixtureData.notes.single.id}')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('selectNoteHint')), findsOneWidget);
      await openFixtureNote(tester);

      expect(find.byKey(const ValueKey('markdownInput')), findsOneWidget);
      expect(
        find.byKey(ValueKey('noteTile:${fixtureData.notes.single.id}')),
        findsOneWidget,
        reason: 'the list stays beside the editor at $width',
      );
      expect(find.byKey(const ValueKey('editorBackButton')), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('2x text stays intact in light and dark at every width', (
    tester,
  ) async {
    await openVault(tester);
    for (final brightness in [Brightness.light, Brightness.dark]) {
      for (final width in [360.0, 720.0, 1100.0]) {
        await tester.pumpWidget(const SizedBox());
        await pumpNotes(
          tester,
          size: Size(width, 800),
          textScale: 2,
          brightness: brightness,
        );
        await openFixtureNote(tester);
        expect(find.byKey(const ValueKey('markdownInput')), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    }
  });

  testWidgets('only real title and body edits report activity', (tester) async {
    await openVault(tester);
    final activity = PrivacySignal();
    final leavings = PrivacySignal();
    addTearDown(activity.dispose);
    addTearDown(leavings.dispose);
    var reports = 0;
    activity.addListener(() => reports++);

    useSize(tester, const Size(800, 900));
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: PrivacySignals(
          activity: activity,
          leavings: leavings,
          child: NotesScreen(session: session, transfer: transfer),
        ),
      ),
    );
    await tester.pump();
    expect(reports, 0, reason: 'opening the screen is not a user edit');

    await openFixtureNote(tester);
    expect(reports, 0, reason: 'switching notes is not a user edit');

    await tester.enterText(find.byKey(const ValueKey('titleInput')), 'Typed');
    expect(reports, 1);
    await tester.enterText(
      find.byKey(const ValueKey('markdownInput')),
      'Typed body',
    );
    expect(reports, 2);
    await settleSave(tester);
  });

  testWidgets(
    'switching notes flushes the last keystroke before the debounce',
    (tester) async {
      await openVault(tester, empty: true);
      await pumpNotes(tester);
      await createNote(tester, 'First', 'first body');
      await createNote(tester, 'Second', 'second body');

      final commits = native.commitCount;
      await tester.enterText(
        find.byKey(const ValueKey('markdownInput')),
        'second edited',
      );
      await tester.pump();
      expect(native.commitCount, commits);

      await tester.tap(
        find.byKey(ValueKey('noteTile:${noteTitled('First').id}')),
      );
      await tester.pump();
      for (var i = 0; i < 200; i++) {
        if (native.commitCount > commits) break;
        await io(
          tester,
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      expect(
        native.commitCount,
        greaterThan(commits),
        reason: 'leaving the note flushes instead of waiting for the debounce',
      );
      expect(noteTitled('Second').markdown, 'second edited');
    },
  );

  testWidgets('Settings opens from the notes surface and closes on lock', (
    tester,
  ) async {
    await openVault(tester);
    await pumpApp(tester);

    await tester.tap(find.byKey(const ValueKey('settingsButton')));
    await tester.pumpAndSettle();
    expect(find.text('Auto-lock'), findsOneWidget);

    await io(tester, session.lock);
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('Auto-lock'), findsNothing);
    expect(find.text('Unlock EnCryNote'), findsOneWidget);
  });

  testWidgets('primary controls meet the 44 pixel touch target', (
    tester,
  ) async {
    await openVault(tester);
    await pumpNotes(tester, size: const Size(360, 640));
    await openFixtureNote(tester);

    for (final key in [
      'lockNowButton',
      'settingsButton',
      'deleteNoteButton',
      'editorBackButton',
    ]) {
      final size = tester.getSize(find.byKey(ValueKey(key)));
      expect(
        size.height,
        greaterThanOrEqualTo(44),
        reason: '$key is a real touch target',
      );
      expect(size.width, greaterThanOrEqualTo(44), reason: key);
    }
    expect(
      tester.getSize(find.byType(SegmentedButton<bool>)).height,
      greaterThanOrEqualTo(48),
      reason: 'the Write/Preview segments are a real touch target',
    );

    await tester.tap(find.byKey(const ValueKey('deleteNoteButton')));
    await tester.pump();
    for (final key in ['cancelDeleteButton', 'confirmDeleteButton']) {
      expect(
        tester.getSize(find.byKey(ValueKey(key))).height,
        greaterThanOrEqualTo(44),
        reason: '$key is a real touch target',
      );
    }
  });

  testWidgets('a seal failure shows the retry surface, not a dead editor', (
    tester,
  ) async {
    await openSealVault(tester);
    useSize(tester, const Size(800, 1200));
    await tester.pumpWidget(
      EnCryNoteApp(session: sealSession, transfer: sealTransfer),
    );
    await tester.pump();
    await tester.tap(
      find.byKey(ValueKey('noteTile:${fixtureData.notes.single.id}')),
    );
    await tester.pump();

    sealCrypto.failSeal = true;
    await tester.enterText(
      find.byKey(const ValueKey('markdownInput')),
      '# unsealed edit',
    );
    await tester.pump();
    await tester.pump(NoteSession.autosaveDebounce);
    for (var i = 0; i < 50; i++) {
      if (sealSession.phase == SessionPhase.storageError) break;
      await io(
        tester,
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    await tester.pump();

    expect(sealSession.phase, SessionPhase.storageError);
    expect(sealSession.canMutate, isFalse);
    expect(find.text('Your last change is not saved yet'), findsOneWidget);
    expect(find.byKey(const ValueKey('markdownInput')), findsNothing);
    expect(find.byKey(const ValueKey('newNoteButton')), findsNothing);
    expect(find.text('Saved'), findsNothing);

    // Navigation cannot quietly retry the seal; only the retry button may.
    final attempts = sealCrypto.sealAttempts;
    await io(tester, sealSession.flushSave);
    expect(sealCrypto.sealAttempts, attempts);

    sealCrypto.failSeal = false;
    await tester.tap(find.byKey(const ValueKey('retryButton')));
    await tester.pump();
    for (var i = 0; i < 100; i++) {
      if (sealSession.phase == SessionPhase.unlocked) break;
      await io(
        tester,
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    await tester.pump();

    expect(sealSession.phase, SessionPhase.unlocked);
    expect(
      sealSession.data!.notes.single.markdown,
      '# unsealed edit',
      reason: 'the retried seal covers the edit that failed',
    );
    expect(find.byKey(const ValueKey('notesScreen')), findsOneWidget);
  });

  testWidgets('lock after a seal failure retries into a locked vault', (
    tester,
  ) async {
    await openSealVault(tester);
    useSize(tester, const Size(800, 1200));
    await tester.pumpWidget(
      EnCryNoteApp(session: sealSession, transfer: sealTransfer),
    );
    await tester.pump();
    await tester.tap(
      find.byKey(ValueKey('noteTile:${fixtureData.notes.single.id}')),
    );
    await tester.pump();

    sealCrypto.failSeal = true;
    await tester.enterText(
      find.byKey(const ValueKey('markdownInput')),
      '# must not be lost',
    );
    await tester.pump();
    await tester.pump(NoteSession.autosaveDebounce);
    for (var i = 0; i < 50; i++) {
      if (sealSession.phase == SessionPhase.storageError) break;
      await io(
        tester,
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    await tester.pump();
    expect(sealSession.phase, SessionPhase.storageError);

    // The lock cannot drop the key while an accepted edit is unsealed.
    await io(tester, sealSession.lock);
    await tester.pump();

    expect(sealSession.phase, SessionPhase.storageError);
    expect(sealSession.data, isNull, reason: 'the lock intent redacts notes');
    expect(sealSession.holdsSensitiveState, isTrue);
    expect(find.text('Your last change is not saved yet'), findsOneWidget);
    expect(find.textContaining('must not be lost'), findsNothing);
    expect(find.text('Unlock EnCryNote'), findsNothing);

    // Retry seals the edit, then the earlier lock intent completes locked.
    sealCrypto.failSeal = false;
    await tester.tap(find.byKey(const ValueKey('retryButton')));
    await tester.pump();
    for (var i = 0; i < 100; i++) {
      if (sealSession.phase == SessionPhase.locked) break;
      await io(
        tester,
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    await tester.pump();

    expect(sealSession.phase, SessionPhase.locked);
    expect(sealSession.holdsSensitiveState, isFalse);
    expect(find.text('Unlock EnCryNote'), findsOneWidget);
    expect(find.text('Your last change is not saved yet'), findsNothing);

    await tester.enterText(
      find.byKey(const ValueKey('unlockPasswordInput')),
      localPassword,
    );
    await tester.tap(find.byKey(const ValueKey('unlockButton')));
    await tester.pump();
    for (var i = 0; i < 100; i++) {
      if (sealSession.phase == SessionPhase.unlocked) break;
      await io(
        tester,
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    await tester.pump();

    expect(sealSession.phase, SessionPhase.unlocked);
    expect(sealSession.data!.notes.single.markdown, '# must not be lost');
  });

  testWidgets('an over-limit draft is rejected without a save error surface', (
    tester,
  ) async {
    await openVault(tester);
    await pumpNotes(tester);
    await openFixtureNote(tester);

    // Real payload-limit rejection: the session keeps its state and the editor
    // restores what is actually stored.
    await tester.enterText(
      find.byKey(const ValueKey('markdownInput')),
      'x' * (maxPayloadBytes + 1),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));

    expect(session.phase, SessionPhase.unlocked);
    expect(session.canMutate, isTrue);
    expect(find.text('This note is too large to save.'), findsOneWidget);
    expect(find.text('Saved'), findsNothing);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('markdownInput')))
          .controller!
          .text,
      fixtureData.notes.single.markdown,
      reason: 'the rejected draft is restored, not kept as a phantom',
    );
    expect(find.byKey(const ValueKey('markdownInput')), findsOneWidget);
  });

  testWidgets('the app still shows loading before any notes surface', (
    tester,
  ) async {
    useSize(tester, const Size(800, 1200));
    await tester.pumpWidget(EnCryNoteApp(session: session, transfer: transfer));
    await tester.pump();

    expect(find.text('Opening your vault...'), findsOneWidget);
    expect(find.byKey(const ValueKey('notesScreen')), findsNothing);
  });
}
