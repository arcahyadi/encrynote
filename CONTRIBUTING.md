# Contributing to EnCryNote

Thanks for helping. This is a small offline app, and the constraints below are
part of the product, not style preferences.

## Ground rules

- No network behaviour in the application. No analytics, telemetry, update
  checks, remote fonts, remote images, or cloud sync. A change that adds a
  network dependency will be rejected even if it is convenient.
- No new plaintext path. Notes, titles, timestamps, passwords, and recovery
  answers never reach a cache, temporary file, or log.
- No silent crypto changes. The v1 suite (Argon2id 19456 KiB / 2 / 1, AES-256-GCM)
  and the size limits are fixed. Changing them needs a new documented format
  version, not an edit to the current parser.
- Keep the UI English-sourced and move every user-visible string into ARB.
- Keep the app code MIT; do not relicense a dependency or copy its text in as
  if it were ours.

## Setup

```sh
flutter pub get
flutter gen-l10n
flutter test
```

Dart `^3.13.5`; targets are Android (min SDK 24) and macOS 12.0. iOS is not part
of this version.

## Tests

Run the whole suite before opening a change:

```sh
flutter gen-l10n
dart format --output=none --set-exit-if-changed lib test integration_test
flutter analyze
flutter test
```

- Unit and widget tests live under `test/`, mirroring `lib/`.
- `test/project_contract_test.dart` checks release contracts that are easy to
  break by accident: the English ARB, the exact auto-lock labels, no network
  permission in the release configuration, Android backup exclusion per section,
  the licence, the README facts, and that every documented integration command
  passes `--no-uninstall`. Update the document and the test together.
- `integration_test/` runs against a real device or desktop and uses the real
  crypto and store. Do not replace them with fakes there.
- **Device integration runs must pass `--no-uninstall`** and must target a
  device or emulator you own or can throw away that holds **no personal vault**.
  The test build reuses the product application id
  (`com.example.hello_flutter`), and `flutter test` uninstalls that package
  afterwards by default, which deletes its whole private data directory
  (`vault.enc`, `vault.previous`). A test-owned subdirectory inside the app does
  not protect a real vault from a package uninstall.
- Tests that need scratch files create a unique directory inside the project or
  the app's private support directory and delete only what they created. Never
  point a test at a live vault.
- Prefer a test that fails first. A bug fix without a regression test is
  incomplete.

## Localization

English is the source of truth: `lib/l10n/app_en.arb` is the template named in
`l10n.yaml`, and generated code in `lib/l10n/generated/` is a build output —
regenerate it, do not hand-edit it.

To add a locale:

1. Copy `lib/l10n/app_en.arb` to `lib/l10n/app_<locale>.arb` (for example
   `app_id.arb` for Indonesian) and set `"@@locale"` to that locale code.
2. Translate every message key. Keys, placeholder names, and types must stay
   identical; only the text changes.
3. Keep ICU placeholders intact. A message such as `Delete "{title}"?` must
   keep `{title}`; `Recovery question {index}` must keep `{index}`. Reordering
   words around a placeholder is fine; renaming or dropping it is not.
4. Do not translate brand names (`EnCryNote`), file extensions
   (`.encrynote`, `.md`), or the values stored in the vault. The four auto-lock
   labels are UI text and may be translated, but the stored values
   (`immediately`, `oneMinute`, …) must not change.
5. Run `flutter gen-l10n` and commit the regenerated files.
6. Add a widget test that pumps the relevant screen under the new locale and
   checks the translated label appears, plus a check that no key falls back to
   English. `test/project_contract_test.dart` already fails if a locale file
   misses a template key or declares the wrong `@@locale`.

Do not add a language picker, a plugin system, or a translation editor. The app
follows the OS locale when a complete translation exists and falls back to
English otherwise.

## Native changes

The native boundary is `lib/platform/native_bridge.dart`: vault commit,
privacy cover, focus events, and the OS file picker. Android lives in
`android/app/src/main/kotlin/com/example/hello_flutter/`, macOS in
`macos/Runner/`. If you change the channel contract, update
`test/support/fake_native_bridge.dart` and the platform integration tests in the
same change.

Release checks that must stay true:

- the release APK has no `android.permission.INTERNET`;
- the signed macOS bundle has no network client/server entitlement and keeps
  the sandbox plus user-selected file access;
- Android backup stays disabled, and both rule files keep excluding every
  domain.

`docs/testing/native-checks.md` explains how to verify those on an artifact and
records what has actually been run. Add a row when you run a check; write
`Not run` with a reason instead of guessing.

## Security reports

There is no bug bounty and no formal audit. If you find a vulnerability, open an
issue that describes the class of problem without pasting anyone's vault,
password, or recovery answers. Do not test against data you do not own.

## Licence

By contributing you agree your contribution is licensed under the MIT licence in
[LICENSE](LICENSE) as part of EnCryNote. Dependency licences are listed in the
README and are not changed by this. The build bundles every dependency's licence
text as the `NOTICES` asset, shown in **Settings → Licences**; adding a
dependency does not require editing that page, but check that its licence is
compatible before you add it.
