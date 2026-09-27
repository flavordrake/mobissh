// #1216 R11/R13 drift guard on the checked-in Android sources. The ARTIFACT
// assertion (A6: the built AAB carries neither the permission nor the
// provider) is scripts/test-self-update-play-exclusion.sh, which builds; this
// pins the wiring that produces it so a manifest edit fails the fast gate.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final main = File('android/app/src/main/AndroidManifest.xml')
      .readAsStringSync();
  final play = File('android/app/src/play/AndroidManifest.xml');
  final paths = File('android/app/src/main/res/xml/update_paths.xml');
  final gradle = File('android/app/build.gradle.kts').readAsStringSync();

  const perm = 'android.permission.REQUEST_INSTALL_PACKAGES';
  const provider = '.mobissh.UpdatesFileProvider';

  test('sideload manifest declares the permission and the updater provider',
      () {
    expect(main, contains('android:name="$perm"'));
    final p = RegExp(
      r'<provider\b[^>]*android:name="\.mobissh\.UpdatesFileProvider"[\s\S]*?</provider>',
    ).firstMatch(main);
    expect(p, isNotNull, reason: 'updater FileProvider missing (R11)');
    final body = p!.group(0)!;
    // Its OWN authority — never shared with share_plus or any other provider.
    expect(
      body,
      contains(r'android:authorities="${applicationId}.updates.fileprovider"'),
    );
    expect(body, contains('android:exported="false"'));
    expect(body, contains('android:grantUriPermissions="true"'));
    expect(body, contains('@xml/update_paths'));
  });

  test('updater FileProvider exposes cache/updates/ and nothing else', () {
    final xml = paths.readAsStringSync();
    final entries = RegExp(r'<([a-z-]+-path)\b[^>]*/>').allMatches(xml).toList();
    expect(entries, hasLength(1));
    expect(entries.single.group(1), 'cache-path');
    expect(entries.single.group(0), contains('path="updates/"'));
  });

  test('Play overlay removes both, and gradle applies it to bundle builds',
      () {
    final xml = play.readAsStringSync();
    expect(
      xml,
      matches(RegExp(
        '<uses-permission[^>]*android:name="$perm"[^>]*tools:node="remove"',
      )),
    );
    expect(
      xml,
      matches(RegExp(
        '<provider[^>]*android:name="${RegExp.escape(provider)}"[^>]*tools:node="remove"',
      )),
    );
    expect(gradle, contains('src/play/AndroidManifest.xml'));
    expect(gradle, contains('isPlayBundle'));
  });
}
