import 'package:flutter/widgets.dart';

/// One named signal, reported by whoever owns the real event.
///
/// No payload: neither a credential nor a note body ever travels through here.
class PrivacySignal extends ChangeNotifier {
  void report() => notifyListeners();
}

/// The two user-intent signals the privacy lifecycle consumes.
///
/// [activity] is a real user edit. Soft-keyboard input never reaches a pointer
/// or `HardwareKeyboard` handler: Android IME keystrokes arrive on the
/// text-input channel and IME taps go to the IME window. Text fields and the
/// editor therefore report their own edits. A programmatic controller update,
/// an autosave or a rebuild must never report.
///
/// [leavings] fires once per time the app was left while the saved policy is
/// Immediately, so a form can drop typed secrets even when the session is
/// already locked and has no key to flush.
class PrivacySignals extends InheritedWidget {
  const PrivacySignals({
    super.key,
    required this.activity,
    required this.leavings,
    required super.child,
  });

  final PrivacySignal activity;
  final PrivacySignal leavings;

  static PrivacySignals? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<PrivacySignals>();

  /// Reports one real user edit. A no-op when no lifecycle is mounted, which is
  /// why a screen can be pumped on its own in a widget test.
  static void reportActivity(BuildContext context) =>
      maybeOf(context)?.activity.report();

  @override
  bool updateShouldNotify(PrivacySignals oldWidget) =>
      oldWidget.activity != activity || oldWidget.leavings != leavings;
}
