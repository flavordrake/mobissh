// Widget tests for the profile-import goal: the two-tab editor, pasting an SSH
// config entry to fill Details, and reusing a stored key instead of re-pasting.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/state/profiles_providers.dart';
import 'package:mobissh/storage/profiles_store.dart';
import 'package:mobissh/storage/secrets_store.dart';
import 'package:mobissh/ui/profile_editor.dart';

String _fieldText(WidgetTester tester, String key) {
  final field = tester.widget<TextField>(find.byKey(Key(key)));
  return field.controller?.text ?? '';
}

Future<void> _pump(
  WidgetTester tester, {
  required ProfilesStore store,
  required SecretsStore secrets,
  required SavedProfile profile,
  bool isNew = false,
}) async {
  tester.view.physicalSize = const Size(1000, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        profilesStoreProvider.overrideWithValue(store),
        secretsStoreProvider.overrideWithValue(secrets),
      ],
      child: MaterialApp(home: ProfileEditor(profile: profile, isNew: isNew)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ProfileEditor — SSH config tab', () {
    testWidgets('both tabs render', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await _pump(
        tester,
        store: ProfilesStore(),
        secrets: SecretsStore(backend: InMemorySecretsBackend()),
        profile: blankProfile(),
        isNew: true,
      );
      expect(find.byKey(const Key('profile-editor-tab-details')), findsOneWidget);
      expect(
        find.byKey(const Key('profile-editor-tab-sshconfig')),
        findsOneWidget,
      );
    });

    testWidgets('pasting a config fills Details and returns to Details tab', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await _pump(
        tester,
        store: ProfilesStore(),
        secrets: SecretsStore(backend: InMemorySecretsBackend()),
        profile: blankProfile(),
        isNew: true,
      );

      await tester.tap(find.byKey(const Key('profile-editor-tab-sshconfig')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('profile-editor-sshconfig-input')),
        'Host prod\n'
            '  HostName prod.example.com\n'
            '  Port 2222\n'
            '  User deploy\n',
      );
      await tester.tap(find.byKey(const Key('profile-editor-sshconfig-apply')));
      await tester.pumpAndSettle();

      expect(_fieldText(tester, 'profile-editor-host'), 'prod.example.com');
      expect(_fieldText(tester, 'profile-editor-port'), '2222');
      expect(_fieldText(tester, 'profile-editor-username'), 'deploy');
      // Name was blank → auto-filled user@host.
      expect(_fieldText(tester, 'profile-editor-title'), 'deploy@prod.example.com');
    });

    testWidgets('an IdentityFile switches auth to key and shows a hint', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await _pump(
        tester,
        store: ProfilesStore(),
        secrets: SecretsStore(backend: InMemorySecretsBackend()),
        profile: blankProfile(),
        isNew: true,
      );

      await tester.tap(find.byKey(const Key('profile-editor-tab-sshconfig')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('profile-editor-sshconfig-input')),
        'Host box\n  HostName box.example.com\n  IdentityFile ~/.ssh/id_ed25519\n',
      );
      await tester.tap(find.byKey(const Key('profile-editor-sshconfig-apply')));
      await tester.pumpAndSettle();

      // Auth flipped to key → the PEM field is present, and the hint names the
      // referenced file.
      expect(find.byKey(const Key('profile-editor-key')), findsOneWidget);
      final hint = find.byKey(const Key('profile-editor-identityfile-hint'));
      expect(hint, findsOneWidget);
      expect(
        tester.widget<Text>(hint).data,
        contains('~/.ssh/id_ed25519'),
      );
    });

    testWidgets('exports the current profile as a copy-ready config block', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await _pump(
        tester,
        store: ProfilesStore(),
        secrets: SecretsStore(backend: InMemorySecretsBackend()),
        profile: SavedProfile(
          title: 'prod',
          host: 'prod.example.com',
          port: 2222,
          username: 'deploy',
        ),
      );

      await tester.tap(find.byKey(const Key('profile-editor-tab-sshconfig')));
      await tester.pumpAndSettle();

      final block = tester.widget<SelectableText>(
        find.byKey(const Key('profile-editor-sshconfig-export')),
      );
      final text = block.data ?? '';
      expect(text, contains('Host prod'));
      expect(text, contains('HostName prod.example.com'));
      expect(text, contains('Port 2222'));
      expect(text, contains('User deploy'));
      expect(
        find.byKey(const Key('profile-editor-sshconfig-copy')),
        findsOneWidget,
      );
    });

    testWidgets('export reflects live edits to the Details fields', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await _pump(
        tester,
        store: ProfilesStore(),
        secrets: SecretsStore(backend: InMemorySecretsBackend()),
        profile: blankProfile(),
        isNew: true,
      );

      // Blank host → the export shows the placeholder, no block yet.
      await tester.tap(find.byKey(const Key('profile-editor-tab-sshconfig')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('profile-editor-sshconfig-export-empty')),
        findsOneWidget,
      );

      // Fill Details, come back — the block now reflects the entered host/user.
      await tester.tap(find.byKey(const Key('profile-editor-tab-details')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('profile-editor-host')),
        'db.example.com',
      );
      await tester.enterText(
        find.byKey(const Key('profile-editor-username')),
        'root',
      );
      await tester.tap(find.byKey(const Key('profile-editor-tab-sshconfig')));
      await tester.pumpAndSettle();

      final text = tester
              .widget<SelectableText>(
                find.byKey(const Key('profile-editor-sshconfig-export')),
              )
              .data ??
          '';
      expect(text, contains('HostName db.example.com'));
      expect(text, contains('User root'));
    });

    testWidgets('Copy writes the config block to the clipboard', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        );
      });

      await _pump(
        tester,
        store: ProfilesStore(),
        secrets: SecretsStore(backend: InMemorySecretsBackend()),
        profile: SavedProfile(
          title: 'prod',
          host: 'prod.example.com',
          port: 2222,
          username: 'deploy',
        ),
      );
      await tester.tap(find.byKey(const Key('profile-editor-tab-sshconfig')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('profile-editor-sshconfig-copy')));
      await tester.pumpAndSettle();

      expect(copied, isNotNull);
      expect(copied, contains('Host prod'));
      expect(copied, contains('HostName prod.example.com'));
    });

    testWidgets('empty/no-host paste shows a message, fills nothing', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await _pump(
        tester,
        store: ProfilesStore(),
        secrets: SecretsStore(backend: InMemorySecretsBackend()),
        profile: blankProfile(),
        isNew: true,
      );
      await tester.tap(find.byKey(const Key('profile-editor-tab-sshconfig')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('profile-editor-sshconfig-input')),
        '# just a comment, no Host line\n',
      );
      await tester.tap(find.byKey(const Key('profile-editor-sshconfig-apply')));
      await tester.pumpAndSettle();

      expect(find.text('No host entry found in that config'), findsOneWidget);
    });
  });

  group('ProfileEditor — reuse a stored key', () {
    testWidgets(
      'selecting a stored key points the profile at it, writes no new secret',
      (tester) async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final store = ProfilesStore();
        // An existing key-auth profile whose key is already in the vault.
        const storedKeyVaultId = 'profile-key-existing.example:22:me';
        await store.save(<SavedProfile>[
          SavedProfile(
            title: 'deploy@existing',
            host: 'existing.example',
            port: 22,
            username: 'me',
            authType: 'key',
            keyVaultId: storedKeyVaultId,
          ),
        ]);
        final backend = InMemorySecretsBackend();
        final secrets = SecretsStore(backend: backend);
        await secrets.write(storedKeyVaultId, <String, Object?>{
          'data': '-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END-----',
        });
        final keyBlobsBefore = (await backend.readAll()).length;

        await _pump(
          tester,
          store: store,
          secrets: secrets,
          profile: blankProfile(),
          isNew: true,
        );

        // Fill a new host, switch to Key auth.
        await tester.enterText(
          find.byKey(const Key('profile-editor-host')),
          'new.example',
        );
        await tester.enterText(
          find.byKey(const Key('profile-editor-username')),
          'me',
        );
        await tester.tap(find.text('Key'));
        await tester.pumpAndSettle();

        // The key-source dropdown lists the stored key; pick it.
        await tester.tap(find.byKey(const Key('profile-editor-key-source')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Stored: deploy@existing').last);
        await tester.pumpAndSettle();

        // The stored-key note replaces the PEM field.
        expect(
          find.byKey(const Key('profile-editor-stored-key-note')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('profile-editor-key')), findsNothing);

        await tester.tap(find.byKey(const Key('profile-editor-save')));
        await tester.pumpAndSettle();

        final saved =
            (await store.load()).firstWhere((p) => p.host == 'new.example');
        expect(saved.authType, 'key');
        expect(
          saved.keyVaultId,
          storedKeyVaultId,
          reason: 'the new profile reuses the stored key by its vault id',
        );

        // No NEW secret blob was written — the vault still holds only the
        // original key entry.
        expect((await backend.readAll()).length, keyBlobsBefore);
      },
    );
  });
}
