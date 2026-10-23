# EnCryNote final code verification

Recorded 2026-10-23 on branch `feat/encrynote`.

## Outcome

The eight implementation tasks and the whole-branch code review are complete.
The final scoped review reports zero open Critical or Important code findings.
This is a development-build handoff, not a formal security audit or approval for
production distribution.

The verified implementation commit is `c2d03bef1165303ee351e48c18ce1cb1e33fa171`.
Later handoff commits update documentation and checklist state only.

## Fresh coordinator checks

| Check | Command or result | Outcome |
| --- | --- | --- |
| Localization | `flutter gen-l10n` | Exit 0 |
| Format | `dart format --output=none --set-exit-if-changed lib test integration_test test_driver` | 43 files, 0 changed |
| Static analysis | `flutter analyze` | No issues |
| Full host suite | `flutter test test --no-uninstall --reporter expanded` | 305 passed, exit 0 |
| Android build | `flutter build apk --release --target=lib/main.dart` | Built successfully |
| macOS build | `flutter build macos --release --target=lib/main.dart` | Built successfully |
| Packaged policy | `./tool/release_checks.sh` | `POLICY=PASS checks=9` |

The packaged policy checks network permissions/components, disabled backup and
the section-specific exclusions, sandbox/user-selected file access, absence of
network entitlements, and third-party notices in both artifacts. It does not
certify runtime UI, hardware, or cryptographic implementation security.

Outputs:

- `build/app/outputs/flutter-apk/app-release.apk`
- `build/macos/Build/Products/Release/EnCryNote.app`

Raw command logs are local, gitignored execution artifacts under
`.superpowers/sdd/encrynote-20261022/final-coordinator-*.log`. They are not shipped
as part of the source distribution. Run the commands above to reproduce the
software checks; no device installation is needed for them.

## Final regressions

- Accepted snapshots carry the same revision through validation and sealing,
  including an edit accepted during an in-flight seal and the `9` to `10`
  boundary. Rejected input does not enter note state.
- A small metadata reserve covers ordinary revision/auto-lock growth without
  changing the v1 wire format or hard size limits. The ten-digit revision budget
  is operational headroom, not a parser cap or a guarantee for every possible
  externally crafted revision. Old prototype vaults written exactly at the raw
  cap are not migrated.
- The seal-only progress regression fails when offload is bypassed. It proves
  the event loop makes progress during sealing, not a fixed millisecond budget
  or the absence of every possible blocking prefix. Timings are diagnostics.
- Lock closes both the licence page and Settings to the authentication route.

The coordinator reproduced the old revision defect using test-owned shadow
sources, and observed the current progress test reject a copied blocking
implementation (`ticks=0`). No production file was reverted for these controls.
An initial shadow-import setup failure is explicitly excluded from the evidence.

## Validation still outstanding

- The updated seal-window integration assertion has not run on a native device.
  Earlier native/AOT/archive-exchange evidence used the previous test revision;
  it must not be represented as proof of the new assertion.
- Actual OS file-picker/save-panel interaction, a successful real selected-file
  grant and native bounded-read path, macOS visual/accessibility inspection,
  device keyboard/focus and sleep/resume checks remain unverified.
- Physical low-end Android KDF performance is unmeasured. The v1 Argon2id profile
  remains marked not approved for release.
- Compositor scanout/task snapshots, real power loss, full-disk and hostile
  filesystem behavior are not certified by the software tests.
- Android is debug-key signed; macOS is ad-hoc/development signed. Production
  signing, notarization, publication, and iOS support were not performed.

No device/install/uninstall, live-vault operation, host-network change, process
kill, merge, push or publication occurred in the final coordinator checks.
Native tests must follow the current `--no-uninstall` and disposable-target
rules in [native-checks.md](native-checks.md), never historical command defaults.

## Decisions and residual notes

See [implementation-decisions.md](implementation-decisions.md) for decisions
and their costs. Public recovery prompts, Dart memory-erasure limits, failed-seal
RAM retention behind Retry, a possible partial export destination on IO failure,
and local development identity are documented tradeoffs, not security promises.
Minor comment/state-cleanup notes remain; no further implementation wave was
started after the final scoped review.
