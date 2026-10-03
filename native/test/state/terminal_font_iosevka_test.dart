// #1256 — Iosevka Term as a terminal font option, plus the storage-layer drift
// guard it exposed. The picker list ([terminalFontFamilies]) is mirrored by
// two inlined allowlists in the storage layer (SavedProfile._knownFontFamilies
// and backup_restore's _knownFontFamilies). Those had drifted at #707: a
// profile or backup carrying RobotoMono / UbuntuMono / Cousine was silently
// reset to the default face on read. Every picker id must survive the profile
// JSON round trip and a backup restore, so a new face can't regress this way.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/state/ui_prefs_providers.dart';
import 'package:mobissh/storage/backup_restore.dart';
import 'package:mobissh/storage/profiles_store.dart';
import 'package:mobissh/storage/secrets_store.dart';

const _iosevka = 'IosevkaTerm';

/// Polls (bounded) until the notifier's async hydrate lands — no fixed sleep.
Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('Iosevka Term in the picker', () {
    test('listed with id IosevkaTerm and label "Iosevka"', () {
      final fam = terminalFontFamilies.where((f) => f.id == _iosevka);
      expect(fam, hasLength(1));
      expect(fam.single.label, 'Iosevka');
    });

    test('resolves to itself and is known', () {
      expect(isKnownFontFamily(_iosevka), isTrue);
      expect(resolveFontFamily(_iosevka), _iosevka);
    });

    test('is not the default face', () {
      expect(fontFamilyDefault, isNot(_iosevka));
    });
  });

  group('Iosevka Term persistence', () {
    test('global default persists and restores on a fresh notifier', () async {
      final first = TerminalFontFamilyNotifier(
        prefs: SharedPreferences.getInstance(),
      );
      await first.set(_iosevka);
      expect(first.state, _iosevka);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(fontFamilyPrefKey), _iosevka);

      final second = TerminalFontFamilyNotifier(
        prefs: SharedPreferences.getInstance(),
      );
      await _until(() => second.state == _iosevka);
      expect(second.state, _iosevka);
    });

    test('per-session override selects Iosevka for that session only', () {
      final pair = InMemoryGatewayPair();
      final c = ProviderContainer(
        overrides: [taskSshGatewayProvider.overrideWithValue(pair.uiSide)],
      );
      addTearDown(pair.dispose);
      addTearDown(c.dispose);
      SessionEntry add(String host) => c
          .read(sessionsProvider.notifier)
          .addOrActivate(
            SshConnectParams(
              host: host,
              port: 22,
              username: 'u',
              auth: const SshAuth.password('p'),
            ),
          );
      final a = add('host-a');
      final b = add('host-b');
      c.read(sessionAppearanceProvider.notifier).setFontFamily(a.id, _iosevka);
      expect(c.read(sessionFontFamilyProvider(a.id)), _iosevka);
      expect(c.read(sessionFontFamilyProvider(b.id)), fontFamilyDefault);
    });
  });

  group('storage allowlists match the picker (drift guard)', () {
    test('every picker family survives the profile JSON round trip', () {
      for (final f in terminalFontFamilies) {
        final p = SavedProfile.fromJson(
          SavedProfile(
            title: 't',
            host: 'h',
            port: 22,
            username: 'u',
            fontFamily: f.id,
          ).toJson(),
        );
        expect(p.fontFamily, f.id, reason: '${f.id} dropped on profile read');
      }
    });

    test('every picker family is restored from a backup', () async {
      for (final f in terminalFontFamilies) {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final prefs = await SharedPreferences.getInstance();
        final result = await applyBackupPayload(
          <String, Object?>{
            'payloadVersion': 1,
            'profiles': [
              {
                'title': 'Box',
                'host': 'h.example',
                'port': 22,
                'username': 'me',
                'fontFamily': f.id,
              },
            ],
            'settings': {fontFamilyPrefKey: f.id},
          },
          prefs: prefs,
          secrets: SecretsStore(backend: InMemorySecretsBackend()),
        );
        expect(result.errors, isEmpty);
        expect(
          prefs.getString(fontFamilyPrefKey),
          f.id,
          reason: '${f.id} default dropped on backup restore',
        );
        final profiles = await ProfilesStore(prefs: prefs).load();
        expect(
          profiles.single.fontFamily,
          f.id,
          reason: '${f.id} profile font dropped on backup restore',
        );
      }
    });
  });
}
