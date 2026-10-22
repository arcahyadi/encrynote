import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hello_flutter/app.dart';
import 'package:hello_flutter/session/note_session.dart';
import 'package:hello_flutter/vault/vault_crypto.dart';
import 'package:hello_flutter/vault/vault_store.dart';

import 'support/fake_native_bridge.dart';

/// Smoke test: the app boots into the English EnCryNote setup flow.
///
/// Detailed setup/unlock/recovery coverage lives in
/// `test/auth/auth_screen_test.dart`.
void main() {
  late Directory scratchRoot;

  setUpAll(() async {
    scratchRoot = await Directory(
      '${Directory.current.path}/.dart_tool/test_scratch/widget_smoke/'
      '${DateTime.now().microsecondsSinceEpoch}',
    ).create(recursive: true);
  });

  tearDownAll(() async {
    if (await scratchRoot.exists()) await scratchRoot.delete(recursive: true);
  });

  testWidgets('the app boots into the English setup flow', (tester) async {
    final dir = (await tester.runAsync(
      () => Directory('${scratchRoot.path}/1').create(recursive: true),
    ))!;
    final session = NoteSession(
      crypto: VaultCrypto(),
      store: VaultStore(directory: dir, native: FakeNativeBridge()),
    );
    addTearDown(session.dispose);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(800, 1200);
    addTearDown(tester.view.reset);

    await tester.runAsync(session.load);
    await tester.pumpWidget(EnCryNoteApp(session: session));
    await tester.pumpAndSettle();

    expect(find.text('EnCryNote'), findsOneWidget);
    expect(find.text('Create your password'), findsOneWidget);
    expect(find.text('Recovery question 1'), findsOneWidget);
    expect(find.text('Recovery question 3'), findsOneWidget);
    expect(find.text('Recovery question 4'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
