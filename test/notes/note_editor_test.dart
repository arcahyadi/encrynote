import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hello_flutter/l10n/generated/app_localizations.dart';
import 'package:hello_flutter/notes/note_editor.dart';
import 'package:hello_flutter/session/note_session.dart';
import 'package:hello_flutter/vault/vault_crypto.dart';
import 'package:hello_flutter/vault/vault_store.dart';
import 'package:hello_flutter/vault/vault_types.dart';

import '../support/fake_native_bridge.dart';
import '../support/fixtures.dart';

/// Counts real HTTP client creation, so a preview that tried the network would
/// be caught even if the request itself failed fast.
class _SpyHttpOverrides extends HttpOverrides {
  int clients = 0;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    clients++;
    throw StateError('network is forbidden in Preview');
  }
}

/// Rejects one marked draft as over the payload limit without allocating 8 MiB.
class _LimitCrypto extends VaultCrypto {
  @override
  void checkSnapshotFits(UnlockedVault vault, VaultData data, int revision) {
    if (data.notes.any(
      (note) =>
          note.markdown.contains('TOO BIG') || note.title.contains('TOO BIG'),
    )) {
      throw const VaultException(FailureCode.limit, 'payload');
    }
    super.checkSnapshotFits(vault, data, revision);
  }
}

