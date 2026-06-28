// On-emulator SFTP FAVORITES smoke (#632).
//
// Favorites are PER-PROFILE starred remote paths, persisted across restart. The
// headless widget tests (file_browser_favorites_test.dart) drive a fake gateway
// + mock SharedPreferences; they cannot catch a device-only long-press timing
// regression or a real shared_preferences persistence gap. This test runs the
// REAL app on the emulator against test-sshd and exercises the favorites UX
// state transitions end to end: TAP star → favorited; LONG-PRESS star → menu →
// TAP favorite → navigate (deepLink seam); LONG-PRESS favorite → removed; and
// that the favorite actually landed in the on-device FavoritesStore (persistence
// proof — the same store a fresh launch reads back).
//
// Network + seeding mirror sftp_browse_smoke_test.dart (reuse the bridge + the
// live-shell seed, per feedback_reuse_pwa_infra). Long-press timing is device-
// only, so this case is tagged integration and gated behind the emulator suite.

@Tags(['integration'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/storage/favorites_store.dart';
import 'package:mobissh/ui/file_browser_screen.dart';

import 'support/connect_helpers.dart';

const _slice = Duration(milliseconds: 500);

Future<bool> _pumpUntil(
  WidgetTester tester,
  bool Function() test, {
  int maxSlices = 80,
}) async {
  for (var i = 0; i < maxSlices; i++) {
    await tester.pump(_slice);
    final trust = find.text('Trust + connect');
    if (trust.evaluate().isNotEmpty) {
      await tester.tap(trust.first);
      await tester.pump(const Duration(milliseconds: 300));
    }
    if (test()) return true;
  }
  return false;
}

Future<bool> _reachTerminal(WidgetTester tester) {
  return _pumpUntil(
    tester,
    () => find.byKey(const Key('session-menu-button')).evaluate().isNotEmpty,
  );
}

Future<void> _assertShellAlive(
  WidgetTester tester,
  SessionEntry entry, {
  required String marker,
}) async {
  final out = <int>[];
  final sub = entry.proxy.output.listen(out.addAll);
  addTearDown(sub.cancel);
  await tester.pump(const Duration(milliseconds: 200));
  entry.proxy.sendInput(Uint8List.fromList(utf8.encode('echo $marker\n')));
  final sawMarker = await _pumpUntil(
    tester,
    () => utf8.decode(out, allowMalformed: true).contains(marker),
    maxSlices: 40,
  );
  expect(sawMarker, isTrue, reason: 'dead shell / input dead');
}

Future<void> _seedTree(
  WidgetTester tester,
  SessionEntry entry, {
  required String root,
}) async {
  final out = <int>[];
  final sub = entry.proxy.output.listen(out.addAll);
  addTearDown(sub.cancel);
  const done = 'MOBISSH_SEED_DONE_632';
  final script = StringBuffer()
    ..write('rm -rf $root; ')
    ..write('mkdir -p $root/sub; ')
    ..write('echo hi > $root/sub/inside.txt; ')
    ..write('echo $done\n');
  entry.proxy.sendInput(Uint8List.fromList(utf8.encode(script.toString())));
  final seeded = await _pumpUntil(
    tester,
    () => utf8.decode(out, allowMalformed: true).contains(done),
    maxSlices: 40,
  );
  expect(seeded, isTrue, reason: 'seed never completed on test-sshd ($root)');
}

Future<void> _openBrowserAt(
  WidgetTester tester,
  BuildContext context,
  String sessionId,
  String path,
) async {
  unawaited(
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => FileBrowserScreen(sessionId: sessionId, initialPath: path),
      ),
    ),
  );
  await _pumpUntil(
    tester,
    () => find.byKey(const Key('file-browser-list')).evaluate().isNotEmpty,
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'favorites: star → favorite, long-press → quick-nav, long-press → remove',
    (tester) async {
      FlutterForegroundTask.initCommunicationPort();

      final container = ProviderContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MobisshApp(),
        ),
      );
      await tester.pump(const Duration(seconds: 1));

      await adhocPasswordConnect(
        tester,
        host: '127.0.0.1',
        port: '2222',
        user: 'testuser',
        pass: 'testpass',
      );
      expect(await _reachTerminal(tester), isTrue, reason: 'no terminal');
      final entry = container.read(sessionsProvider).active;
      expect(entry, isNotNull);
      await _assertShellAlive(tester, entry!, marker: 'MOBISSH_OK_632');

      const root = '/tmp/mobissh_itest_632';
      await _seedTree(tester, entry, root: root);

      // Open the browser at the seeded root.
      final ctx = tester.element(find.byKey(const Key('session-menu-button')));
      await _openBrowserAt(tester, ctx, entry.id, root);

      // 1) TAP the star → favorited (filled).
      expect(
        find.descendant(
          of: find.byKey(const Key('file-browser-star')),
          matching: find.byIcon(Icons.star_border),
        ),
        findsOneWidget,
        reason: 'star should start as outline',
      );
      await tester.tap(find.byKey(const Key('file-browser-star')));
      final favorited = await _pumpUntil(
        tester,
        () => find
            .descendant(
              of: find.byKey(const Key('file-browser-star')),
              matching: find.byIcon(Icons.star),
            )
            .evaluate()
            .isNotEmpty,
        maxSlices: 20,
      );
      expect(favorited, isTrue, reason: 'star did not become filled after tap');

      // Persistence proof: the on-device FavoritesStore (what a fresh launch
      // reads back) now holds this profile's path.
      final key = entry.profileKey;
      expect(
        await FavoritesStore().isFavorite(key, root),
        isTrue,
        reason: 'favorite did not persist to shared_preferences',
      );

      // Descend into sub so the current dir differs from the favorite.
      await tester.tap(find.byKey(const Key('file-entry-sub')));
      await _pumpUntil(
        tester,
        () =>
            find.byKey(const Key('file-entry-inside.txt')).evaluate().isNotEmpty,
      );

      // 2) LONG-PRESS the star → favorites menu → TAP favorite → navigate back.
      await tester.longPress(find.byKey(const Key('file-browser-star')));
      final menuUp = await _pumpUntil(
        tester,
        () => find.byKey(const Key('favorites-list')).evaluate().isNotEmpty,
        maxSlices: 20,
      );
      expect(menuUp, isTrue, reason: 'long-press star did not open the menu');
      expect(find.byKey(Key('favorite-item-$root')), findsOneWidget);
      await tester.tap(find.byKey(Key('favorite-item-$root')));
      final navback = await _pumpUntil(
        tester,
        () => find.byKey(const Key('file-entry-sub')).evaluate().isNotEmpty,
      );
      expect(navback, isTrue, reason: 'quick-nav did not return to the root dir');

      // 3) LONG-PRESS the favorite → removed (gone from the list).
      await tester.longPress(find.byKey(const Key('file-browser-star')));
      await _pumpUntil(
        tester,
        () => find.byKey(const Key('favorites-list')).evaluate().isNotEmpty,
        maxSlices: 20,
      );
      await tester.longPress(find.byKey(Key('favorite-item-$root')));
      final removedFromList = await _pumpUntil(
        tester,
        () => find.byKey(Key('favorite-item-$root')).evaluate().isEmpty,
        maxSlices: 20,
      );
      expect(
        removedFromList,
        isTrue,
        reason: 'long-press favorite did not remove it from the menu',
      );
      expect(
        await FavoritesStore().isFavorite(key, root),
        isFalse,
        reason: 'removal did not persist',
      );

      // Tear the session + service down.
      final notifier = container.read(sessionsProvider.notifier);
      for (final id in container
          .read(sessionsProvider)
          .entries
          .map((e) => e.id)
          .toList(growable: false)) {
        notifier.close(id);
      }
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
    },
  );
}
