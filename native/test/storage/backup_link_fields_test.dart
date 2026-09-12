// #1140 (PR B of #1117): backup posture of the link fields. Spec: R13 and
// docs/deep-link-intents.md §14 — `linkAutoConnect` is destination TRUST, so
// it takes the same posture as `initialCommand`: stripped from every exported
// profile, and on restore applied ONLY through the existing explicit
// `restoreCommands` opt-in (otherwise the prior local value is kept; a new
// identity gets false). `linkAlias` is plain metadata and travels normally.
//
// PINNED API:
//   buildBackupPayload(...)  — payload['profiles'][i] never has a
//                              'linkAutoConnect' key; 'linkAlias' present.
//   applyBackupPayload(payload, restoreCommands: false) — linkAutoConnect
//                              kept (existing) / false (new).
//   applyBackupPayload(payload, restoreCommands: true)  — linkAutoConnect
//                              taken from the payload.
//
// Note for the develop agent: native has NO plain profiles-JSON export
// function — `ProfilesStore.save` (profiles_store.dart ~L514) is the
// persistence write and MUST keep `linkAutoConnect` (see
// profile_link_fields_test.dart 'persists both link fields'). Do not strip
// it there.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/ssh/host_key_store.dart';
import 'package:mobissh/state/recent_sessions.dart';
import 'package:mobissh/storage/backup_payload.dart';
import 'package:mobissh/storage/backup_restore.dart';
import 'package:mobissh/storage/custom_patterns_store.dart';
import 'package:mobissh/storage/detection_exceptions_store.dart';
import 'package:mobissh/storage/detection_styles_store.dart';
import 'package:mobissh/storage/favorites_store.dart';
import 'package:mobissh/storage/keys_store.dart';
import 'package:mobissh/storage/profiles_store.dart';
import 'package:mobissh/storage/secrets_store.dart';

Future<SharedPreferences> _freshPrefs() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  return SharedPreferences.getInstance();
}

/// Export from a store holding [profiles]. Credential-less profiles keep the
/// secrets classification trivially clean, so the export never aborts.
Future<Map<String, Object?>> _export(
  SharedPreferences prefs,
  List<SavedProfile> profiles,
) async {
  await ProfilesStore(prefs: prefs).save(profiles);
  final result = await buildBackupPayload(
    profiles: ProfilesStore(prefs: prefs),
    keys: KeysStore(prefs: prefs),
    secrets: SecretsStore(backend: InMemorySecretsBackend()),
    hostKeys: InMemoryHostKeyBackend({}),
    recents: RecentSessionsStore(prefs: prefs),
    favorites: FavoritesStore(prefs: prefs),
    detectionExceptions: DetectionExceptionsStore(prefs: prefs),
    customPatterns: CustomPatternsStore(prefs: prefs),
    detectionStyles: DetectionStylesStore(prefs: prefs),
    prefs: prefs,
    appVersion: 'test+1',
    now: () => DateTime.utc(2026, 9, 12),
  );
  expect(result.error, isNull);
  return result.payload!;
}

/// Minimal restore payload: one profile with both link fields set.
Map<String, Object?> _restorePayload({
  String host = 'h.example',
  bool linkAutoConnect = true,
}) =>
    <String, Object?>{
      'payloadVersion': 1,
      'createdAt': '2026-09-12T00:00:00Z',
      'appVersion': '0.1.12',
      'profiles': [
        {
          'title': 'Box',
          'host': host,
          'port': 22,
          'username': 'me',
          'linkAlias': 'box',
          'linkAutoConnect': linkAutoConnect,
        },
      ],
      'keys': <Object?>[],
      'secrets': <String, Object?>{},
      'hostKeys': <String, Object?>{},
      'recents': <Object?>[],
      'profileOrder': <Object?>[],
      'favorites': <String, Object?>{},
      'detectionExceptions': <Object?>[],
      'customPatterns': <Object?>[],
      'detectionStyles': <String, Object?>{},
      'settings': <String, Object?>{},
    };

