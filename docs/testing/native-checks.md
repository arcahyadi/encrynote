# Native and release checks

This file records what was actually run for EnCryNote v1, on which device and
build mode, and what was **not** run. A check that could not be performed is
written as `Not run` with the reason — never as PASS.

Records dated 2026-10-23 (fix round 1). Host: macOS 27.0.1 (arm64). Android:
emulator `Medium_Phone_API_37.0`, Android 17 / API 37, arm64 (`emulator-5554`).
Archived command output for each run below lives in
`.superpowers/sdd/encrynote-20261022/` (`fix1-*.log`).

## How to run each check

Every command below is copy-pasteable from the repository root. `build/` is
generated, not committed; run the build first.

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

The rule files are compiled and their resource names obfuscated, so resolve the
name from the resource table first, then dump that exact file:

```sh
AAPT=$(ls $ANDROID_HOME/build-tools/*/aapt2 | tail -1)
"$AAPT" dump resources build/app/outputs/flutter-apk/app-release.apk \
  | grep -A2 'xml/backup_rules'
# → resource 0x7f0e0000 xml/backup_rules ... (file) res/<name>.xml
"$AAPT" dump xmltree --file res/<name>.xml \
  build/app/outputs/flutter-apk/app-release.apk
```

Repeat for `xml/data_extraction_rules`. The recorded run resolved
`res/Qq.xml` and `res/4j.xml`; those names are build-specific and must not be
reused for a different build.

### Release entitlements (macOS)

```sh
flutter build macos --release
codesign -d --entitlements :- \
  build/macos/Build/Products/Release/EnCryNote.app
codesign -dv build/macos/Build/Products/Release/EnCryNote.app
```

The release entitlement source (`macos/Runner/Release.entitlements`) has the
sandbox and the user-selected file grant only, and no network client or server
key. The debug build (`DebugProfile.entitlements`) keeps `network.server` for
the Dart VM service. Read the *sealed* entitlements from the built bundle as
above; the source file alone does not prove what codesign sealed, and the
sealed output must be archived with the run.

### Integration flows

```sh
flutter test integration_test/encrynote_flow_test.dart -d macos
flutter test integration_test/encrynote_flow_test.dart -d <android-device-id>
flutter test integration_test/storage_platform_test.dart -d <device-id>
flutter test integration_test/privacy_platform_test.dart -d <device-id>
flutter test integration_test/transfer_platform_test.dart -d <device-id>
flutter test integration_test/crypto_platform_test.dart -d <device-id>
```

`flutter test` on an integration test installs the app and **uninstalls it
afterwards by default** (`--uninstall` defaults to true; pass `--no-uninstall`
to keep it). That matters only if you want to pull a file out of the app's
private directory afterwards; the app is debuggable, so `adb run-as` works while
it is installed.

The flow test is **service-level**: it drives `NoteSession`, `VaultStore`,
`VaultCrypto` and `TransferService` with the real native commit channel. It
pumps no widget tree, so it is not UI coverage; the UI path is separately
`Not run` (see below).

AOT/profile runtime (not build-only):

```sh
flutter drive --driver=test_driver/integration_test.dart \
  --target=integration_test/encrynote_flow_test.dart -d <device-id> --profile
```

### Android ↔ macOS export exchange

The flow test writes an export into a directory this run owns and prints it as
a path plus base64. The base64 line is convenience for moving a ciphertext
artifact through a test log; it is not a product path, and the file still opens
only with its export password. The run deletes its own directories in
`tearDownAll`.

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
   `recovery` or `passwordWrap` header. The bridge in this test is a **test
   double** for the OS picker: it reads a file path with a bounded stream, so it
   proves the flow above the bridge, not the native grant or the native reader.

The OS file picker itself is still a human-driven panel; the exchange replaces
only the dialog, never the crypto or the store.

## What was run (fix round 1)

Every row below has a matching log in
`.superpowers/sdd/encrynote-20261022/fix1-*.log`; the counts are those in the
logs, not re-typed from memory.

