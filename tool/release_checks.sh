#!/bin/sh
# Release artifact checks for EnCryNote.
#
# Usage, from the repository root, after the two release builds:
#   ./tool/release_checks.sh
#
# It inspects the built artifacts and enforces the release policy:
#   - no INTERNET / network-state permission and no <service> in the APK
#   - android:allowBackup="false" plus both backup rule resources
#   - every used domain excluded in full-backup-content, cloud-backup and
#     device-transfer in the *compiled* rules
#   - no network client/server entitlement in the sealed macOS bundle
#   - the bundle really carries the third-party notices asset
#
# It exits non-zero when a required tool, artifact, or resource lookup is
# missing, and prints POLICY=PASS only when every check above passed. Without
# POLICY=PASS the run is a report, not a verdict.
#
# Environment overrides (used by the self-check test):
#   ENCRYNOTE_APK, ENCRYNOTE_APP, ENCRYNOTE_ANDROID_HOME
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

APK=${ENCRYNOTE_APK:-build/app/outputs/flutter-apk/app-release.apk}
APP=${ENCRYNOTE_APP:-build/macos/Build/Products/Release/EnCryNote.app}
ANDROID_HOME=${ENCRYNOTE_ANDROID_HOME:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}

# The apkanalyzer launcher needs a JDK. An inherited JAVA_HOME may point at a JDK
# that no longer exists, so use the Android Studio JBR unless it is valid.
if [ ! -x "${JAVA_HOME:-}/bin/java" ]; then
  JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
fi
export JAVA_HOME

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require() {
  command -v "$1" >/dev/null 2>&1 || fail "required tool not found on PATH: $1"
}

echo "JAVA_HOME=$JAVA_HOME"
"$JAVA_HOME/bin/java" -version 2>&1 | head -1

APKANALYZER="$ANDROID_HOME/cmdline-tools/latest/bin/apkanalyzer"
[ -x "$APKANALYZER" ] || fail "apkanalyzer not found at $APKANALYZER"
[ -f "$APK" ] || fail "release APK not found at $APK"
[ -d "$APP" ] || fail "release app not found at $APP"

require codesign
require plutil
require shasum
require unzip
require python3

# aapt2 lives in the SDK build-tools, not usually on PATH.
if command -v aapt2 >/dev/null 2>&1; then
  AAPT=$(command -v aapt2)
