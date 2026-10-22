import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hello_flutter/app.dart';
import 'package:hello_flutter/l10n/generated/app_localizations.dart';
import 'package:hello_flutter/platform/native_bridge.dart';
import 'package:hello_flutter/session/note_session.dart';
import 'package:hello_flutter/transfer/transfer_dialogs.dart';
import 'package:hello_flutter/transfer/transfer_service.dart';
import 'package:hello_flutter/vault/vault_crypto.dart';
import 'package:hello_flutter/vault/vault_store.dart';
import 'package:hello_flutter/vault/vault_types.dart';

import '../support/fake_native_bridge.dart';
import '../support/fixtures.dart';

/// The English transfer dialogs: confirmation, warnings, lock teardown and the
/// resume-after-unlock path that must not reopen the picker.
void main() {
  final crypto = VaultCrypto();
  late Uint8List seed;
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
  });

  setUp(() async {
    scratch++;
    dir = await Directory(
      '${Directory.current.path}/.dart_tool/test_scratch/transfer_dialogs/'
      '${DateTime.now().microsecondsSinceEpoch}_$scratch',
    ).create(recursive: true);
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
    await File('${dir.path}/vault.enc').writeAsBytes(seed, flush: true);
    await session.load();
    await session.unlock(localPassword);
  });

  tearDown(() async {
    session.dispose();
    transfer.dispose();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<T> io<T>(WidgetTester tester, Future<T> Function() body) async {
    final value = await tester.runAsync(body);
    return value as T;
  }

  /// Pumps enough frames for a dialog to finish its exit animation. A progress
  /// indicator animates forever, so `pumpAndSettle` would never return while a
  /// transfer is still working.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await io(
        tester,
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  Future<void> tapAndWait(
    WidgetTester tester,
    String key, {
    required bool Function() done,
  }) async {
    await tester.tap(find.byKey(ValueKey(key)));
    await tester.pump();
    // The crypto runs in a helper isolate: let it finish in the real zone, then
    // pump so its continuation runs in the widget-test zone.
    for (var i = 0; i < 200; i++) {
      if (done()) break;
      await io(
        tester,
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(done(), isTrue, reason: 'the transfer did not settle in time');
    await settle(tester);
  }

  Future<void> pumpHost(
    WidgetTester tester, {
    required Future<void> Function(BuildContext) open,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(800, 1200);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => open(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('open'));
    await tester.pump();
  }

  group('export dialog', () {
    testWidgets('asks for a new password and both warnings', (tester) async {
      await pumpHost(
        tester,
        open: (context) => showExportDialog(context, transfer),
      );

      expect(find.text('Export notes'), findsOneWidget);
      expect(find.byKey(const ValueKey('exportPasswordInput')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('confirmExportPasswordInput')),
        findsOneWidget,
      );
      expect(
        find.textContaining('recovery questions cannot open it'),
        findsOneWidget,
      );
      expect(find.textContaining('stays plaintext'), findsOneWidget);
    });

    testWidgets('a short or mismatched password writes nothing', (
      tester,
    ) async {
      await pumpHost(
        tester,
        open: (context) => showExportDialog(context, transfer),
      );

      await tester.enterText(
        find.byKey(const ValueKey('exportPasswordInput')),
        'short',
      );
      await tester.enterText(
        find.byKey(const ValueKey('confirmExportPasswordInput')),
        'short',
      );
      await tester.tap(find.byKey(const ValueKey('confirmExportButton')));
      await tester.pump();
      expect(find.text('Use at least 8 characters.'), findsOneWidget);
      expect(native.savedExport, isNull);

      await tester.enterText(
        find.byKey(const ValueKey('exportPasswordInput')),
        'export-1234',
      );
      await tester.enterText(
        find.byKey(const ValueKey('confirmExportPasswordInput')),
        'export-1235',
      );
      await tester.tap(find.byKey(const ValueKey('confirmExportButton')));
      await tester.pump();
      expect(find.text('The passwords do not match.'), findsOneWidget);
      expect(native.savedExport, isNull);
    });

    testWidgets('saving closes the dialog and clears the password fields', (
      tester,
    ) async {
      await pumpHost(
        tester,
        open: (context) => showExportDialog(context, transfer),
      );
      await tester.enterText(
        find.byKey(const ValueKey('exportPasswordInput')),
        'export-1234',
      );
      await tester.enterText(
        find.byKey(const ValueKey('confirmExportPasswordInput')),
        'export-1234',
      );

      await tapAndWait(
        tester,
        'confirmExportButton',
        done: () => native.savedExport != null,
      );
      await settle(tester);

      expect(find.text('Export notes'), findsNothing);
      expect(native.savedExport, isNotNull);
      final notes = await io(
        tester,
        () => crypto.importExport(native.savedExport!, 'export-1234'),
      );
      expect(notes.single.markdown, fixtureData.notes.single.markdown);
    });

    testWidgets('a lock closes the dialog and drops typed passwords', (
      tester,
    ) async {
      await pumpHost(
        tester,
        open: (context) => showExportDialog(context, transfer),
      );
      await tester.enterText(
        find.byKey(const ValueKey('exportPasswordInput')),
        'export-1234',
      );
      await tester.enterText(
        find.byKey(const ValueKey('confirmExportPasswordInput')),
        'export-1234',
      );

      await io(tester, session.lock);
      await settle(tester);

      expect(find.text('Export notes'), findsNothing);
      expect(find.text('export-1234'), findsNothing);
      expect(find.byKey(const ValueKey('exportPasswordInput')), findsNothing);
      expect(native.savedExport, isNull);
      expect(session.data, isNull);
    });

    testWidgets('cancelling changes no note', (tester) async {
      await pumpHost(
        tester,
        open: (context) => showExportDialog(context, transfer),
      );
      await tester.tap(find.byKey(const ValueKey('cancelExportButton')));
      await settle(tester);

      expect(find.text('Export notes'), findsNothing);
      expect(native.savedExport, isNull);
      expect(session.data!.notes, hasLength(1));
      expect(native.commitCount, 0);
    });

    testWidgets('the save panel opens only after the ciphertext exists', (
      tester,
    ) async {
      native.saveGate = Completer<void>();
      await pumpHost(
        tester,
        open: (context) => showExportDialog(context, transfer),
      );
      await tester.enterText(
        find.byKey(const ValueKey('exportPasswordInput')),
        'export-1234',
      );
      await tester.enterText(
        find.byKey(const ValueKey('confirmExportPasswordInput')),
        'export-1234',
      );
      await tester.tap(find.byKey(const ValueKey('confirmExportButton')));
      for (var i = 0; i < 200 && native.savedExport == null; i++) {
        await io(
          tester,
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }

      // While the panel is up, the dialog holds no password field and no note
      // text, and the bytes handed over are already an export envelope.
      expect(native.savedExport, isNotNull);
      expect(find.byKey(const ValueKey('exportPasswordInput')), findsNothing);
      expect(find.text('export-1234'), findsNothing);
      expect(find.text(fixtureData.notes.single.markdown), findsNothing);
      final saved = native.savedExport!;
      expect(
        utf8.decode(saved, allowMalformed: true).contains('export-1234'),
        isFalse,
      );

      // Escape and back cannot recall a save the native panel already owns.
      await tester.binding.handlePopRoute();
      await settle(tester);
      expect(find.text('Export notes'), findsOneWidget);

      native.saveGate!.complete();
      await settle(tester);
      expect(find.text('Export notes'), findsNothing);
      final notes = await io(
        tester,
        () => crypto.importExport(saved, 'export-1234'),
      );
      expect(notes.single.markdown, fixtureData.notes.single.markdown);
    });
  });

  group('import dialog', () {
    testWidgets('a Markdown file is imported after confirming', (tester) async {
      native.nextPicked = const PickedImport(
        token: 'md-1',
        name: 'Shopping list.md',
      );
      native.importBytes = Uint8List.fromList(utf8.encode('# Milk\n'));

      await pumpHost(
        tester,
        open: (context) => showImportDialog(context, transfer),
      );
      await settle(tester);
      expect(find.text('Shopping list.md'), findsOneWidget);
      expect(find.textContaining('stays plaintext'), findsOneWidget);
      expect(find.byKey(const ValueKey('importPasswordInput')), findsNothing);

      await tapAndWait(
        tester,
        'confirmImportButton',
        done: () => session.data!.notes.length == 2,
      );
      await settle(tester);

      expect(find.text('Import notes'), findsNothing);
      expect(native.released, ['md-1']);
      expect(
        session.data!.notes.map((note) => note.title),
        contains('Shopping list'),
      );
    });

    testWidgets('an export asks for its own password', (tester) async {
      final bytes = await io(
        tester,
        () => crypto.exportNotes(fixtureData.notes, 'export-1234'),
      );
      native.nextPicked = PickedImport(
        token: 'enc-1',
        name: 'notes.encrynote',
        length: bytes.length,
      );
      native.importBytes = bytes;

      await pumpHost(
        tester,
        open: (context) => showImportDialog(context, transfer),
      );
      await settle(tester);
      expect(find.byKey(const ValueKey('importPasswordInput')), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('importPasswordInput')),
        localPassword,
      );
      await tapAndWait(
        tester,
        'confirmImportButton',
        done: () => native.released.isNotEmpty,
      );
      await settle(tester);

      expect(
        find.text(
          'That export password is incorrect. Your notes were not changed.',
        ),
        findsOneWidget,
      );
      expect(session.data!.notes, hasLength(1));
      expect(native.released, ['enc-1']);
    });

    testWidgets('a cancelled picker closes without an error', (tester) async {
      native.nextPicked = null;

      await pumpHost(
        tester,
        open: (context) => showImportDialog(context, transfer),
      );
      await settle(tester);

      expect(find.text('Import notes'), findsNothing);
      expect(session.data!.notes, hasLength(1));
      expect(native.released, isEmpty);
    });

    testWidgets('cancel releases the handle and keeps every note', (
      tester,
    ) async {
      native.nextPicked = const PickedImport(token: 'md-2', name: 'x.md');
      native.importBytes = Uint8List.fromList(utf8.encode('body'));

      await pumpHost(
        tester,
        open: (context) => showImportDialog(context, transfer),
      );
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('cancelImportButton')));
      await settle(tester);

      expect(native.released, ['md-2']);
      expect(session.data!.notes, hasLength(1));
      expect(transfer.pendingImport, isNull);
    });

    testWidgets('a lock closes the dialog and keeps only the handle', (
      tester,
    ) async {
      native.nextPicked = const PickedImport(token: 'md-3', name: 'kept.md');
      native.importBytes = Uint8List.fromList(utf8.encode('kept body'));

      await pumpHost(
        tester,
        open: (context) => showImportDialog(context, transfer),
      );
      await settle(tester);
      expect(find.text('kept.md'), findsOneWidget);

      await io(tester, session.lock);
      await settle(tester);

      expect(find.text('Import notes'), findsNothing);
      expect(find.text('kept.md'), findsNothing);
      expect(session.data, isNull);
      expect(transfer.pendingImport?.token, 'md-3');
      expect(native.readTokens, isEmpty, reason: 'nothing read while locked');
      expect(native.released, isEmpty, reason: 'the handle survives the lock');
      expect(session.data, isNull);
    });

    testWidgets('a barrier tap cancels the selection exactly once', (
      tester,
    ) async {
      native.nextPicked = const PickedImport(
        token: 'md-8',
        name: 'dismissed.md',
      );
      native.importBytes = Uint8List.fromList(utf8.encode('dismissed body'));

      await pumpHost(
        tester,
        open: (context) => showImportDialog(context, transfer),
      );
      await settle(tester);
      expect(find.text('dismissed.md'), findsOneWidget);

      await tester.tapAt(const Offset(5, 5));
      await settle(tester);

      expect(find.text('Import notes'), findsNothing);
      expect(native.released, ['md-8'], reason: 'released exactly once');
      expect(transfer.pendingImport, isNull);
      expect(session.data!.notes, hasLength(1));
      expect(native.readTokens, isEmpty);
      expect(native.commitCount, 0);
    });

    testWidgets('Android back cancels the selection exactly once', (
      tester,
    ) async {
      native.nextPicked = const PickedImport(token: 'md-9', name: 'backed.md');
      native.importBytes = Uint8List.fromList(utf8.encode('back body'));

      await pumpHost(
        tester,
        open: (context) => showImportDialog(context, transfer),
      );
      await settle(tester);
      expect(find.text('backed.md'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await settle(tester);

      expect(find.text('Import notes'), findsNothing);
      expect(native.released, ['md-9'], reason: 'released exactly once');
      expect(transfer.pendingImport, isNull);
      expect(session.data!.notes, hasLength(1));
      expect(native.readTokens, isEmpty);
      expect(native.commitCount, 0);
    });

    testWidgets('a dismissed selection is not offered again on the next open', (
      tester,
    ) async {
      native.nextPicked = const PickedImport(token: 'md-10', name: 'gone.md');
      native.importBytes = Uint8List.fromList(utf8.encode('gone body'));

      await pumpHost(
        tester,
        open: (context) => showImportDialog(context, transfer),
      );
      await settle(tester);
      await tester.tapAt(const Offset(5, 5));
      await settle(tester);
      expect(transfer.pendingImport, isNull);

      // A fresh open must ask the picker again, not resurrect the old file.
      native.nextPicked = const PickedImport(token: 'md-11', name: 'fresh.md');
      await tester.tap(find.text('open'));
      await settle(tester);

      expect(find.text('fresh.md'), findsOneWidget);
      expect(find.text('gone.md'), findsNothing);
      expect(native.pickCalls, 2);
      expect(native.released, ['md-10']);
    });

    testWidgets('cancelling during a read releases once and commits nothing', (
      tester,
    ) async {
      native.nextPicked = const PickedImport(token: 'md-12', name: 'slow.md');
      native.importBytes = Uint8List.fromList(utf8.encode('slow body'));
      native.readGate = Completer<void>();

      await pumpHost(
        tester,
        open: (context) => showImportDialog(context, transfer),
      );
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('confirmImportButton')));
      await tester.pump();
      // The read is still open, so Cancel is offered and truthful.
      expect(find.byKey(const ValueKey('cancelImportButton')), findsOneWidget);
      expect(native.readTokens, ['md-12']);

      await tester.tap(find.byKey(const ValueKey('cancelImportButton')));
      await settle(tester);
      expect(find.text('Import notes'), findsNothing);

      native.readGate!.complete();
      await settle(tester);
      await io(
        tester,
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );

      expect(native.released, ['md-12'], reason: 'released exactly once');
      expect(session.data!.notes, hasLength(1));
      expect(native.commitCount, 0);
      expect(transfer.pendingImport, isNull);
    });

    testWidgets('a barrier tap during a read cannot commit later', (
      tester,
    ) async {
      native.nextPicked = const PickedImport(token: 'md-13', name: 'later.md');
      native.importBytes = Uint8List.fromList(utf8.encode('later body'));
      native.readGate = Completer<void>();

      await pumpHost(
        tester,
        open: (context) => showImportDialog(context, transfer),
      );
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('confirmImportButton')));
      await tester.pump();

      await tester.binding.handlePopRoute();
      await settle(tester);
      expect(find.text('Import notes'), findsNothing);

      native.readGate!.complete();
      await settle(tester);
      await io(
        tester,
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );

      expect(session.data!.notes, hasLength(1));
      expect(native.commitCount, 0);
      expect(native.released, ['md-13']);
    });
  });

  group('app root', () {
    Future<void> pumpApp(WidgetTester tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(800, 1200);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        EnCryNoteApp(session: session, transfer: transfer),
      );
      await tester.pump();
    }

    testWidgets('offers the import again after unlock, without a picker', (
      tester,
    ) async {
      native.nextPicked = const PickedImport(token: 'md-4', name: 'resume.md');
      native.importBytes = Uint8List.fromList(utf8.encode('resumed body'));
      await pumpApp(tester);

      // The picker ran, then the app lost focus before the import.
      await io(tester, transfer.pickImport);
      await io(tester, session.lock);
      await settle(tester);
      expect(native.pickCalls, 1);
      expect(find.text('Unlock EnCryNote'), findsOneWidget);

      await io(tester, () => session.unlock(localPassword));
      await settle(tester);

      expect(find.text('Import notes'), findsOneWidget);
      expect(find.text('resume.md'), findsOneWidget);
      expect(native.pickCalls, 1, reason: 'no second picker for a held handle');

      await tapAndWait(
        tester,
        'confirmImportButton',
        done: () => session.data!.notes.length == 2,
      );
      await settle(tester);

      expect(
        session.data!.notes.map((note) => note.markdown),
        contains('resumed body'),
      );
      expect(native.released, ['md-4']);
    });

    testWidgets('a dismissed resume is not reopened in a loop', (tester) async {
      native.nextPicked = const PickedImport(token: 'md-5', name: 'once.md');
      native.importBytes = Uint8List.fromList(utf8.encode('once'));
      await pumpApp(tester);
      await io(tester, transfer.pickImport);
      await io(tester, session.lock);
      await settle(tester);

      await io(tester, () => session.unlock(localPassword));
      await settle(tester);
      expect(find.text('Import notes'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('cancelImportButton')));
      await settle(tester);

      expect(find.text('Import notes'), findsNothing);
      expect(native.released, ['md-5']);
      expect(transfer.pendingImport, isNull);
      expect(session.data!.notes, hasLength(1));
    });

    testWidgets('a barrier-dismissed resume is not offered on a later unlock', (
      tester,
    ) async {
      native.nextPicked = const PickedImport(token: 'md-14', name: 'bar.md');
      native.importBytes = Uint8List.fromList(utf8.encode('bar body'));
      await pumpApp(tester);
      await io(tester, transfer.pickImport);
      await io(tester, session.lock);
      await settle(tester);

      await io(tester, () => session.unlock(localPassword));
      await settle(tester);
      expect(find.text('Import notes'), findsOneWidget);

      // Dismissing the resumed dialog is a cancel, not a pause.
      await tester.tapAt(const Offset(5, 5));
      await settle(tester);
      expect(native.released, ['md-14']);
      expect(transfer.pendingImport, isNull);

      await io(tester, session.lock);
      await settle(tester);
      await io(tester, () => session.unlock(localPassword));
      await settle(tester);

      expect(find.text('Import notes'), findsNothing);
      expect(find.text('bar.md'), findsNothing);
      expect(native.released, ['md-14'], reason: 'still released only once');
      expect(session.data!.notes, hasLength(1));
    });

    testWidgets('a failed commit keeps the busy UI truthful', (tester) async {
      native.nextPicked = const PickedImport(token: 'md-15', name: 'slow.md');
      native.importBytes = Uint8List.fromList(utf8.encode('slow body'));
      // Hold the vault commit open so the dialog is in its committing stage.
      native.holdAt = CommitStage.fileSync;
      await pumpApp(tester);
      await tester.tap(find.byKey(const ValueKey('importNotesButton')));
      await settle(tester);
      expect(find.text('slow.md'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('confirmImportButton')));
      await tester.pump();
      // Pump while the seal runs; the commit then parks at the held stage.
      for (var i = 0; i < 200 && !native.entered.isCompleted; i++) {
        await io(
          tester,
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(native.entered.isCompleted, isTrue);
      await settle(tester);

      expect(
        find.byKey(const ValueKey('importSavingHint')),
        findsOneWidget,
        reason: 'the UI says the commit cannot be cancelled',
      );
      final cancel = tester.widget<TextButton>(
        find.byKey(const ValueKey('cancelImportButton')),
      );
      expect(cancel.onPressed, isNull, reason: 'no impossible cancel offer');

      native.release();
      await settle(tester);
      expect(find.text('Import notes'), findsNothing);
      expect(
        session.data!.notes.map((note) => note.markdown),
        contains('slow body'),
      );
      expect(native.released, ['md-15']);
    });

    testWidgets('a picker that returns after the lock is offered on unlock', (
      tester,
    ) async {
      native.nextPicked = const PickedImport(token: 'md-7', name: 'late.md');
      native.importBytes = Uint8List.fromList(utf8.encode('late body'));
      native.pickGate = Completer<void>();
      await pumpApp(tester);

      // The OS panel is still up when the lock lands, so its handle arrives
      // only after the vault is closed.
      final picking = transfer.pickImport();
      await tester.pump();
      await io(tester, session.lock);
      await settle(tester);
      expect(transfer.pendingImport, isNull);

      native.pickGate!.complete();
      await tester.pump();
      await settle(tester);
      await picking;
      expect(transfer.pendingImport?.token, 'md-7');

      await io(tester, () => session.unlock(localPassword));
      await settle(tester);

      expect(find.text('Import notes'), findsOneWidget);
      expect(find.text('late.md'), findsOneWidget);
    });

    testWidgets('the unlocked app shows the transfer buttons', (tester) async {
      await pumpApp(tester);

      expect(find.byKey(const ValueKey('notesScreen')), findsOneWidget);
      expect(find.byKey(const ValueKey('exportNotesButton')), findsOneWidget);
      expect(find.byKey(const ValueKey('importNotesButton')), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const ValueKey('exportNotesButton'))).height,
        greaterThanOrEqualTo(44),
      );
    });

    testWidgets('an open import dialog is not duplicated by a rebuild', (
      tester,
    ) async {
      native.nextPicked = const PickedImport(token: 'md-6', name: 'one.md');
      native.importBytes = Uint8List.fromList(utf8.encode('one'));
      await pumpApp(tester);

      await tester.tap(find.byKey(const ValueKey('importNotesButton')));
      await tester.pump();
      await settle(tester);
      expect(find.text('Import notes'), findsOneWidget);

      // Any unrelated session notification rebuilds the root; the dialog the
      // notes screen owns must stay the only one.
      await io(tester, () => session.setAutoLock(AutoLockMode.oneMinute));
      await settle(tester);

      expect(find.text('Import notes'), findsOneWidget);
      expect(native.pickCalls, 1);

      await tester.tap(find.byKey(const ValueKey('cancelImportButton')));
      await settle(tester);
      expect(native.released, ['md-6']);
    });
  });
}