/// Source/Preview editor: rendering safety, limits and rejected drafts.
void main() {
  final crypto = VaultCrypto();
  late Uint8List seed;
  late Directory scratchRoot;
  late Directory dir;
  late FakeNativeBridge native;
  late NoteSession session;
  late NoteSession limited;
  var scratch = 0;

  setUpAll(() async {
    seed = (await crypto.createVault(
      localPassword,
      fixtureRecovery,
      fixtureData,
    )).envelope;
    scratchRoot = await Directory(
      '${Directory.current.path}/.dart_tool/test_scratch/note_editor/'
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
    // Created here, not in a test body: the session's queue must live in the
    // real zone or its IO would never complete under the fake-async test zone.
    limited = NoteSession(
      crypto: _LimitCrypto(),
      store: VaultStore(directory: dir, native: native),
    );
  });

  tearDown(() {
    session.dispose();
    limited.dispose();
  });

  Future<T> io<T>(WidgetTester tester, Future<T> Function() body) async {
    final value = await tester.runAsync(body);
    return value as T;
  }

  Future<void> openVault(WidgetTester tester, {NoteSession? using}) async {
    final target = using ?? session;
    await io(tester, () async {
      await File('${dir.path}/vault.enc').writeAsBytes(seed);
      await target.load();
      await target.unlock(localPassword);
    });
    expect(target.phase, SessionPhase.unlocked);
  }

  Future<void> pumpEditor(
    WidgetTester tester, {
    NoteSession? using,
    Size size = const Size(800, 1000),
    double textScale = 1,
  }) async {
    final target = using ?? session;
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: NoteEditor(session: target, note: target.data!.notes.single),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> settleSave(WidgetTester tester) async {
    final before = native.commitCount;
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

  /// Every image provider that could touch the network or the disk would have
  /// to build one of these; the placeholder path builds none.
  void expectNoImageWidgets(WidgetTester tester) {
    expect(find.byType(Image), findsNothing);
    expect(find.byType(RawImage), findsNothing);
    expect(tester.widgetList(find.byType(Image)), isEmpty);
  }

  bool hasRecognizer(InlineSpan? span) {
    if (span == null) return false;
    if (span is TextSpan) {
      if (span.recognizer != null) return true;
      return span.children?.any(hasRecognizer) ?? false;
    }
    return false;
  }

  bool treeHasRecognizer(Widget widget) {
    if (widget is RichText) return hasRecognizer(widget.text);
    if (widget is SelectableText) return hasRecognizer(widget.textSpan);
    if (widget is Text) return hasRecognizer(widget.textSpan);
    return false;
  }

  testWidgets('Preview renders Markdown and Write keeps the exact source', (
    tester,
  ) async {
    await openVault(tester);
    await pumpEditor(tester);

    const source = '# A heading\n\n**Important**';
    await tester.enterText(find.byKey(const ValueKey('markdownInput')), source);
    await tester.pump();

    await tester.tap(find.text('Preview'));
    await tester.pump();
    expect(find.text('A heading'), findsOneWidget);
    expect(find.text('Important'), findsOneWidget);

    await tester.tap(find.text('Write'));
    await tester.pump();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('markdownInput')))
          .controller!
          .text,
      source,
    );
    await settleSave(tester);
  });

  testWidgets('Preview never loads images from network, disk or assets', (
    tester,
  ) async {
    final sentinel = await io(tester, () async {
      final file = File('${dir.path}/secret.png');
      await file.writeAsString('plaintext-file-sentinel');
      return file.path;
    });
    final overrides = _SpyHttpOverrides();
    final previous = HttpOverrides.current;
    HttpOverrides.global = overrides;
    addTearDown(() => HttpOverrides.global = previous);

    await openVault(tester);
    final note = session.data!.notes.single.copyWith(
      markdown: [
        '# Images',
        '![remote](https://example.com/tracker.png)',
        '![file](file://$sentinel)',
        '![absolute]($sentinel)',
        '![relative](pictures/local.png)',
        '![asset](assets/images/logo.png)',
      ].join('\n\n'),
    );
    await io(tester, () => session.saveNote(note));
    await pumpEditor(tester);

    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();

    expect(find.text('Images'), findsOneWidget);
    expect(
      find.text('Image not available offline.'),
      findsNWidgets(5),
      reason: 'every image reference becomes the offline notice',
    );
    expectNoImageWidgets(tester);
    expect(
      tester.binding.imageCache.currentSize,
      0,
      reason: 'no image provider was resolved',
    );
    expect(
      overrides.clients,
      0,
      reason: 'Preview must never create an HTTP client',
    );
    expect(find.textContaining('plaintext-file-sentinel'), findsNothing);
    expect(tester.takeException(), isNull);
    await settleSave(tester);
  });

  testWidgets('links are selectable text with no launch recognizer', (
    tester,
  ) async {
    await openVault(tester);
    final note = session.data!.notes.single.copyWith(
      markdown: 'Read [the example](https://example.com/private?q=1) now.',
    );
    await io(tester, () => session.saveNote(note));
    await pumpEditor(tester);

    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();

    final link = find.text('the example');
    expect(link, findsOneWidget);
    expect(
      find.textContaining('https://example.com/private'),
      findsNothing,
      reason: 'the destination is not rendered as a target',
    );
    final selectable = tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .singleWhere((widget) => widget.data == 'the example');
    expect(selectable.data, 'the example');
    expect(
      hasRecognizer(selectable.textSpan),
      isFalse,
      reason: 'a link must not carry a tap recognizer',
    );
    expect(
      tester.widgetList<Widget>(find.byType(RichText)).any(treeHasRecognizer),
      isFalse,
      reason: 'no preview text span may carry a recognizer',
    );

    await tester.tap(link);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await settleSave(tester);
  });

  testWidgets('a rejected over-limit draft restores the last accepted source', (
    tester,
  ) async {
    await openVault(tester, using: limited);
    await pumpEditor(tester, using: limited);

    final accepted = limited.data!.notes.single.markdown;
    await tester.enterText(
      find.byKey(const ValueKey('markdownInput')),
      'TOO BIG',
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));

    expect(
      limited.data!.notes.single.markdown,
      accepted,
      reason: 'the session keeps the last accepted text',
    );
    expect(
      limited.canMutate,
      isTrue,
      reason: 'a rejected draft never entered the writer',
    );
    expect(find.text('This note is too large to save.'), findsOneWidget);
    expect(find.text('Saved'), findsNothing);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('markdownInput')))
          .controller!
          .text,
      accepted,
      reason: 'the rejected draft is restored to the last accepted value',
    );

    await tester.enterText(
      find.byKey(const ValueKey('markdownInput')),
      'small again',
    );
    await tester.pump();
    await settleSave(tester);
    expect(limited.data!.notes.single.markdown, 'small again');
    expect(find.text('This note is too large to save.'), findsNothing);
    expect(find.text('Saved'), findsOneWidget);
  });

  testWidgets('a rejected over-limit title restores the last accepted title', (
    tester,
  ) async {
    await openVault(tester, using: limited);
    await pumpEditor(tester, using: limited);

    final accepted = limited.data!.notes.single.title;
    await tester.enterText(
      find.byKey(const ValueKey('titleInput')),
      'TOO BIG TITLE',
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));

    expect(limited.data!.notes.single.title, accepted);
    expect(find.text('This note is too large to save.'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('titleInput')))
          .controller!
          .text,
      accepted,
    );
    expect(find.text('Saved'), findsNothing);
  });

  testWidgets('the editor keeps cursor and Preview after a rejected draft', (
    tester,
  ) async {
    await openVault(tester, using: limited);
    await pumpEditor(tester, using: limited);

    // A normal edit keeps the caret where the user left it and does not toggle
    // the view; only a rejected draft resets the source.
    await tester.enterText(
      find.byKey(const ValueKey('markdownInput')),
      'accepted body',
    );
    await tester.pump();
    await settleSave(tester);
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('markdownInput')),
    );
    expect(field.controller!.selection.baseOffset, 'accepted body'.length);

    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();
    expect(find.text('accepted body'), findsOneWidget);

    await tester.tap(find.text('Write'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('markdownInput')))
          .controller!
          .text,
      'accepted body',
      reason: 'Preview never mutates the source',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('markdownInput')))
          .controller!
          .selection
          .baseOffset,
      'accepted body'.length,
      reason: 'a normal save leaves the cursor alone',
    );
  });

  testWidgets('the editor scrolls and stays usable at 360 with 2x text', (
    tester,
  ) async {
    await openVault(tester);
    final note = session.data!.notes.single.copyWith(
      markdown: List.filled(40, '# Section heading').join('\n\n'),
    );
    await io(tester, () => session.saveNote(note));
    await pumpEditor(tester, size: const Size(360, 640), textScale: 2);

    expect(find.byKey(const ValueKey('markdownInput')), findsOneWidget);
    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();
    expect(find.text('Section heading'), findsWidgets);
    expect(tester.takeException(), isNull);
    await settleSave(tester);
  });
}
