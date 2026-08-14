// Widget test: a plain (no-vault) re-import upsert must NOT rebind an existing
// local profile's credentials (#1106 supersedes the old #595/#547 behavior).
//
// History: #595 (a #547 follow-up) wanted a plain re-import to REBIND an
// existing profile's authType + keyVaultId so the next tap connected in the new
// mode. #1106 found that exact behavior is a credential-theft vector: vault ids
// are predictable, so a crafted plain import naming another host's stored
// secret (or, on a collision, rebinding the profile to an arbitrary stored
// secret) authenticates with a credential the importer never possessed. The
// fix: a plain import can only refresh NON-SECRET metadata on a collision; the
// credential bundle (authType/vaultId/keyVaultId) and auto-run config are
// FROZEN. Rebinding a real credential now requires the profile editor or an
// encrypted backup that carries the secret.
//
// We seed the profile as authType=password WITH a usable password secret, then
// plain-re-import it as authType=key naming an EXISTING local key secret. The
// secure contract: the upsert leaves the credential bundle untouched, so the
// next tap still connects in PASSWORD mode (the frozen secret) — it does NOT
// pick up the injected key.
//
// Observable contract (no inline connect form exists post-#583): tapping a
// profile routes through `_connectFromProfile`, which resolves the profile's
// authType + vault credentials and dispatches `proxy.connect`. The connect
// command crosses the in-memory gateway as a JSON payload carrying
// `auth: {type: 'key'|'password', ...}`. We capture that payload on the task
// side and assert `auth.type == 'password'` after the upsert — proof the
// injected key never reached the connect path.

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
    'plain re-import does NOT rebind an existing profile to an injected key; '
    'next tap still connects in PASSWORD mode (#1106, supersedes #595)',
    (tester) async {
      // 1. Pre-seed the store with a PASSWORD profile that has a usable
      //    password secret. A plain re-import naming a key handle must NOT flip
      //    it to key mode (that is the #1106 injection). The next tap must keep
      //    connecting with the frozen password credential.
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
            home: Scaffold(body: ConnectForm()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 3. Re-import the SAME identity, now KEY auth naming an existing local
      //    key secret, through the real dialog. Plain (no-vault) envelope →
      //    single-stage submit. This upserts the profile (added=0, updated=1)
      //    but must leave its credential bundle frozen (#1106).
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

      // The store still holds the ORIGINAL password bundle — the plain import
      // could not rebind it (#1106). The injected key handle was dropped.
      final loaded = await store.load();
      expect(
        loaded.single.authType,
        'password',
        reason: 'plain import must NOT flip authType on a collision (#1106)',
      );
      expect(
        loaded.single.keyVaultId,
        isNull,
        reason: 'plain import must NOT bind the injected keyVaultId (#1106)',
      );
      expect(
        loaded.single.vaultId,
        pwVaultId,
        reason: 'the original credential handle is preserved (#1106)',
      );

      // 4. Tap the profile. With its bundle frozen it connects in PASSWORD
      //    mode using the original secret — never the injected key.
      await tester.tap(
        find.byKey(const Key('profile-tile-box.example:2222:testuser')),
      );
      await _pumpFrames(tester, count: 40);

      expect(
        connectCommands,
        isNotEmpty,
        reason: 'the profile keeps a usable password credential, so tapping '
            'it dispatches a connect',
      );
      final auth = Map<String, dynamic>.from(
        connectCommands.last['auth'] as Map,
      );
      expect(
        auth['type'],
        'password',
        reason:
            'connect must stay in PASSWORD mode — the plain import could not '
            'rebind the profile to the injected key (#1106)',
      );
    },
  );
}
