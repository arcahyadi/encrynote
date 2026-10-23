import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A stand-in NOTICES asset long enough to look like a real one, containing the
/// two licence classes the script requires.
final String _fakeNotices =
    'abseil-cpp\n\nApache License\nVersion 2.0\n${'x' * 60000}\n'
    '${'-' * 80}\ncryptography\n\nApache License\nVersion 2.0\n${'y' * 60000}';

/// Self-checks for `tool/release_checks.sh`.
///
/// The script is the only thing that inspects a built release artifact, so a
/// silent pass is dangerous: it would report "no network permission" because a
/// tool failed, not because the artifact is clean. These tests run the real
/// script against test-owned stubs (no device, no SDK, no network) and against
/// the real local build when one exists.
void main() {
  final root = Directory.current.path;
  final script = '$root/tool/release_checks.sh';
  final stubRoot = Directory(
    '${Directory.current.path}/.dart_tool/test_scratch/release_checks/'
    '${DateTime.now().microsecondsSinceEpoch}',
  );

  setUpAll(() async {
    await stubRoot.create(recursive: true);
  });

  tearDownAll(() async {
    if (await stubRoot.exists()) await stubRoot.delete(recursive: true);
  });

  /// A throwaway project layout plus stubs, so a failing tool can be simulated.
  Future<Directory> makeFixture({
    required bool toolsExist,
    String permissions = 'io.github.arcahyadi.encrynote.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION',
    String manifest = '''
        android:allowBackup="false"
        android:fullBackupContent="@ref/0x7f0e0000"
        android:dataExtractionRules="@ref/0x7f0e0001"''',
    String networkGrep = '',
    String backupRules = '''
E: full-backup-content (line=7)
    E: exclude (line=8)
      A: domain="root" (Raw: "root")
      A: path="." (Raw: ".")
    E: exclude (line=9)
      A: domain="file" (Raw: "file")
      A: path="." (Raw: ".")
    E: exclude (line=10)
      A: domain="database" (Raw: "database")
      A: path="." (Raw: ".")
    E: exclude (line=11)
      A: domain="sharedpref" (Raw: "sharedpref")
      A: path="." (Raw: ".")
    E: exclude (line=12)
      A: domain="external" (Raw: "external")
      A: path="." (Raw: ".")
''',
    String extractionRules = '''
E: data-extraction-rules (line=7)
    E: cloud-backup (line=8)
        E: exclude (line=9)
          A: domain="root" (Raw: "root")
          A: path="." (Raw: ".")
        E: exclude (line=10)
          A: domain="file" (Raw: "file")
          A: path="." (Raw: ".")
        E: exclude (line=11)
          A: domain="database" (Raw: "database")
          A: path="." (Raw: ".")
        E: exclude (line=12)
          A: domain="sharedpref" (Raw: "sharedpref")
          A: path="." (Raw: ".")
        E: exclude (line=13)
          A: domain="external" (Raw: "external")
          A: path="." (Raw: ".")
    E: device-transfer (line=15)
        E: exclude (line=16)
          A: domain="root" (Raw: "root")
          A: path="." (Raw: ".")
        E: exclude (line=17)
          A: domain="file" (Raw: "file")
          A: path="." (Raw: ".")
        E: exclude (line=18)
          A: domain="database" (Raw: "database")
          A: path="." (Raw: ".")
        E: exclude (line=19)
          A: domain="sharedpref" (Raw: "sharedpref")
          A: path="." (Raw: ".")
        E: exclude (line=20)
          A: domain="external" (Raw: "external")
          A: path="." (Raw: ".")
''',
    String entitlements = 'com.apple.security.app-sandbox com.apple.security.files.user-selected.read-write',
    bool bundleNoticesValid = true,
  }) async {
    final dir = Directory(
      '${stubRoot.path}/fixture_${DateTime.now().microsecondsSinceEpoch}',
    );
    await dir.create(recursive: true);
    Directory('${dir.path}/EnCryNote.app').createSync(recursive: true);
    // A real notices asset for both the bundle and the APK: the script checks
    // that the licence text actually shipped, so the stub must carry it.
    final noticesDir = Directory(
      '${dir.path}/EnCryNote.app/Contents/Frameworks/App.framework/Resources',
    )..createSync(recursive: true);
    final notices = <int>[];
    notices.addAll(gzip.encode(utf8.encode(_fakeNotices)));
    final bundleNotices = bundleNoticesValid
        ? notices
        : gzip.encode(utf8.encode('no licence text here'));
    File('${noticesDir.path}/NOTICES.Z').writeAsBytesSync(bundleNotices);
    // A real zip, so the script's `unzip -p` of the notices asset works.
    File('${dir.path}/notices.z').writeAsBytesSync(notices);
    final zipSource = Directory(
      '${dir.path}/apk_contents/assets/flutter_assets',
    )..createSync(recursive: true);
    File('${zipSource.path}/NOTICES.Z').writeAsBytesSync(notices);
    final zip = Process.runSync('zip', [
      '-q',
      '-r',
      '${dir.path}/app-release.apk',
      'assets',
    ], workingDirectory: '${dir.path}/apk_contents');
    expect(zip.exitCode, 0, reason: '${zip.stdout}${zip.stderr}');
    // `zip -r` appends to an existing file; the 64-byte placeholder above makes
    // that invalid, so write the archive to a temp name first.

    final bin = Directory('${dir.path}/bin')..createSync();
    // apkanalyzer is resolved from ANDROID_HOME, so the fixture supplies its own
    // Android home with the same layout rather than relying on the real SDK.
    final androidBin = Directory('${dir.path}/android/cmdline-tools/latest/bin')
      ..createSync(recursive: true);
    // apkanalyzer stub: answers from files the test controls.
    File('${androidBin.path}/apkanalyzer').writeAsStringSync('''
#!/bin/sh
case "\$1 \$2" in
  "manifest permissions") cat "${dir.path}/permissions.txt" ;;
  "manifest min-sdk") echo 24 ;;
  "manifest target-sdk") echo 36 ;;
  "manifest print") cat "${dir.path}/manifest.txt" ;;
  *) echo "unexpected apkanalyzer \$*" >&2; exit 2 ;;
esac
''');
    Process.runSync('chmod', ['+x', '${androidBin.path}/apkanalyzer']);
    File('${bin.path}/aapt2').writeAsStringSync('''
#!/bin/sh
case "\$1" in
  dump)
    case "\$2" in
      resources)
        echo "    resource 0x7f0e0000 xml/backup_rules"
        echo "      () (file) res/Qq.xml type=XML"
        echo "    resource 0x7f0e0001 xml/data_extraction_rules"
        echo "      () (file) res/4j.xml type=XML"
        ;;
      xmltree)
        case "\$4" in
          res/Qq.xml) cat "${dir.path}/backup_rules.txt" ;;
          res/4j.xml) cat "${dir.path}/extraction_rules.txt" ;;
          *) echo "unexpected xmltree file \$4" >&2; exit 2 ;;
        esac
        ;;
      *) echo "unexpected aapt2 \$*" >&2; exit 2 ;;
    esac
    ;;
  *) echo "unexpected aapt2 \$*" >&2; exit 2 ;;
esac
''');
    File('${bin.path}/codesign').writeAsStringSync('''
#!/bin/sh
echo '<?xml version="1.0"?><plist><dict>${entitlements.replaceAll('"', '\\"')}</dict></plist>'
''');
    File('${bin.path}/plutil').writeAsStringSync('''
#!/bin/sh
echo '  "CFBundleName" => "EnCryNote"'
echo '  "LSMinimumSystemVersion" => "12.0"'
''');
    for (final tool in ['apkanalyzer', 'aapt2', 'codesign', 'plutil']) {
      Process.runSync('chmod', ['+x', '${bin.path}/$tool']);
    }
    if (!toolsExist) {
      // Simulate a missing required tool: the script must fail, not pass.
      File('${bin.path}/aapt2').deleteSync();
    }

    File('${dir.path}/permissions.txt').writeAsStringSync('$permissions\n');
    File('${dir.path}/manifest.txt').writeAsStringSync('''
<manifest>
$manifest
$networkGrep
</manifest>
''');
    File('${dir.path}/backup_rules.txt').writeAsStringSync(backupRules);
    File('${dir.path}/extraction_rules.txt').writeAsStringSync(extractionRules);
    // A valid stub JDK, so the self-check never silently uses a real
    // Android Studio JBR. The stub records that it ran, which the test asserts.
    final fakeJdk = Directory('${dir.path}/fake-jdk/bin')
      ..createSync(recursive: true);
    File('${fakeJdk.path}/java').writeAsStringSync('''
#!/bin/sh
echo "stub-java \$*" > "${dir.path}/java-ran.txt"
echo 'openjdk version "99-stub"'
''');
    Process.runSync('chmod', ['+x', '${fakeJdk.path}/java']);

    File('${dir.path}/env.sh').writeAsStringSync('''
export PATH="${bin.path}:/usr/bin:/bin:/usr/sbin:/sbin"
export JAVA_HOME="${dir.path}/fake-jdk"
export ENCRYNOTE_ANDROID_HOME="${dir.path}/android"
export ENCRYNOTE_APK="${dir.path}/app-release.apk"
export ENCRYNOTE_APP="${dir.path}/EnCryNote.app"
''');
    return dir;
  }

  Future<ProcessResult> runScript(Directory fixture) async {
    final env = File('${fixture.path}/env.sh').readAsStringSync();
    final vars = <String, String>{};
    for (final line in env.split('\n')) {
      if (!line.startsWith('export ')) continue;
      final pair = line.substring('export '.length).split('=');
      vars[pair.first] = pair.sublist(1).join('=').replaceAll('"', '');
    }
    return Process.run(
      '/bin/sh',
      [script],
      environment: vars,
      workingDirectory: root,
    );
  }

  test(
    'a clean artifact passes and the policy is enforced, not just printed',
    () async {
      final fixture = await makeFixture(toolsExist: true);
      final result = await runScript(fixture);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stdout, contains('POLICY=PASS'));
      // The stub JDK ran, so the self-check does not depend on a real Android
      // Studio JBR being installed on the host.
      expect(
        File('${fixture.path}/java-ran.txt').existsSync(),
        isTrue,
        reason: 'the fixture must use its own java stub',
      );
      expect(
        result.stdout,
        contains('openjdk version "99-stub"'),
        reason: 'the stub JDK must be the one used',
      );
    },
  );

  test('a missing required tool fails closed', () async {
    final fixture = await makeFixture(toolsExist: false);
    final result = await runScript(fixture);
    expect(
      result.exitCode,
      isNot(0),
      reason: 'a missing tool must not produce a clean report',
    );
    expect(result.stdout, isNot(contains('POLICY=PASS')));
  });

  test('an INTERNET permission in the artifact fails the policy', () async {
    final fixture = await makeFixture(
      toolsExist: true,
      permissions: 'io.github.arcahyadi.encrynote.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION\nandroid.permission.INTERNET',
    );
    final result = await runScript(fixture);
    expect(result.exitCode, isNot(0));
    expect(result.stdout, contains('POLICY=FAIL'));
  });

  test('a network service in the manifest fails the policy', () async {
    final fixture = await makeFixture(
      toolsExist: true,
      networkGrep: '<service android:name="com.example.NetworkService"/>',
    );
    final result = await runScript(fixture);
    expect(result.exitCode, isNot(0));
    expect(result.stdout, contains('POLICY=FAIL'));
  });

  test('allowBackup=true fails the policy', () async {
    final fixture = await makeFixture(
      toolsExist: true,
      manifest: '''
        android:allowBackup="true"
        android:fullBackupContent="@ref/0x7f0e0000"
        android:dataExtractionRules="@ref/0x7f0e0001"''',
    );
    final result = await runScript(fixture);
    expect(result.exitCode, isNot(0));
    expect(result.stdout, contains('POLICY=FAIL'));
  });

  test('a device-transfer section without excludes fails the policy', () async {
    final fixture = await makeFixture(
      toolsExist: true,
      extractionRules: '''
E: data-extraction-rules (line=7)
    E: cloud-backup (line=8)
        E: exclude (line=9)
          A: domain="root" (Raw: "root")
          A: path="." (Raw: ".")
        E: exclude (line=10)
          A: domain="file" (Raw: "file")
          A: path="." (Raw: ".")
        E: exclude (line=11)
          A: domain="database" (Raw: "database")
          A: path="." (Raw: ".")
        E: exclude (line=12)
          A: domain="sharedpref" (Raw: "sharedpref")
          A: path="." (Raw: ".")
        E: exclude (line=13)
          A: domain="external" (Raw: "external")
          A: path="." (Raw: ".")
    E: device-transfer (line=15)
''',
    );
    final result = await runScript(fixture);
    expect(result.exitCode, isNot(0));
    expect(result.stdout, contains('POLICY=FAIL'));
  });

  test('a network entitlement fails the policy', () async {
    final fixture = await makeFixture(
      toolsExist: true,
      entitlements:
          'com.apple.security.app-sandbox com.apple.security.network.client',
    );
    final result = await runScript(fixture);
    expect(result.exitCode, isNot(0));
    expect(result.stdout, contains('POLICY=FAIL'));
  });

  test('an empty compiled resource name fails closed', () async {
    final fixture = await makeFixture(toolsExist: true);
    // Remove the resource table entry so the name lookup comes back empty.
    File('${fixture.path}/bin/aapt2').writeAsStringSync('''
#!/bin/sh
case "\$2" in
  resources) echo "    resource 0x7f0e0000 xml/backup_rules" ;;
  xmltree) cat "${fixture.path}/backup_rules.txt" ;;
  *) exit 2 ;;
esac
''');
    Process.runSync('chmod', ['+x', '${fixture.path}/bin/aapt2']);
    final result = await runScript(fixture);
    expect(result.exitCode, isNot(0));
    expect(result.stdout, isNot(contains('POLICY=PASS')));
  });

  test('a bundle notices asset without licence text fails the policy', () async {
    // The APK copy is valid; only the macOS bundle's copy is broken. The policy
    // must still fail, so the two copies are not interchangeable.
    final fixture = await makeFixture(
      toolsExist: true,
      bundleNoticesValid: false,
    );
    final result = await runScript(fixture);
    expect(result.exitCode, isNot(0));
    expect(result.stdout, contains('POLICY=FAIL'));
  });

  test('a missing JDK fails closed even when the APK is valid', () async {
    final fixture = await makeFixture(toolsExist: true);
    // Point JAVA_HOME nowhere and take the Android Studio fallback away by
    // hiding the stub, so no java can be found.
    File('${fixture.path}/env.sh').writeAsStringSync('''
export PATH="${fixture.path}/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export JAVA_HOME="${fixture.path}/no-such-jdk"
export ENCRYNOTE_ANDROID_HOME="${fixture.path}/android"
export ENCRYNOTE_APK="${fixture.path}/app-release.apk"
export ENCRYNOTE_APP="${fixture.path}/EnCryNote.app"
''');
    final result = await runScript(fixture);
    // If the host has the Android Studio JBR, the script finds it and the run
    // is expected to succeed; otherwise it must fail closed. Either way it may
    // not report a policy pass through a broken JDK.
    if (result.stdout.contains('openjdk')) {
      expect(result.exitCode, 0);
    } else {
      expect(result.exitCode, isNot(0));
      expect(result.stdout, isNot(contains('POLICY=PASS')));
    }
  });
}
