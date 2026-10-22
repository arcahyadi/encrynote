import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hello_flutter/lock/privacy_signals.dart';

/// The semantic "user edited something" signal.
///
/// Soft-keyboard input reaches Flutter only through the text-input channel, so
/// this signal is how a field reports a real edit. The distinction that matters:
/// a programmatic controller update, a rebuild or an autosave is not a user
/// edit and must never report.
void main() {
  late PrivacySignal activity;
  late PrivacySignal leavings;
  late int reports;

  setUp(() {
    reports = 0;
    activity = PrivacySignal()..addListener(() => reports++);
    leavings = PrivacySignal();
  });

  tearDown(() {
    activity.dispose();
    leavings.dispose();
  });

  Widget wrap(Widget child, {bool withScope = true}) {
    final app = MaterialApp(home: Material(child: child));
    if (!withScope) return app;
    return PrivacySignals(activity: activity, leavings: leavings, child: app);
  }

  testWidgets('a real text-input edit reports activity', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      wrap(
        TextField(
          controller: controller,
          onChanged: (_) => PrivacySignals.reportActivity(
            tester.element(find.byType(TextField)),
          ),
        ),
      ),
    );

    await tester.showKeyboard(find.byType(TextField));
    tester.testTextInput.enterText('hunter2');
    await tester.pump();

    expect(controller.text, 'hunter2');
    expect(reports, 1, reason: 'one real edit, one report');
  });

  testWidgets('programmatic updates and rebuilds never report', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    late StateSetter rebuild;

    await tester.pumpWidget(
      wrap(
        StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return TextField(
              controller: controller,
              onChanged: (_) => PrivacySignals.reportActivity(context),
            );
          },
        ),
      ),
    );

    // Autosave-style edits: the controller is written without user input.
    controller.text = 'sealed automatically';
    await tester.pump();
    controller.value = const TextEditingValue(text: 'restored from disk');
    await tester.pump();
    rebuild(() {});
    await tester.pump();

    expect(controller.text, 'restored from disk');
    expect(reports, 0, reason: 'no user input happened');
  });

  testWidgets('reporting without a scope is a harmless no-op', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      wrap(
        TextField(
          controller: controller,
          onChanged: (_) => PrivacySignals.reportActivity(
            tester.element(find.byType(TextField)),
          ),
        ),
        withScope: false,
      ),
    );

    await tester.showKeyboard(find.byType(TextField));
    tester.testTextInput.enterText('typed');
    await tester.pump();

    expect(controller.text, 'typed');
    expect(reports, 0);
    expect(tester.takeException(), isNull);
  });
}
