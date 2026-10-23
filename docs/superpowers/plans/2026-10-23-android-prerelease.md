# Android Pre-release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. All implementers and reviewers must use `kenari/deepseek-v4-1-flash#max` under the existing user constraint.

**Goal:** Publish an installable, release-signed Android development APK without distributing signing secrets.

**Architecture:** Configure local release signing in the existing Gradle app. Generate an ignored local keystore, verify the resulting APK independently, then attach only that APK and its checksum to a GitHub pre-release.

**Tech Stack:** Existing Flutter/Dart, Gradle Kotlin DSL, Java keytool, Android SDK apksigner/apkanalyzer, GitHub CLI.

**Spec:** [Android development release](../specs/2026-10-23-android-prerelease-design.md)

## Global Constraints

- Version `1.0.0-dev.1+1`; tag `v1.0.0-dev.1`; GitHub pre-release only.
- New release key stored locally; never overwrite or upload keys/passwords.
- No debug-signing fallback, dependency additions, application-id changes, new platform work, or CI automation.
- No device installation/uninstallation, live-vault operations, data deletion, or history rewriting.
- Keep all existing offline, backup, recovery, file-access and licensing contracts.
- Work in this project only; evidence belongs in the ignored `.superpowers/sdd/` workspace.
- Do not confuse signing/build success with unavailable manual/physical-device validation.

## Review Focus

- Missing signing credentials must fail a release build rather than emit a debug-signed artifact.
- A contributor without the private key must still be able to use debug builds and host tests.
- Keystore/passwords must remain ignored and absent from staged content and release assets.
- APK must be non-debuggable and have the expected version, application id and non-debug certificate.
- Replacing an installed debug-signed copy must not be advised without a note-export warning.

### Task 1: Release signing, version and documentation

**Files:** Modify `android/app/build.gradle.kts`, `pubspec.yaml`, `README.md`; add focused signing-contract checks to `test/project_contract_test.dart`. Keep new secrets only in ignored `android/key.properties` and `android/app/encrynote-release.jks`.

**Interfaces:** Local signing properties `storeFile`, `storePassword`, `keyAlias`, `keyPassword`; release artifact `build/app/outputs/flutter-apk/app-release.apk`.

- [x] Add focused contract checks for an explicit release signing configuration, no release-to-debug fallback, and ignored signing inputs. Run the contract test to record a meaningful RED against the old Gradle configuration.
- [x] Load local signing properties, configure the release signer, and make missing/invalid signing configuration fail closed for release tasks without requiring secrets for debug builds. Preserve other Gradle settings.
- [x] Generate a long-lived RSA release key with Java keytool and strong random passwords using non-interactive secret handling. Set restrictive file permissions, check ignore behavior, and record only the public certificate fingerprint. Abort if files already exist.
- [x] Set `pubspec.yaml` to `1.0.0-dev.1+1`. Update README signing/development status, local setup/backup instructions and debug-install incompatibility warning; retain all existing safety/licensing text.
- [x] Run `flutter test test/project_contract_test.dart --no-uninstall`, then the full host suite and analyzer. Verify no-key release rejection and no-key debug configuration using isolated project-owned fixtures rather than moving or deleting real key files.
- [x] Inspect staged paths and commit only non-secret configuration, tests, version and documentation. Obtain a focused independent Kenari review and resolve material findings before publication.

### Task 2: Verify and publish the APK

**Files:** Generate APK/checksum under ignored `build/`; keep exact verification logs and release notes under ignored `.superpowers/sdd/`.

**Interfaces:** Tag `v1.0.0-dev.1` points at the verified source commit; release assets contain only the universal APK and checksum.

- [x] Build `flutter build apk --release --target=lib/main.dart`. Stop on failure; do not substitute a debug APK.
- [x] Use SDK tools to verify signature integrity, non-debug signer/certificate fingerprint, `debuggable=false`, version name/code, existing application id, minimum SDK, offline permissions/backup policy and bundled notices. Record exact output without signing secrets.
- [x] Name the APK `EnCryNote-1.0.0-dev.1-android-universal.apk` and calculate its SHA-256 checksum. Record tests, signing fingerprint, installation/update warning and outstanding validation in release notes.
- [x] Push reviewed source, create the immutable version tag, and publish a GitHub pre-release on `arcahyadi/encrynote` with only the APK and checksum. If a tag/release already exists, stop rather than overwrite it.
- [x] Verify remote tag/source identity, pre-release status and asset checksum/size. Report the download URL and local signing-backup paths, never their contents.
