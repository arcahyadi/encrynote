import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Project contracts that must hold for every release build.
///
/// These read source files only. They cannot prove what Gradle merged into an
/// APK or what codesign sealed into the bundle; the artifact checks in
/// `docs/testing/native-checks.md` cover that.
void main() {
  final root = Directory.current.path;

  String source(String path) => File('$root/$path').readAsStringSync();

  bool exists(String path) => File('$root/$path').existsSync();

  late Map<String, dynamic> englishArb;
  late String mainManifest;
  late String releaseEntitlements;

  setUpAll(() {
    englishArb =
        jsonDecode(source('lib/l10n/app_en.arb')) as Map<String, dynamic>;
    mainManifest = source('android/app/src/main/AndroidManifest.xml');
    releaseEntitlements = source('macos/Runner/Release.entitlements');
  });

  group('English source strings', () {
    test('the ARB is the English template', () {
      expect(englishArb['@@locale'], 'en');
      expect(source('l10n.yaml'), contains('template-arb-file: app_en.arb'));
      expect(source('l10n.yaml'), contains('arb-dir: lib/l10n'));
    });

    test('the four auto-lock labels are exact', () {
      expect(
        [
          englishArb['autoLockImmediately'],
          englishArb['autoLockOneMinute'],
          englishArb['autoLockFiveMinutes'],
          englishArb['autoLockTenMinutes'],
        ],
        ['Immediately', '1 minute', '5 minutes', '10 minutes'],
      );
      // No fifth duration and no "Never".
      expect(
        englishArb.keys.where((key) => key.startsWith('autoLock')),
        unorderedEquals([
          'autoLockTitle',
          'autoLockImmediately',
          'autoLockOneMinute',
          'autoLockFiveMinutes',
          'autoLockTenMinutes',
        ]),
      );
    });

    test('dynamic messages declare ICU placeholders', () {
      expect(
        (englishArb['@deleteNoteBody'] as Map<String, dynamic>)['placeholders'],
        contains('title'),
      );
      expect(
        (englishArb['@recoveryQuestionLabel']
            as Map<String, dynamic>)['placeholders'],
        contains('index'),
      );
    });

    test('every locale keeps the template placeholders', () {
      final arbFiles = Directory('$root/lib/l10n')
          .listSync()
          .whereType<File>()
          .map((file) => file.uri.pathSegments.last)
          .where((name) => name.startsWith('app_') && name.endsWith('.arb'));
      final placeholder = RegExp(r'\{([a-zA-Z][a-zA-Z0-9_]*)\}');
      final template = {
        for (final entry in englishArb.entries)
          if (!entry.key.startsWith('@') && entry.value is String)
            entry.key: placeholder
                .allMatches(entry.value as String)
                .map((match) => match.group(1)!)
                .toSet(),
      };
      for (final name in arbFiles) {
        final arb =
            jsonDecode(source('lib/l10n/$name')) as Map<String, dynamic>;
        for (final entry in template.entries) {
          final value = arb[entry.key];
          expect(value, isA<String>(), reason: '$name: ${entry.key}');
          expect(
            placeholder
                .allMatches(value as String)
                .map((match) => match.group(1)!)
                .toSet(),
            entry.value,
            reason: '$name: ${entry.key} must keep its placeholders',
          );
        }
      }
    });

    test('every ARB declares the locale its file name promises', () {
      final arbFiles = Directory('$root/lib/l10n')
          .listSync()
          .whereType<File>()
          .map((file) => file.uri.pathSegments.last)
          .where((name) => name.startsWith('app_') && name.endsWith('.arb'))
          .toList();
      // English is the source template and must always be present. Additional
      // locales are community contributions; see CONTRIBUTING.md.
      expect(arbFiles, contains('app_en.arb'));
      for (final name in arbFiles) {
        final locale = name.substring('app_'.length, name.length - 4);
        final arb =
            jsonDecode(source('lib/l10n/$name')) as Map<String, dynamic>;
        expect(arb['@@locale'], locale, reason: name);
        // A translation must cover the template's keys or the build falls back
        // to English mid-screen.
        for (final key in englishArb.keys.where((k) => !k.startsWith('@'))) {
          expect(arb.containsKey(key), isTrue, reason: '$name is missing $key');
        }
      }
    });
  });

  group('offline release configuration', () {
    test('the main manifest declares no network permission or service', () {
      expect(mainManifest.contains('android.permission.INTERNET'), isFalse);
      expect(mainManifest.contains('ACCESS_NETWORK_STATE'), isFalse);
      expect(mainManifest.contains('usesCleartextTraffic'), isFalse);
      expect(mainManifest.contains('<service'), isFalse);
    });

    test('debug tooling keeps its own INTERNET permission', () {
      // Hot reload needs it; it must not leak into the release manifest, which
      // the artifact check verifies separately.
      for (final flavor in ['debug', 'profile']) {
        expect(
          source('android/app/src/$flavor/AndroidManifest.xml'),
          contains('android.permission.INTERNET'),
        );
      }
    });

    test('the release entitlement enables no network client or server', () {
      expect(
        releaseEntitlements.contains('com.apple.security.network.client'),
        isFalse,
      );
      expect(
        releaseEntitlements.contains('com.apple.security.network.server'),
        isFalse,
      );
      // Sandbox stays on; the picker grant is the only file access.
      expect(releaseEntitlements, contains('com.apple.security.app-sandbox'));
      expect(
        releaseEntitlements,
        contains('com.apple.security.files.user-selected.read-write'),
      );
    });

    test('no networking dependency is declared', () {
      final pubspec = source('pubspec.yaml');
      final declared = RegExp(
        r'^  ([a-z0-9_]+):',
        multiLine: true,
      ).allMatches(pubspec).map((match) => match.group(1)!).toSet();
      expect(
        declared.intersection({
          'http',
          'dio',
          'web_socket_channel',
          'firebase_core',
          'url_launcher',
          'google_fonts',
        }),
        isEmpty,
      );
      // No source file reaches the network APIs either.
      final sources = Directory('$root/lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'));
      for (final file in sources) {
        final text = file.readAsStringSync();
        expect(text.contains('dart:html'), isFalse, reason: file.path);
        expect(text.contains('HttpClient'), isFalse, reason: file.path);
        expect(text.contains('Socket.connect'), isFalse, reason: file.path);
      }
    });
  });

  group('Android backup exclusion', () {
    test('automatic backup is off and extraction rules are referenced', () {
      expect(mainManifest, contains('android:allowBackup="false"'));
      expect(
        mainManifest,
        contains('android:fullBackupContent="@xml/backup_rules"'),
      );
      expect(
        mainManifest,
        contains('android:dataExtractionRules="@xml/data_extraction_rules"'),
      );
    });

    /// The domains excluded inside one named section (or at the top level of
    /// `<full-backup-content>` when [section] is null).
    ///
    /// A tiny section splitter instead of an XML dependency: the rule files are
    /// ours, flat, and every assertion below is about which section owns which
    /// `<exclude>`, which a file-wide `contains` cannot tell.
    Set<String> excludedIn(String rules, String? section) {
      final body = section == null
          ? rules
          : RegExp(
              '<$section>(.*?)</$section>',
              dotAll: true,
            ).firstMatch(rules)?.group(1);
      expect(body, isNotNull, reason: '$section must exist');
      return RegExp(r'<exclude\s+domain="([a-z_]+)"')
          .allMatches(body!)
          .map((match) => match.group(1)!)
          .toSet();
    }

    test('the legacy rules exclude every domain at the top level', () {
      final rules = source('android/app/src/main/res/xml/backup_rules.xml');
      expect(rules, contains('<full-backup-content>'));
      expect(
        excludedIn(rules, null),
        containsAll(['root', 'file', 'database', 'sharedpref', 'external']),
      );
    });

    test('cloud backup excludes every domain', () {
      final rules = source(
        'android/app/src/main/res/xml/data_extraction_rules.xml',
      );
      expect(rules, contains('<data-extraction-rules>'));
      expect(
        excludedIn(rules, 'cloud-backup'),
        containsAll(['root', 'file', 'database', 'sharedpref', 'external']),
      );
    });

    test('device transfer excludes every domain', () {
      final rules = source(
        'android/app/src/main/res/xml/data_extraction_rules.xml',
      );
      expect(
        excludedIn(rules, 'device-transfer'),
        containsAll(['root', 'file', 'database', 'sharedpref', 'external']),
      );
    });

    test('deleting the device-transfer excludes is caught', () {
      // The old whole-file `contains` check stayed green for exactly this
      // mutation, because the same strings still exist under cloud-backup.
      final original = source(
        'android/app/src/main/res/xml/data_extraction_rules.xml',
      );
      final start = original.indexOf('<device-transfer>');
      final end = original.indexOf('</device-transfer>');
      expect(start, greaterThan(0));
      expect(end, greaterThan(start));
      final mutated =
          '${original.substring(0, start)}'
          '<device-transfer></device-transfer>'
          '${original.substring(end + '</device-transfer>'.length)}';

      expect(mutated, contains('domain="root"'));
      expect(excludedIn(mutated, 'cloud-backup'), isNotEmpty);
      expect(excludedIn(mutated, 'device-transfer'), isEmpty);
    });
  });

  group('licence and community documents', () {
    test('the app code is MIT for EnCryNote contributors', () {
      final licence = source('LICENSE');
      expect(licence, contains('MIT License'));
      expect(licence, contains('EnCryNote contributors'));
      expect(licence, contains('THE SOFTWARE IS PROVIDED "AS IS"'));
    });

    test('dependency licences are attributed without being relicensed', () {
      final readme = source('README.md');
      expect(readme, contains('Third-party licences'));
      expect(readme, contains('Apache License 2.0'));
      expect(readme, contains('`cryptography`'));
      expect(
        readme.contains('dependency licences are MIT'),
        isFalse,
        reason: 'dependencies keep their own licences',
      );
      // The bundle carries the texts, and the app can show them; a pub-cache
      // path is not distribution.
      expect(readme, contains('NOTICES'));
      expect(readme, contains('Settings → Licences'));
      expect(
        readme.contains('~/.pub-cache'),
        isFalse,
        reason: 'the pub cache is not part of the distribution',
      );
      // Native/transitive packages that ship in the bundles are named.
      for (final package in ['jni', 'objective_c', 'path_provider_android']) {
        expect(readme.contains('`$package`'), isTrue, reason: package);
      }
    });

    test('the licence page is reachable from settings', () {
      expect(
        source('lib/settings/settings_screen.dart'),
        contains('showLicensePage'),
      );
      expect(
        source('lib/settings/settings_screen.dart'),
        contains("ValueKey('licensesButton')"),
      );
      expect(source('lib/l10n/app_en.arb'), contains('settingsLicensesButton'));
    });

    test('README describes the manual retry, not an automatic one', () {
      final readme = source('README.md');
      expect(readme, contains('Retry'));
      expect(
        readme.contains('keeps retrying'),
        isFalse,
        reason: 'retry is a button, not a loop',
      );
      expect(
        RegExp(r'nothing retries\s+on a timer').hasMatch(readme),
        isTrue,
        reason: 'README must say nothing retries automatically',
      );
    });

    test('README states the runtime and data limits', () {
      final readme = source('README.md');
      for (final fact in [
        'Cold start',
        'locked',
        'recovery',
        'unlock',
        '.encrynote',
        '.md',
        'plaintext',
        '8 MiB',
        '16 MiB',
        '1 MiB',
        'Argon2id',
        '19456',
        'macOS 12',
        'Android',
      ]) {
        expect(readme.contains(fact), isTrue, reason: 'README must say $fact');
      }
      expect(readme, contains('no formal security audit'));
      expect(readme, contains('zeroization'));
    });

    test('CONTRIBUTING explains locale contributions', () {
      final contributing = source('CONTRIBUTING.md');
      expect(contributing, contains('app_en.arb'));
      expect(contributing, contains('app_<locale>.arb'));
      expect(contributing, contains('placeholder'));
      expect(contributing, contains('flutter gen-l10n'));
      expect(contributing, contains('MIT'));
    });

    test('native checks are recorded with their limits', () {
      expect(exists('docs/testing/native-checks.md'), isTrue);
      final checks = source('docs/testing/native-checks.md');
      expect(checks, contains('Not run'));
      expect(checks, contains('apkanalyzer'));
      expect(checks, contains('codesign'));
    });
  });

  group('integration commands cannot delete app data', () {
    /// Every `flutter test integration_test/...` command in a document or in a
    /// test's usage comment must carry `--no-uninstall`.
    ///
    /// The test APK uses the product application id, so the tool's default
    /// uninstall removes that package's whole data directory, including a real
    /// vault. A test-owned subdirectory does not help.
    void expectSafeCommands(String text, String origin) {
      // Join backslash continuations first: one shell command can span lines,
      // and the flag may sit on a later one.
      final raw = text.split('\n');
      final commands = <String>[];
      final startLines = <int>[];
      for (var i = 0; i < raw.length; i++) {
        var line = raw[i];
        final start = i + 1;
        while (line.trimRight().endsWith('\\') && i + 1 < raw.length) {
          line =
              '${line.trimRight().substring(0, line.trimRight().length - 1)}'
              ' ${raw[++i]}';
        }
        commands.add(line);
        startLines.add(start);
      }
      for (var i = 0; i < commands.length; i++) {
        final line = commands[i];
        if (!line.contains('flutter test integration_test/')) continue;
        expect(
          line.contains('--no-uninstall'),
          isTrue,
          reason:
              '$origin:${startLines[i]} runs an integration test without '
              '--no-uninstall: ${line.trim()}',
        );
      }
    }

    test('README test commands are safe', () {
      expectSafeCommands(source('README.md'), 'README.md');
    });

    test('CONTRIBUTING test commands are safe', () {
      expectSafeCommands(source('CONTRIBUTING.md'), 'CONTRIBUTING.md');
    });

    test('native-checks commands are safe', () {
      expectSafeCommands(
        source('docs/testing/native-checks.md'),
        'docs/testing/native-checks.md',
      );
    });

    test('integration test usage comments are safe', () {
      for (final file
          in Directory('$root/integration_test')
              .listSync()
              .whereType<File>()
              .where((file) => file.path.endsWith('.dart'))) {
        expectSafeCommands(file.readAsStringSync(), file.path);
      }
    });

    test('the docs explain the data-loss reason and the owned-target rule', () {
      final checks = source('docs/testing/native-checks.md');
      expect(checks, contains('--no-uninstall'));
      // Not a file-pulling inconvenience: uninstall deletes package data.
      expect(
        RegExp(
          r'uninstall[^.]{0,200}(data|vault)',
          caseSensitive: false,
        ).hasMatch(checks),
        isTrue,
        reason: 'uninstall must be described as data loss',
      );
      expect(
        RegExp(
          r'owned|disposable|no personal vault',
          caseSensitive: false,
        ).hasMatch(checks),
        isTrue,
        reason: 'the target must be owned/disposable',
      );
      // The product application id is shared, so say so.
      expect(checks, contains('com.example.hello_flutter'));
    });

    test('README warns that the device must hold no personal vault', () {
      final readme = source('README.md');
      expect(readme, contains('--no-uninstall'));
      expect(
        RegExp(
          r'personal vault|owned|disposable',
          caseSensitive: false,
        ).hasMatch(readme),
        isTrue,
      );
    });

    test(
      'the frozen plan keeps its old commands but points at the new rule',
      () {
        final plan = source(
          'docs/superpowers/plans/2026-10-22-encrynote-implementation.md',
        );
        // The historical step is not rewritten...
        expect(
          plan,
          contains('flutter test integration_test/encrynote_flow_test.dart'),
        );
        // ...but a reader is told the current rule wins.
        expect(plan, contains('Safety supersession'));
        expect(plan, contains('--no-uninstall'));
        expect(plan, contains('docs/testing/native-checks.md'));
      },
    );

    test('the release helper documents its fail-closed policy', () {
      final script = source('tool/release_checks.sh');
      expect(script, contains('set -eu'));
      expect(script, contains('POLICY=PASS'));
      expect(script, contains('POLICY=FAIL'));
      expect(script, contains('fail '));
    });
  });
}