else
  AAPT=$(ls "$ANDROID_HOME"/build-tools/*/aapt2 2>/dev/null | tail -1 || true)
  [ -n "$AAPT" ] || fail "aapt2 not found on PATH or under $ANDROID_HOME/build-tools"
fi
[ -x "$AAPT" ] || fail "aapt2 is not executable: $AAPT"

echo "== apk: $APK"
ls -l "$APK"
echo "== apk sha256"
shasum -a 256 "$APK"

PERMISSIONS=$("$APKANALYZER" manifest permissions "$APK") \
  || fail "apkanalyzer manifest permissions failed"
MANIFEST=$("$APKANALYZER" manifest print "$APK") \
  || fail "apkanalyzer manifest print failed"

echo "== apk permissions"
printf '%s\n' "$PERMISSIONS"
echo "== apk min/target sdk"
"$APKANALYZER" manifest min-sdk "$APK" || fail "min-sdk lookup failed"
"$APKANALYZER" manifest target-sdk "$APK" || fail "target-sdk lookup failed"

echo "== apk backup attributes"
printf '%s\n' "$MANIFEST" | grep -E 'allowBackup|fullBackupContent|dataExtractionRules' \
  || fail "no backup attributes found in the merged manifest"

echo "== compiled backup rule resources"
RESOURCES=$("$AAPT" dump resources "$APK") || fail "aapt2 dump resources failed"
printf '%s\n' "$RESOURCES" | grep -A2 'xml/backup_rules\|xml/data_extraction_rules' \
  || fail "backup rule resources are missing from the APK"

BACKUP_XML=$(printf '%s\n' "$RESOURCES" \
  | awk '/xml\/backup_rules/{found=1; next} found && /\(file\)/{print $3; exit}')
[ -n "$BACKUP_XML" ] || fail "could not resolve the compiled backup_rules resource"
EXTRACT_XML=$(printf '%s\n' "$RESOURCES" \
  | awk '/xml\/data_extraction_rules/{found=1; next} found && /\(file\)/{print $3; exit}')
[ -n "$EXTRACT_XML" ] || fail "could not resolve the compiled data_extraction_rules resource"

echo "== compiled backup rules (full-backup-content)"
echo "res file: $BACKUP_XML"
BACKUP_RULES=$("$AAPT" dump xmltree --file "$BACKUP_XML" "$APK") \
  || fail "aapt2 dump xmltree failed for $BACKUP_XML"
printf '%s\n' "$BACKUP_RULES"
echo "== compiled extraction rules (cloud-backup + device-transfer)"
echo "res file: $EXTRACT_XML"
EXTRACT_RULES=$("$AAPT" dump xmltree --file "$EXTRACT_XML" "$APK") \
  || fail "aapt2 dump xmltree failed for $EXTRACT_XML"
printf '%s\n' "$EXTRACT_RULES"

echo "== sealed entitlements"
ENTITLEMENTS=$(codesign -d --entitlements :- "$APP" 2>&1) \
  || fail "codesign entitlements read failed"
printf '%s\n' "$ENTITLEMENTS"
echo "== signature"
codesign -dv "$APP" 2>&1 | head -10 || fail "codesign -dv failed"
echo "== minimum system version"
plutil -p "$APP/Contents/Info.plist" | grep -E 'LSMinimumSystemVersion|CFBundleName' \
  || fail "Info.plist keys missing"

echo "== bundled third-party notices"
NOTICES=$(find "$APP/Contents/Frameworks" -name 'NOTICES*' 2>/dev/null | head -1 || true)
[ -n "$NOTICES" ] || fail "no bundled NOTICES asset in $APP"
ls -l "$NOTICES"
NOTICES_TEXT=$(unzip -p "$APK" assets/flutter_assets/NOTICES.Z | python3 -c '
import sys, zlib
text = zlib.decompress(sys.stdin.buffer.read(), 47).decode("utf-8", "replace")
print(len(text))
print("true" if "cryptography" in text else "false")
print("true" if "Apache License" in text else "false")
') || fail "could not read the bundled NOTICES asset"
NOTICES_CHARS=$(printf '%s\n' "$NOTICES_TEXT" | sed -n 1p)
NOTICES_CRYPTO=$(printf '%s\n' "$NOTICES_TEXT" | sed -n 2p)
NOTICES_APACHE=$(printf '%s\n' "$NOTICES_TEXT" | sed -n 3p)
echo "notices chars: $NOTICES_CHARS cryptography=$NOTICES_CRYPTO apache=$NOTICES_APACHE"

# --- policy ---------------------------------------------------------------
FAILURES=0
check() {
  description=$1
  shift
  if "$@"; then
    echo "ok: $description"
  else
    echo "FAIL: $description"
    FAILURES=$((FAILURES + 1))
  fi
}

has_no_network_permission() {
  ! printf '%s\n' "$PERMISSIONS" | grep -qE 'android\.permission\.INTERNET|ACCESS_NETWORK_STATE'
}

has_no_service_or_cleartext() {
  ! printf '%s\n' "$MANIFEST" | grep -qE '<service|usesCleartextTraffic'
}

backup_disabled() {
  printf '%s\n' "$MANIFEST" | grep -q 'android:allowBackup="false"' &&
    printf '%s\n' "$MANIFEST" | grep -q 'fullBackupContent="@ref/' &&
    printf '%s\n' "$MANIFEST" | grep -q 'dataExtractionRules="@ref/'
}

# Every domain the app uses must be excluded inside one named section.
# aapt2 prints `E: <section> (line=N)` and `E: exclude` under it, so the
# section name appears without angle brackets.
section_excludes_all() {
  rules=$1
  section=$2
  body=$(printf '%s\n' "$rules" | awk -v s="$section" '
    $0 ~ "^[ \t]*E: " s " " { inside = 1; next }
    $0 ~ "^[ \t]*E: [a-z]" && $0 !~ "exclude" { if (inside) inside = 0 }
    inside' )
  [ -n "$body" ] || return 1
  for domain in root file database sharedpref external; do
    printf '%s\n' "$body" | grep -q "domain=\"$domain\"" || return 1
  done
}

top_level_excludes_all() {
  for domain in root file database sharedpref external; do
    printf '%s\n' "$BACKUP_RULES" | grep -q "domain=\"$domain\"" || return 1
  done
}

no_network_entitlement() {
  ! printf '%s\n' "$ENTITLEMENTS" \
    | grep -qE 'com\.apple\.security\.network\.(client|server)'
}

sandbox_kept() {
  printf '%s\n' "$ENTITLEMENTS" | grep -q 'com.apple.security.app-sandbox' &&
    printf '%s\n' "$ENTITLEMENTS" \
      | grep -q 'com.apple.security.files.user-selected.read-write'
}

notices_present() {
  [ "${NOTICES_CRYPTO:-false}" = "true" ] &&
    [ "${NOTICES_APACHE:-false}" = "true" ] &&
    [ "${NOTICES_CHARS:-0}" -gt 100000 ]
}

echo "== policy"
check "APK declares no INTERNET or network-state permission" has_no_network_permission
check "APK manifest has no <service> and no cleartext traffic" has_no_service_or_cleartext
check "allowBackup is false and both rule resources are referenced" backup_disabled
check "full-backup-content excludes every used domain" top_level_excludes_all
check "cloud-backup excludes every used domain" section_excludes_all "$EXTRACT_RULES" cloud-backup
check "device-transfer excludes every used domain" section_excludes_all "$EXTRACT_RULES" device-transfer
check "sealed bundle has no network client/server entitlement" no_network_entitlement
check "sealed bundle keeps sandbox and user-selected file access" sandbox_kept
check "bundled notices carry the third-party licence texts" notices_present

if [ "$FAILURES" -ne 0 ]; then
  echo "POLICY=FAIL failures=$FAILURES"
  exit 1
fi
echo "POLICY=PASS checks=9"
