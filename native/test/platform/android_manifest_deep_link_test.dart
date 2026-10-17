// #1146: the Android manifest must opt OUT of Flutter's built-in deep-link
// handler. With it on (the default), every warm `mobissh://` delivery makes
// FlutterActivity.onNewIntent push the raw URI as a Navigator route, and
// MaterialApp has no route generator for "/?host=…" — a FlutterError in debug,
// a null-check TypeError in release, recorded by CrashReporter on every link.
// app_links owns link delivery (#1141); the engine must stay out of it.
//
// Drift guard: reads the checked-in manifest so a scaffold regeneration or a
// manifest edit that drops the meta-data fails the fast gate, not the device.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('manifest disables flutter_deeplinking (app_links owns mobissh://)', () {
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    final activity = RegExp(
      r'<activity\b[^>]*android:name="\.mobissh\.MainActivity"[\s\S]*?</activity>',
    ).firstMatch(manifest);
    expect(activity, isNotNull, reason: 'MainActivity element missing');
    final body = activity!.group(0)!;
    expect(
      body,
      contains('android:scheme="mobissh"'),
      reason: 'mobissh VIEW intent filter missing (#1141)',
    );
    // #1279 S4 (D1): MobiSSH claims ssh:// so it is offered in the "Open with"
    // chooser. One filter, with VIEW + DEFAULT + BROWSABLE, on this activity.
    final sshFilter = RegExp(
      r'<intent-filter>(?:(?!</intent-filter>)[\s\S])*android:scheme="ssh"(?:(?!</intent-filter>)[\s\S])*</intent-filter>',
    ).firstMatch(body);
    expect(sshFilter, isNotNull, reason: 'ssh VIEW intent filter missing (#1279)');
    final filter = sshFilter!.group(0)!;
    for (final needed in [
      'android.intent.action.VIEW',
      'android.intent.category.DEFAULT',
      'android.intent.category.BROWSABLE',
    ]) {
      expect(filter, contains(needed), reason: 'ssh filter lacks $needed');
    }
    expect(filter, isNot(contains('android:host')),
        reason: 'ssh filter must not pin a host');
    final metaData = RegExp(
      r'<meta-data\b[^>]*android:name="flutter_deeplinking_enabled"[^>]*android:value="false"',
    );
    expect(
      body,
      matches(metaData),
      reason:
          'flutter_deeplinking_enabled=false missing — warm links crash (#1146)',
    );
  });
}
