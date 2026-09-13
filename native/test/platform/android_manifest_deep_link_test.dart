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