| Area | Device / OS | Build | Result | Log |
| --- | --- | --- | --- | --- |
| Unit + widget suite | macOS 27.0.1 | debug-JIT | See the report for the final count | `fix1-suite.log` |
| Project contract test (18 tests) | macOS 27.0.1 | debug-JIT | Pass | `fix1-contract.log` |
| Service-level flow: setup → write → lock → unlock → recovery → export → import | macOS 27.0.1 | debug-JIT | Pass | `fix1-flow-macos.log` |
| Service-level flow, same case | Android emulator API 37 | debug-JIT | Pass | `fix1-flow-android.log` |
| Service-level flow (AOT) | macOS 27.0.1 | profile-AOT | Pass | `fix1-flow-macos-profile.log` |
| Service-level flow (AOT) | Android emulator API 37 | profile-AOT | Pass | `fix1-flow-android-profile.log` |
| Android → macOS exchange | macOS imports an Android export | debug-JIT | Pass | `fix1-exchange-android-to-macos.log` |
| macOS → Android exchange | Android imports a macOS export | debug-JIT | Pass | `fix1-exchange-macos-to-android.log` |
| Plaintext scan of this run's own vault/exchange/cache dirs | macOS / Android | debug-JIT | Pass | in the flow logs |
| Storage commit + rollback | macOS + Android emulator | debug-JIT | Pass | `fix1-platform-suites.log` |
| Privacy cover + focus stream | macOS + Android emulator | debug-JIT | Pass | `fix1-platform-suites.log` |
| Transfer channel / unknown handle | macOS + Android emulator | debug-JIT | Pass | `fix1-platform-suites.log` |
| Crypto profile | macOS + Android emulator | debug-JIT | Pass | `fix1-platform-suites.log` |
| Release APK permissions | — | `flutter build apk --release` | Pass: no INTERNET, no network state | `fix1-artifact-checks.log` |
| Release APK compiled backup rules | — | release APK | Pass: every domain excluded in each section | `fix1-artifact-checks.log` |
| Release macOS sealed entitlements | — | `flutter build macos --release` | Pass: sandbox + user-selected files + development `get-task-allow`; no network | `fix1-artifact-checks.log` |
| Release APK target | — | release APK | `lib/main.dart` is the release entry point (build log) | `fix1-apk-build.log` |
| Offline operation | Android emulator, airplane mode, `ping` unreachable | debug-JIT | Pass; connectivity restored afterwards | `fix1-offline.log` |

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
  was not allowed. The channel contract and the unknown-handle refusal are
  covered; the panel's own cancel/error GUI branches and a real selected-file
  grant are not.
- **Native bounded-read / size-limit path**: the flow test's bridge bounds its
  own stream, but no automated test supplies a real native grant or a
  real over-limit picked file. Treat the native `readBounded` implementations as
  code-reviewed, not runtime-verified.
- **UI-level integration**: the flow test is service-level and pumps no widgets.
  The UI path (setup form, editor, dialogs) is covered by widget tests only.
- **macOS visual verification**: no screen capture or accessibility inspection of
  the running macOS window was possible here. Light/dark and text scale are
  covered by widget tests, not by a look at the built macOS app.
- **OS task-snapshot inspection**: the native cover is exercised through the real
  channel and the raster-frame gate is tested, but the compositor's snapshot
  itself cannot be observed from inside the app. The cover is a design intent,
  not an observed guarantee.
- **All four lock durations and sleep/resume on a device**: covered by the
  controllable-clock unit tests (`test/lock/`), not by waiting on the emulator.
  `Immediately` on focus loss is covered against the real channel.
- **Keyboard/focus traversal by hand on a device**: covered by widget tests only.
- **Backup upload/restore with a cloud account**: excluded by configuration and
  verified in the merged artifact; the OS behaviour was not exercised with an
  account (that needs network and a user account).
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

## Process safety note

An earlier round used a broad `pgrep -f <name> | xargs kill` probe to stop a
diagnostic process and killed Gradle's AOT snapshotter children instead, wasting
two builds. Do not kill by process name. Target a PID or process group you
started yourself, and keep its handle.
