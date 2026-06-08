// Unit tests for recent-sessions persistence (#796, PWA parity #385).
//
// Mirrors the PWA `src/modules/profiles.ts` recent-sessions rules
// (`src/modules/__tests__/recent-sessions.test.ts`):
//   - add() dedups on host+port+username (replaces, does NOT duplicate)
//   - newest entry is first
//   - the list is capped at 5
//   - remove() deletes by host+port+username
//   - load() tolerates corrupt JSON (returns []) — config-system resilience
//
// Native stores identity fields + title directly (not the PWA's profileIdx),
// because native profiles are identity-keyed and reorderable.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/state/recent_sessions.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  RecentSessionEntry entry(String host, {int port = 22, String user = 'me'}) {
    return RecentSessionEntry(
      host: host,
      port: port,
      username: user,
      title: '$user@$host',
    );
  }

  group('RecentSessionEntry', () {
    test('identityKey is host:port:username', () {
      expect(entry('h.example', port: 2222, user: 'u').identityKey,
          'h.example:2222:u');
    });

    test('round-trips through toJson/fromJson', () {
      final e = RecentSessionEntry(
        title: 'Home', host: 'home.example', port: 2200, username: 'root',
      );
      final back = RecentSessionEntry.fromJson(e.toJson());
      expect(back.host, e.host);
      expect(back.port, e.port);
      expect(back.username, e.username);
      expect(back.title, e.title);
    });
  });

  group('RecentSessionsStore.add', () {
    test('newest entry is first', () async {
      final store = RecentSessionsStore();
      await store.add(entry('a.example'));
      await store.add(entry('b.example'));
      final list = await store.load();
      expect(list.first.host, 'b.example');
      expect(list[1].host, 'a.example');
    });

    test('dedups same host+port+username, keeping the new one first', () async {
      final store = RecentSessionsStore();
      await store.add(entry('a.example'));
      await store.add(entry('b.example'));
      // Re-add a.example — should move it to the front, not duplicate.
      await store.add(entry('a.example'));
      final list = await store.load();
      expect(list.length, 2);
      expect(list.first.host, 'a.example');
      expect(list[1].host, 'b.example');
    });

    test('a different port is NOT a duplicate', () async {
      final store = RecentSessionsStore();
      await store.add(entry('a.example', port: 22));
      await store.add(entry('a.example', port: 2222));
      final list = await store.load();
      expect(list.length, 2);
    });

    test('caps the list at 5 entries (newest kept)', () async {
      final store = RecentSessionsStore();
      for (var i = 0; i < 8; i++) {
        await store.add(entry('host$i.example'));
      }
      final list = await store.load();
      expect(list.length, 5);
      // Newest first: host7..host3.
      expect(list.first.host, 'host7.example');
      expect(list.last.host, 'host3.example');
    });
  });

  group('RecentSessionsStore.remove', () {
    test('removes the matching identity, leaves others', () async {
      final store = RecentSessionsStore();
      await store.add(entry('a.example'));
      await store.add(entry('b.example'));
      await store.remove(host: 'a.example', port: 22, username: 'me');
      final list = await store.load();
      expect(list.length, 1);
      expect(list.single.host, 'b.example');
    });

    test('no-op when nothing matches', () async {
      final store = RecentSessionsStore();
      await store.add(entry('a.example'));
      await store.remove(host: 'zzz.example', port: 22, username: 'me');
      final list = await store.load();
      expect(list.length, 1);
    });
  });

  group('RecentSessionsStore.load resilience', () {
    test('returns [] when key absent', () async {
      final store = RecentSessionsStore();
      expect(await store.load(), isEmpty);
    });

    test('returns [] for corrupt JSON', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        recentSessionsPrefsKey: 'not json {',
      });
      final store = RecentSessionsStore();
      expect(await store.load(), isEmpty);
    });

    test('skips malformed entries but keeps valid ones', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        recentSessionsPrefsKey: jsonEncode(<dynamic>[
          <String, dynamic>{'host': 'ok.example', 'port': 22, 'username': 'me'},
          <String, dynamic>{'port': 22}, // missing host -> skipped
          'garbage',
        ]),
      });
      final store = RecentSessionsStore();
      final list = await store.load();
      expect(list.length, 1);
      expect(list.single.host, 'ok.example');
    });
  });
}
