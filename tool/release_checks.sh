#!/bin/sh
# Release artifact checks for EnCryNote. Run from the repository root after
# `flutter build apk --release` and `flutter build macos --release`.
#
# Prints the merged Android manifest facts, the compiled backup rule contents,
# the sealed macOS entitlements, and the release entry point. Every section is
# labelled so the archived output is self-explanatory.
set -u

APK=build/app/outputs/flutter-apk/app-release.apk
APP=build/macos/Build/Products/Release/EnCryNote.app
ANDROID_HOME=${ANDROID_HOME:-$HOME/Library/Android/sdk}
# The apkanalyzer launcher needs a JDK. An inherited JAVA_HOME here points at a
# JDK that no longer exists, so use the Android Studio JBR unless it is valid.
if [ ! -x "${JAVA_HOME:-}/bin/java" ]; then
  JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
fi
export JAVA_HOME
echo "JAVA_HOME=$JAVA_HOME"
"$JAVA_HOME/bin/java" -version 2>&1 | head -1

echo "== apk: $APK"
ls -l "$APK" || exit 1
echo "== apk sha256"
shasum -a 256 "$APK"
echo "== apk permissions"
"$ANDROID_HOME/cmdline-tools/latest/bin/apkanalyzer" manifest permissions "$APK"
echo "== apk min/target sdk"
"$ANDROID_HOME/cmdline-tools/latest/bin/apkanalyzer" manifest min-sdk "$APK"
"$ANDROID_HOME/cmdline-tools/latest/bin/apkanalyzer" manifest target-sdk "$APK"
echo "== apk backup attributes"
"$ANDROID_HOME/cmdline-tools/latest/bin/apkanalyzer" manifest print "$APK" \
  | grep -E 'allowBackup|fullBackupContent|dataExtractionRules'
echo "== apk network permission / service search (must be empty)"
"$ANDROID_HOME/cmdline-tools/latest/bin/apkanalyzer" manifest print "$APK" \
  | grep -E 'permission.INTERNET|ACCESS_NETWORK_STATE|usesCleartextTraffic|<service' \
  || echo "(none)"

AAPT=$(ls "$ANDROID_HOME"/build-tools/*/aapt2 | tail -1)
echo "== compiled backup rule resource names"
"$AAPT" dump resources "$APK" | grep -A2 'xml/backup_rules\|xml/data_extraction_rules'
echo "== compiled backup rules (full-backup-content)"
BACKUP_XML=$("$AAPT" dump resources "$APK" \
  | awk '/xml\/backup_rules/{found=1; next} found && /\(file\)/{print $3; exit}')
echo "res file: $BACKUP_XML"
"$AAPT" dump xmltree --file "$BACKUP_XML" "$APK"
echo "== compiled extraction rules (cloud-backup + device-transfer)"
EXTRACT_XML=$("$AAPT" dump resources "$APK" \
  | awk '/xml\/data_extraction_rules/{found=1; next} found && /\(file\)/{print $3; exit}')
echo "res file: $EXTRACT_XML"
"$AAPT" dump xmltree --file "$EXTRACT_XML" "$APK"

echo "== app bundle: $APP"
ls -d "$APP" || exit 1
echo "== sealed entitlements"
codesign -d --entitlements :- "$APP" 2>&1
echo "== signature"
codesign -dv "$APP" 2>&1 | head -10
echo "== minimum system version"
plutil -p "$APP/Contents/Info.plist" | grep -E 'LSMinimumSystemVersion|CFBundleName'

echo "== bundled third-party notices"
NOTICES=$(find "$APP/Contents/Frameworks" -name 'NOTICES*' 2>/dev/null | head -3)
echo "$NOTICES"
if [ -n "$NOTICES" ]; then
  for f in $NOTICES; do ls -l "$f"; done
fi
