// Widget test: a re-import upsert that CHANGES authType is reflected on the
// next profile tap — no stale password mode (#595, the #547 follow-up).
//
// Headless reproduction of the on-device bug found by the #589 integration
// gate (import_upsert_diversity_test.dart): a STALE profile is re-imported with
// a CHANGED authType. #547 made the LIST refresh after an upsert; the remaining
// gap is the per-profile authType used by the connect path. If the upserted
// profile still carries the OLD authType, tapping it connects in the OLD mode.
// We seed the stale profile as authType=password WITH a usable password secret,
// then re-import it as authType=key — so a stale authType connects in PASSWORD
// mode and a refreshed one connects in KEY mode. (Seeding the password secret
// is what makes this a strict authType test: the keyVaultId-inference fallback
// only fires when authType is null, so it cannot mask a stale `password`.)
//
// Observable contract (no inline connect form exists post-#583): tapping a
// profile routes through `_connectFromProfile`, which resolves the profile's
// authType + vault credentials and dispatches `proxy.connect`. The connect
// command crosses the in-memory gateway as a JSON payload carrying
// `auth: {type: 'key'|'password', ...}`. We capture that payload on the task
// side and assert `auth.type == 'key'` after the upsert — the direct proof the
// fresh authType reached the connect path.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/state/profiles_providers.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/storage/profiles_store.dart';
import 'package:mobissh/storage/secrets_store.dart';
import 'package:mobissh/ui/connect_form.dart';

const String _testKeyPem = '''
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACB85qILD6Ykve+v2FrQWtcrsjW1baL6CXJ4LD5mmiDTdgAAAJgTrJmWE6yZ
lgAAAAtzc2gtZWQyNTUxOQAAACB85qILD6Ykve+v2FrQWtcrsjW1baL6CXJ4LD5mmiDTdg
AAAEBbgsew/IHGlnh7mBUSl/1dndeVjG9AmMGYWl0TNGsVK3zmogsPpiS976/YWtBa1yuy
NbVtovoJcngsPmaaINN2AAAAFXRlc3R1c2VyQG1vYmlzc2gtdGVzdA==
-----END OPENSSH PRIVATE KEY-----
''';

Future<void> _pumpFrames(WidgetTester tester, {int count = 12}) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets(
    're-import upsert to KEY auth: next tap connects with auth.type=key (#595)',
    (tester) async {
      // 1. Pre-seed the store with a STALE PASSWORD profile that ALSO has a
      //    usable password secret. This is deliberately the hardest case: if
      //    the list serves the stale object, `_connectFromProfile` sees
      //    authType=password + a usable password and connects in PASSWORD mode
      //    — the bug. Seeding a password secret here means a stale authType
      //    cannot be masked by the keyVaultId-inference fallback (which only
      //    fires when authType is null). The ONLY thing that flips the connect
      //    to KEY mode is the upsert refreshing the per-profile authType.
      const pwVaultId = 'v-box';
      const keyVaultId = 'k-box';
      final secrets = SecretsStore(backend: InMemorySecretsBackend());
      await secrets.write(pwVaultId, <String, Object?>{'password': 'stalepw'});
      await secrets.write(keyVaultId, <String, Object?>{'data': _testKeyPem});

      final store = ProfilesStore();
      await store.save(<SavedProfile>[
        SavedProfile(
          title: 'fd-dev (stale password)',
          host: 'box.example',
          port: 2222,
          username: 'testuser',
          authType: 'password',
          vaultId: pwVaultId,
        ),
      ]);

      // 2. Capture the connect command the proxy dispatches across the gateway.
      final pair = InMemoryGatewayPair();
      final connectCommands = <Map<String, dynamic>>[];
      final sub = pair.taskSide.incoming.listen((payload) {
        if (payload['kind'] == 'connect') {
          connectCommands.add(Map<String, dynamic>.from(payload));
        }
      });
      addTearDown(() async {
        await sub.cancel();
        await pair.dispose();
      });

      final container = ProviderContainer(
        overrides: [
          taskSshGatewayProvider.overrideWithValue(pair.uiSide),
          profilesStoreProvider.overrideWithValue(store),
          secretsStoreProvider.overrideWithValue(secrets),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: SingleChildScrollView(child: ConnectForm())),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 3. Re-import the SAME identity, now KEY auth, through the real dialog.
      //    Plain (no-vault) envelope → single-stage submit. This upserts the
      //    stale profile (added=0, updated=1) — the #547 follow-up case.
      final envelope = jsonEncode(<String, Object?>{
        'version': 1,
        'profiles': <Map<String, dynamic>>[
          <String, dynamic>{
            'title': 'fd-dev',
            'host': 'box.example',
            'port': 2222,
            'username': 'testuser',
            'authType': 'key',
            'keyVaultId': keyVaultId,
          },
        ],
      });

      await tester.tap(find.byKey(const Key('open-import-profiles-dialog')));
      await tester.pumpAndSettle();
      // Expand the paste disclosure, then paste + submit.
      await tester.tap(
        find.byKey(const Key('import-profiles-paste-disclosure')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('import-profiles-input')),
        envelope,
      );
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.byKey(const Key('import-profiles-submit')));
      await tester.pumpAndSettle();

      // The store now holds the upserted KEY profile.
      final loaded = await store.load();
      expect(
        loaded.single.authType,
        'key',
        reason: 'store must hold the upserted authType=key',
      );

      // 4. Tap the formerly-stale profile. With a fresh authType it must
      //    connect in KEY mode. The bug: a stale authType (null/password)
      //    routes to password mode (or the no-creds editor fallback), so the
      //    connect command's auth.type is NOT 'key'.
      await tester.tap(
        find.byKey(const Key('profile-tile-box.example:2222:testuser')),
      );
      await _pumpFrames(tester, count: 40);

      expect(
        connectCommands,
        isNotEmpty,
        reason:
            'tapping the upserted profile must dispatch a connect — a '
            'stale authType=null with no usable creds opens the editor '
            'instead of connecting',
      );
      final auth = Map<String, dynamic>.from(
        connectCommands.last['auth'] as Map,
      );
      expect(
        auth['type'],
        'key',
        reason:
            'connect must use KEY auth after the upsert changed '
            'authType from null → key (the #547 follow-up bug: stale '
            'per-profile authType applied in password mode)',
      );
    },
  );
}
