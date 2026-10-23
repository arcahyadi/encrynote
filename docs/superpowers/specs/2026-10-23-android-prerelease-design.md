# Android development release

## Intent and approval

The user requests an installable, non-debug APK on the public EnCryNote GitHub
repository and accepts a development/pre-release. They explicitly approved
creating a new release signing key locally, keeping it out of GitHub, and
backing it up for later updates. No existing release keystore or
`android/key.properties` was found in this project.

## Proposed delivery

- Version `1.0.0-dev.1+1`, Git tag `v1.0.0-dev.1`, GitHub **pre-release**.
- One universal APK, built in release mode and signed by a newly generated
  release key, not the Android debug certificate. Attach the APK and SHA-256
  checksum only; do not publish keys, passwords, or signing configuration.
- Keep the existing application id and app behavior. A debug-signed installed
  copy cannot be updated in place with the new certificate; users must export
  their notes before considering a reinstall. Do not install or uninstall on
  anyone's behalf.
- Store `android/app/encrynote-release.jks` and `android/key.properties` locally
  with restrictive permissions, using existing ignore rules. Generate strong
  passwords without displaying them or placing them on a command line. Never
  overwrite an existing key or credential file.
- Document safe local signing setup and backup. Future updates must retain the
  signing key and use a higher Android version code.

## Approach and limits

A dedicated local release key meets the request. Retaining the debug signer
does not, and Play Store signing/distribution is outside scope. Use existing
Flutter/Gradle/Android SDK tools, without new dependencies or CI automation.

Release builds must not fall back to debug signing when credentials are absent.
Contributor debug builds and host tests must remain usable without release
credentials. Preserve offline permissions, backup exclusions, native file
boundaries, license delivery, recovery behavior, and all existing tests.

Signing proves artifact identity, not production readiness. Physical low-end
Android KDF measurements, real picker/device lifecycle validation, and the
remaining manual security checks stay unverified and must be stated in the
pre-release notes. Publish no stable/production-readiness claim.
