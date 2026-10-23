# Native and release checks

This file records what was actually run for EnCryNote v1, on which device and
build mode, and what was **not** run. A check that could not be performed is
written as `Not run` with the reason — never as PASS.

Records dated 2026-10-23. Host: macOS 27.0.1 (arm64). Android: emulator
`Medium_Phone_API_37.0`, Android 17 / API 37, arm64 (`emulator-5554`).

## How to run each check

### Release artifact permissions (Android)

```sh
flutter build apk --release
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
$ANDROID_HOME/cmdline-tools/latest/bin/apkanalyzer manifest permissions \
  build/app/outputs/flutter-apk/app-release.apk
```

The expected output contains **no** `android.permission.INTERNET` and no
`ACCESS_NETWORK_STATE`. `app-debug.apk` *does* carry `INTERNET` because the
Flutter tool needs it for hot reload; that is a development permission from
`android/app/src/debug/AndroidManifest.xml`, not a product feature.

Backup configuration as merged into the artifact:

```sh
apkanalyzer manifest print build/app/outputs/flutter-apk/app-release.apk \
  | grep -E 'allowBackup|fullBackupContent|dataExtractionRules'
```

The rule files are compiled and renamed, so read them back by resource name:

```sh
AAPT=$(ls $ANDROID_HOME/build-tools/*/aapt2 | tail -1)
"$AAPT" dump resources build/app/outputs/flutter-apk/app-release.apk \
  | grep -A2 'xml/backup_rules'
"$AAPT" dump xmltree --file <compiled name> \
  build/app/outputs/flutter-apk/app-release.apk
```

### Release entitlements (macOS)

```sh
flutter build macos --release
codesign -d --entitlements :- \
  build/macos/Build/Products/Release/EnCryNote.app
codesign -dv build/macos/Build/Products/Release/EnCryNote.app
```

Expected: `com.apple.security.app-sandbox` and
`com.apple.security.files.user-selected.read-write` only — no
`com.apple.security.network.client` and no `network.server`. The debug build
(`DebugProfile.entitlements`) keeps `network.server` for the Dart VM service;
that entitlement must not be in the release bundle.

### Integration flows

```sh
flutter test integration_test/encrynote_flow_test.dart -d macos
flutter test integration_test/encrynote_flow_test.dart -d <android-device-id>
flutter test integration_test/storage_platform_test.dart -d <device-id>
flutter test integration_test/privacy_platform_test.dart -d <device-id>
flutter test integration_test/transfer_platform_test.dart -d <device-id>
flutter test integration_test/crypto_platform_test.dart -d <device-id>
```

AOT/profile runtime (not build-only):

```sh
flutter drive --driver=test_driver/integration_test.dart \
  --target=integration_test/encrynote_flow_test.dart -d <device-id> --profile
```

### Android ↔ macOS export exchange

The flow test writes an export into its own private test directory and prints it
both as a path and as base64 (an Android test app is uninstalled when the run
ends, so its private file cannot be pulled afterwards; the base64 line is log
transport for the artifact, not a product path).

1. On the source platform run
   `flutter test integration_test/encrynote_flow_test.dart -d <source>
   --dart-define=ENCRYNOTE_MARKER=<source marker>`
   and note `EXCHANGE_EXPORT_BASE64=` in the log.
2. Put the decoded artifact somewhere the destination can read: on macOS inside
   the app container (the sandbox cannot read the project directory), on
   Android in `/data/local/tmp/`.
3. On the destination run

   ```sh
   flutter test integration_test/encrynote_flow_test.dart -d <destination> \
     --dart-define=ENCRYNOTE_IMPORT_ARTIFACT=<destination path> \
     --dart-define=ENCRYNOTE_EXPECT_MARKER=<marker from the source log>
   ```

   The second case imports the artifact into a freshly set-up vault, checks the
   marker, and asserts the file is an `export` envelope with no local
   `recovery` or `passwordWrap` header.

The OS file picker itself is still a human-driven panel; the exchange replaces
only the dialog, never the crypto or the store.

## What was run

