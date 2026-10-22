import 'package:flutter_test/flutter_test.dart';
import 'package:hello_flutter/platform/native_bridge.dart';
import 'package:integration_test/integration_test.dart';

/// Exercises the real native privacy channel on the target platform.
///
/// Usage:
///   flutter test integration_test/privacy_platform_test.dart -d macos
///   flutter test integration_test/privacy_platform_test.dart -d DEVICE_ID
///
/// This only proves the channel is wired and both directions of the shield
/// call succeed. Whether the cover is actually painted before the OS snapshot
/// is a manual check (app switcher, minimize, sleep/resume); no test here can
/// observe the system snapshot.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const native = MethodChannelNativeBridge();

  testWidgets('the native shield channel accepts show and hide', (
    tester,
  ) async {
    await native.setPrivacyShield(true);
    await native.setPrivacyShield(false);
  });

  testWidgets('the focus stream can be subscribed and cancelled', (
    tester,
  ) async {
    final events = <bool>[];
    final subscription = native.focusChanges.listen(events.add);
    await subscription.cancel();
    expect(events, isEmpty);
  });
}
