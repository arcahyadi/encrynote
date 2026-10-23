# EnCryNote

A small, fully offline notebook for Android and macOS. Every note lives in one
encrypted vault in the app's private directory (an active `vault.enc` plus the
previous generation the store keeps for rollback); there is no account, no
cloud, no telemetry, no network code, and no update check.

The UI is English (source strings in `lib/l10n/app_en.arb`). The application
code is MIT licensed — see [LICENSE](LICENSE) and
[third-party licences](#third-party-licences).

## Running it

Requires Flutter with Dart `^3.13.5`.

```sh
flutter pub get
flutter gen-l10n
flutter run -d macos
flutter run -d <android-device-id>
```

Tests and builds:

```sh
flutter test
flutter analyze
flutter build apk --release
flutter build macos --release
flutter test integration_test/encrynote_flow_test.dart -d <device-id> --no-uninstall
```

**Always pass `--no-uninstall` to an integration test on a device.** The test
build uses the product application id (`com.example.hello_flutter`), and
`flutter test` uninstalls that package afterwards by default. Uninstalling
deletes the app's private data directory, including `vault.enc` and
`vault.previous` — so a run against a phone or emulator that holds a real vault
destroys it. Use a device or emulator you own or can throw away that has **no
personal vault** on it, and never a daily-driver install. `--no-uninstall` keeps
the package (and its data) installed after the run.

The release builds use development signing only (Android debug keystore, macOS
ad-hoc/local signing). A successful local build is **not** a store-signed or
published release.

## What the app guarantees, and what it does not

- **Cold start is always locked.** Nothing resumes a session from a previous
  process: no key, password, or note content is stored for that purpose. The
  auto-lock preference is about an already-unlocked session, not a shortcut past
  the password.
- **Two ways in.** The app password, or the three recovery questions and
  answers chosen at setup. There is no third path, no recovery email, and no
  recovery key. If the password and the needed answers are both lost, the notes
  are unrecoverable.
- **Recovery questions are readable while the vault is locked.** They are stored
  as public header text so the recovery screen can show them. Do not put secrets
  in a question. Guessable answers weaken recovery; that is a limit of the
  design the user chose, not something the app can repair.
- **Answers are case-sensitive** after trimming leading and trailing spaces.
  Inner spaces and capitalisation must match exactly. Passwords are not trimmed
  and are case-sensitive.
- **Exports do not use recovery.** An `.encrynote` export is encrypted with the
  export password you type when exporting. The app password and the recovery
  answers cannot open it, and a forgotten export password cannot be recovered.
  If the original vault is still accessible you can make a new export; the old
  file stays unreadable.
- **Imported `.md` files stay plaintext outside the app.** EnCryNote stores a
  copy inside the encrypted vault and never modifies the source file. The
  original `.md` on disk, in a cloud folder, or in a backup remains readable by
  anything that can read that location.
- **There has been no formal security audit.** This is a small, deliberately simple design
  (Argon2id + AES-256-GCM, one encrypted snapshot per vault) but it has not been
  audited by a third party. Do not treat the design or the tests as a security
  guarantee.
- **No perfect zeroization.** The app drops references to keys, passwords,
  answers, and note text as soon as it can, and never writes plaintext to a
  cache or temporary file. Dart and the OS do not guarantee that every copy in
  memory is physically erased, so no zeroization claim is made.
- **No absolute crash protection.** A commit writes staged ciphertext, syncs it,
  replaces the vault, and syncs the directory; the previous generation is kept
  and restored when a replacement fails. A change that never reached a
  successful commit — for example a full disk followed by a power loss — is not
  guaranteed to survive. A failed seal keeps the vault in RAM with the key so
  the draft is not silently lost, and replaces the editor with a save-error
  screen whose **Retry** button is the only way to try again: nothing retries
  on a timer, so a draft stays unsaved until someone presses Retry. Do not
  treat "atomic" as "durable against every power loss".

## Storage, sizes, and KDF

| Limit | Value |
| --- | --- |
| One imported `.md` | 1 MiB |
| Plaintext vault payload | 8 MiB |
| Vault or export envelope | 16 MiB |

Over-limit writes are refused explicitly; nothing is truncated. The whole vault
is re-encrypted on every save, so a very large vault means a longer save; this
has not been tuned for large vaults.

The v1 crypto profile is fixed and is not negotiated: Argon2id with 19456 KiB
(19 MiB) of memory, 2 iterations, parallelism 1, 32-byte hash, a fresh 16-byte
salt per wrapper; AES-256-GCM with a 32-byte key, a fresh 12-byte nonce per
encryption, and a 16-byte tag. The parser accepts only this profile. The memory
cost is deliberate: each unlock or recovery needs roughly 19 MiB of extra RAM
while the KDF runs. It has only been measured on macOS and an Android emulator,
never on a low-end phone, so it is **not approved for release** yet — see
`docs/security/crypto-profile.md`, which also records the measured timings.

`docs/security/crypto-profile.md` records the envelope layout, AAD domains, and
measured timings.

## Platform notes

- **Android:** minimum SDK 24 (or Flutter's higher default). Automatic backup
  is disabled with `android:allowBackup="false"`, and the two rule files exclude
  the five app data domains the app actually uses (`root`, `file`, `database`,
  `sharedpref`, `external`) from legacy backup, cloud backup, and
  device-to-device transfer. Device-protected storage domains are not listed
  because the app never writes there; the manifest flag is the primary barrier.
  A backup that the OS or the user controls is outside the app's reach; any
  copy the app writes itself is always ciphertext.
- **macOS:** deployment target macOS 12.0. The app runs sandboxed with only the
  user-selected file read/write entitlement; the release entitlement enables no
  network client or server.
- The OS file picker is the only way files are read or written outside the
  private directory. Markdown preview never loads remote images, fonts, or
  stylesheets, and links are shown as selectable text rather than followed.

## Privacy behaviour

- The lock screen shows no note titles, snippets, or content.
- While the app is unlocked, leaving it with **Immediately** selected locks it at
  once; the other options count from the last user interaction, including while
  the app is in the background. The native layer covers the window with an
  opaque view while the app is not foregrounded. That cover is designed to keep
  notes out of OS task snapshots, but the compositor's snapshot was not observed
  on a device, so it is a design intent rather than a verified guarantee.
- A failed save freezes edits, import, export, and credential changes until the
  sealed snapshot is written. The session keeps the key in memory for that
  retry — the UI says the change is not saved yet rather than pretending the
  vault is locked and clean.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for tests, localization, and the native
checklist. `docs/testing/native-checks.md` records which native checks were run,
on which device and build mode, and which were not run.

## Third-party licences

The app's own code is MIT (see [LICENSE](LICENSE)). Dependencies keep their own
licences and are **not** relicensed as MIT.

Every dependency's licence text is bundled into the build by the Flutter tool as
the `NOTICES` asset (zipped to `NOTICES.Z` in release builds), which the engine
registers with `LicenseRegistry`. The app shows that text in
**Settings → Licences**, so a user of the built APK or `.app` can read the
licences they are entitled to without a developer machine or the pub cache.

Direct dependencies and their licences (versions pinned in `pubspec.lock`):

| Package | Licence |
| --- | --- |
| `flutter`, `flutter_localizations`, `flutter_test`, `integration_test` | BSD-3-Clause (Flutter Authors) |
| `flutter_lints` | BSD-3-Clause (Flutter Authors) |
| `path_provider` | BSD-3-Clause (Flutter Authors) |
| `flutter_markdown_plus` | BSD-3-Clause (Flutter Authors) |
| `characters` | BSD-3-Clause (Dart project authors) |
| `markdown` | BSD-3-Clause (Dart project authors) |
| `intl` | BSD-3-Clause (Dart project authors) |
| `cryptography` | Apache License 2.0 (dint-dev, `github.com/dint-dev/cryptography`) |
| `cupertino_icons` | MIT (Vladimir Kharlampidi) |

Transitive packages also ship code or native bindings in the bundles and are
included in the same bundled NOTICES: `jni`, `jni_flutter`, `jni_util`,
`objective_c`, `ffi`, `code_assets`, `hooks`, `path_provider_android`,
`path_provider_foundation`, `crypto`, `collection`, `meta`, `logging`, `yaml`,
`material_color_utilities`, and the rest of `pubspec.lock`. Their licence classes
are BSD-3-Clause or Apache-2.0 (`material_color_utilities` is Apache-2.0);
`yaml` is MIT with the Dart project and Kiri Wagstaff copyright lines. The exact
text for each is in the bundled NOTICES page, and `pubspec.lock` is the pinned
list.

`sky_engine` is SDK-vendored rather than a pub package and has **no** entry in
the bundled NOTICES; it is not a separately distributed work here.

The `cryptography` package's Apache-2.0 terms apply to that dependency's code
only; its use here does not change the app's MIT licence or add Apache terms to
EnCryNote's own source. Apache-2.0 §4's requirement to include a copy of the
licence is met by the bundled NOTICES asset and the in-app licence page.