Future<SavedProfile> _loadBox(SharedPreferences prefs) async =>
    (await ProfilesStore(prefs: prefs).load())
        .firstWhere((p) => p.host == 'h.example');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('buildBackupPayload — linkAutoConnect stripped, linkAlias travels',
      () {
    test('no exported profile carries a linkAutoConnect key', () async {
      final prefs = await _freshPrefs();
      final payload = await _export(prefs, <SavedProfile>[
        SavedProfile(
          title: 'Trusted',
          host: 'h1.example',
          port: 22,
          username: 'u1',
          linkAlias: 'one',
          linkAutoConnect: true,
        ),
        SavedProfile(
          title: 'Plain',
          host: 'h2.example',
          port: 22,
          username: 'u2',
          linkAutoConnect: true,
        ),
      ]);
      final profiles = (payload['profiles'] as List).cast<Map>();
      expect(profiles, hasLength(2));
      for (final p in profiles) {
        expect(p.containsKey('linkAutoConnect'), isFalse,
            reason: 'trust bit must not travel in a backup (${p['host']})');
      }
    });

    test('linkAlias is present on the exported profile', () async {
      final prefs = await _freshPrefs();
      final payload = await _export(prefs, <SavedProfile>[
        SavedProfile(
          title: 'Trusted',
          host: 'h1.example',
          port: 22,
          username: 'u1',
          linkAlias: 'one',
          linkAutoConnect: true,
        ),
      ]);
      final p = (payload['profiles'] as List).cast<Map>().single;
      expect(p['linkAlias'], 'one');
    });
  });

  group('applyBackupPayload — linkAutoConnect gated by restoreCommands', () {
    test('default OFF: a new identity restores with linkAutoConnect false',
        () async {
      final prefs = await _freshPrefs();
      final result = await applyBackupPayload(
        _restorePayload(linkAutoConnect: true),
        prefs: prefs,
        secrets: SecretsStore(backend: InMemorySecretsBackend()),
      );
      expect(result.added, 1);
      final box = await _loadBox(prefs);
      expect(box.linkAutoConnect, isFalse);
      expect(box.linkAlias, 'box', reason: 'alias is metadata — it travels');
    });

    test('default OFF: an existing identity keeps its prior true', () async {
      final prefs = await _freshPrefs();
      await ProfilesStore(prefs: prefs).save(<SavedProfile>[
        SavedProfile(
          title: 'Old Box',
          host: 'h.example',
          port: 22,
          username: 'me',
          linkAutoConnect: true,
        ),
      ]);
      final result = await applyBackupPayload(
        _restorePayload(linkAutoConnect: false),
        prefs: prefs,
        secrets: SecretsStore(backend: InMemorySecretsBackend()),
      );
      expect(result.updated, 1);
      expect((await _loadBox(prefs)).linkAutoConnect, isTrue);
    });

    test('default OFF: an existing identity keeps its prior false', () async {
      final prefs = await _freshPrefs();
      await ProfilesStore(prefs: prefs).save(<SavedProfile>[
        SavedProfile(
          title: 'Old Box',
          host: 'h.example',
          port: 22,
          username: 'me',
        ),
      ]);
      final result = await applyBackupPayload(
        _restorePayload(linkAutoConnect: true),
        prefs: prefs,
        secrets: SecretsStore(backend: InMemorySecretsBackend()),
      );
      expect(result.updated, 1);
      expect((await _loadBox(prefs)).linkAutoConnect, isFalse);
    });

    test('restoreCommands ON: a new identity takes the payload value (true)',
        () async {
      final prefs = await _freshPrefs();
      final result = await applyBackupPayload(
        _restorePayload(linkAutoConnect: true),
        prefs: prefs,
        secrets: SecretsStore(backend: InMemorySecretsBackend()),
        restoreCommands: true,
      );
      expect(result.added, 1);
      expect((await _loadBox(prefs)).linkAutoConnect, isTrue);
    });

    test('restoreCommands ON: an existing identity takes the payload value',
        () async {
      final prefs = await _freshPrefs();
      await ProfilesStore(prefs: prefs).save(<SavedProfile>[
        SavedProfile(
          title: 'Old Box',
          host: 'h.example',
          port: 22,
          username: 'me',
        ),
      ]);
      final result = await applyBackupPayload(
        _restorePayload(linkAutoConnect: true),
        prefs: prefs,
        secrets: SecretsStore(backend: InMemorySecretsBackend()),
        restoreCommands: true,
      );
      expect(result.updated, 1);
      final box = await _loadBox(prefs);
      expect(box.linkAutoConnect, isTrue);
      expect(box.title, 'Old Box', reason: 'upsert preserves the local title');
    });
  });
}
