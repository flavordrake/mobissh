// #1258 R16 — the post-update notice: "Updated to <version>" only on the first
// launch whose running build is GREATER than the stored last-run build; a fresh
// install (or a corrupt value) is stored silently. Version lives in the value.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/services/post_update_notice.dart';
import 'package:mobissh/services/self_update.dart';

UpdateManifest manifest({int build = 199, String notes = '## v\n- a'}) =>
    UpdateManifest.parse(
      jsonEncode(<String, Object?>{
        'version': '0.1.13+$build',
        'build': build,
        'abi': 'arm64-v8a',
        'url': 'https://mobissh.tailbe5094.ts.net/m.apk',
        'sha256':
            '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        'notes': notes,
      }),
      manifestUrl:
          Uri.parse('https://mobissh.tailbe5094.ts.net/android-latest.json'),
    );

String lastRun(int b) => jsonEncode(<String, Object?>{'v': 1, 'build': b});

void main() {
  group('postUpdateNotice decision table', () {
    for (final row in <(String, int?, int?, bool, bool)>[
      ('no MOBISSH_BUILD → nothing', null, 5, false, false),
      ('no MOBISSH_BUILD, nothing stored → nothing', null, null, false, false),
      ('fresh install → store silently', 199, null, false, true),
      ('same build → nothing', 199, 199, false, false),
      ('downgrade / reinstall → store silently', 198, 199, false, true),
      ('build increased → show + store', 199, 198, true, true),
    ]) {
      test(row.$1, () {
        final d = postUpdateNotice(running: row.$2, stored: row.$3);
        expect(d.show, row.$4);
        expect(d.write, row.$5);
      });
    }
  });

  group('parseLastRun (version in the value)', () {
    test('v1 round trip', () => expect(parseLastRun(lastRun(198)), 198));
    for (final bad in <String?>[
      null,
      '',
      'not json',
      '198',
      '[1]',
      '{"v":2,"build":198}',
      '{"v":1,"build":"198"}',
      '{"v":1}',
    ]) {
      test('corrupt or unknown → null ($bad)', () {
        expect(parseLastRun(bad), isNull);
      });
    }
  });

  group('PostUpdateStore', () {
    test('fresh install: no notice, running build stored', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final store = PostUpdateStore();
      expect(await store.evaluate(199), isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(parseLastRun(prefs.getString(lastRunPrefKey)), 199);
    });

    test('corrupt stored value → treated as fresh, no crash, no notice',
        () async {
      SharedPreferences.setMockInitialValues(
          <String, Object>{lastRunPrefKey: '{oops'});
      expect(await PostUpdateStore().evaluate(199), isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(parseLastRun(prefs.getString(lastRunPrefKey)), 199);
    });

    test('build increased: notice with the saved notes, shown once', () async {
      SharedPreferences.setMockInitialValues(
          <String, Object>{lastRunPrefKey: lastRun(198)});
      final store = PostUpdateStore();
      await store.savePending(manifest());
      final n = await store.evaluate(199);
      expect(n, isNotNull);
      expect(n!.version, '0.1.13+199');
      expect(n.notes, '## v\n- a');
      // Second launch of the same build: nothing.
      expect(await store.evaluate(199), isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(pendingPrefKey), isNull,
          reason: 'pending notes are cleared once shown');
    });

    test('pending notes for a DIFFERENT build are not shown', () async {
      SharedPreferences.setMockInitialValues(
          <String, Object>{lastRunPrefKey: lastRun(197)});
      final store = PostUpdateStore();
      await store.savePending(manifest(build: 198));
      final n = await store.evaluate(199);
      expect(n, isNotNull);
      expect(n!.version, isNull, reason: 'caller falls back to PackageInfo');
      expect(n.notes, isEmpty);
    });

    test('no running build → nothing stored, nothing shown', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      expect(await PostUpdateStore().evaluate(null), isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(lastRunPrefKey), isNull);
    });
  });
}