| Area | Device / OS | Build | Result |
| --- | --- | --- | --- |
| Unit + widget suite | macOS 27.0.1 | debug-JIT (`flutter test`) | Pass, 275 tests |
| Project contract test | macOS 27.0.1 | debug-JIT | Pass, 15 tests |
| Full flow: setup → write → restart locked → unlock → recovery → export → import | macOS 27.0.1 | debug-JIT | Pass |
| Full flow, same case | Android emulator API 37 | debug-JIT | Pass |
| Full flow (AOT) | macOS 27.0.1 | profile-AOT (`flutter drive`) | Pass |
| Full flow (AOT) | Android emulator API 37 | profile-AOT (`flutter drive`) | Pass |
| Android → macOS exchange | macOS imports an Android export | debug-JIT | Pass (marker `flow-marker-android-b93c`) |
| macOS → Android exchange | Android imports a macOS export | debug-JIT | Pass (marker `flow-marker-macos-c51d`) |
| Plaintext marker scan of support + cache dirs | macOS / Android | debug-JIT | Pass, no note text, password, or question found in any app file |
| Storage commit + rollback | macOS + Android emulator | debug-JIT | Pass, 7 tests each |
| Privacy cover + focus stream | macOS + Android emulator | debug-JIT | Pass, 3 tests each |
| Transfer channel / import write | macOS + Android emulator | debug-JIT | Pass, 4 tests each |
| Crypto profile | macOS + Android emulator | debug-JIT | Pass, 1 test each |
| Release APK permissions | — | `flutter build apk --release` | Pass: only `com.example.hello_flutter.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION`; no INTERNET, no network state |
| Release APK backup config | — | release APK | Pass: `allowBackup="false"`, both rule resources present, every domain excluded in `full-backup-content` and in both `cloud-backup` and `device-transfer` |
| Release macOS entitlements | — | `flutter build macos --release` | Pass: sandbox + user-selected files only; no network client/server |
| App launches from the release APK | Android emulator API 37 | release | Observed: English setup screen, no crash in logcat |
| OS dark theme | Android emulator | release | Observed: dark surface, light text, purple accent (screenshot in the task evidence folder) |
| 2× text scale | Android emulator | release | Observed: text scales, content scrolls instead of clipping (screenshot in the task evidence folder) |
| Offline operation | Android emulator, airplane mode on, `ping 8.8.8.8` unreachable | debug-JIT | Pass: full flow and all four platform suites ran with no network; connectivity restored afterwards |

## Not run, and why

- **Physical Android device (especially low-end)**: none attached, and this task
  allows no new hardware, SDK, or AVD installation. The emulator is a
  desktop-class arm64 machine, so its Argon2id timings are not evidence for a
  low-end phone. `docs/security/crypto-profile.md` keeps the v1 KDF profile
  marked "not approved for release" until that measurement exists.
- **iOS**: out of scope for this version by design; no scaffolding added.
- **Native click-through of the OS file dialogs**: the picker is an OS panel, not
  a Flutter surface. No desktop automation tool is available in this environment
  (Orca desktop control is absent), and substituting another automation harness
  was not allowed. The channel contract, a bounded read, and the post-import
  write are covered; the panel's own cancel/error GUI branches are not.
- **macOS visual verification**: no screen capture or accessibility inspection of
  the running macOS window was possible here. Light/dark and text scale are
  covered by widget tests and by the Android release screenshots above, not by a
  look at the built macOS app.
- **OS task-snapshot inspection**: the native cover is exercised through the real
  channel and the raster-frame gate is tested, but the compositor's snapshot
  itself cannot be observed from inside the app.
- **All four lock durations and sleep/resume on a device**: covered by the
  controllable-clock unit tests (`test/lock/`), not by waiting 1/5/10 minutes on
  the emulator. `Immediately` on focus loss is covered by the privacy lifecycle
  test against the real channel.
- **Keyboard/focus traversal on a device**: covered by widget tests; not walked
  by hand on the emulator.
- **Backup upload/restore**: excluded by configuration and verified in the merged
  artifact; no cloud backup account was used to confirm the OS honours it (that
  would need a user account and network).
- **Power-loss / kill-during-write on hardware**: simulated by the store and
  native-fault tests (staged write, failed replace, rollback, previous
  generation). A real power cut is not reproduced, and durability is not claimed
  beyond a successful commit.

## Signing status

Both release builds use development identities:

- Android: `signingConfig = signingConfigs.getByName("debug")` in
  `android/app/build.gradle.kts`. The release APK is debug-signed.
- macOS: `Signature=adhoc`, `TeamIdentifier=not set`, and the sealed
  entitlements include `com.apple.security.get-task-allow` — a development
  signing artifact. The bundle is not notarized and not distribution-signed.

A local release build is therefore **not** a store-signed or published artifact.
Production signing, notarization, and publication are separate, unrequested
work.
