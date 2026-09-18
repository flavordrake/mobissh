// A9 (#1184, spec docs/jump-host.md R18/R19/R20) — pasting a config that
// carries a ProxyJump into the editor's "SSH config" tab.
//
// PINNED KEY: Key('profile-editor-import-notes') — the PERSISTENT note panel
// under the Details tab's Jump host picker. Import guidance the user must ACT
// on ("create that profile first") belongs where the action is, not in a
// vanishing toast (feedback_actionable_guidance_not_toast).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/state/profiles_providers.dart';
import 'package:mobissh/storage/profiles_store.dart';
import 'package:mobissh/storage/secrets_store.dart';
import 'package:mobissh/ui/profile_editor.dart';

SavedProfile _p(
  String title,
  String host, {
  int port = 22,
  String user = 'me',
  String? alias,
}) => SavedProfile(
  title: title,
  host: host,
  port: port,
  username: user,
  authType: 'password',
  linkAlias: alias,
);

/// Open the editor in CREATE mode over a store seeded with [profiles], paste
/// [config] into the SSH config tab and apply it.
Future<ProfilesStore> _pasteConfig(
  WidgetTester tester,
  List<SavedProfile> profiles,
  String config,
) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final store = ProfilesStore();
  await store.save(profiles);
  final secrets = SecretsStore(backend: InMemorySecretsBackend());

  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        profilesStoreProvider.overrideWithValue(store),
        secretsStoreProvider.overrideWithValue(secrets),
      ],
      child: MaterialApp(
        home: ProfileEditor(profile: blankProfile(), isNew: true),
      ),
    ),
  );
  await tester.pumpAndSettle();

  await tester.tap(find.byKey(const Key('profile-editor-tab-sshconfig')));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byKey(const Key('profile-editor-sshconfig-input')),
    config,
  );
  await tester.tap(find.byKey(const Key('profile-editor-sshconfig-apply')));
  await tester.pumpAndSettle();
  return store;
}

String _notesText(WidgetTester tester) {
  final panel = find.byKey(const Key('profile-editor-import-notes'));
  expect(panel, findsOneWidget);
  return tester
      .widgetList<Text>(find.descendant(of: panel, matching: find.byType(Text)))
      .map((t) => t.data ?? '')
      .join('\n');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ProfileEditor — ProxyJump import', () {
    testWidgets('R18: a resolvable alias hop is saved as jumpIdentityKey', (
      tester,
    ) async {
      final bastion = _p(
        'bastion',
        'bastion.example.com',
        user: 'ops',
        alias: 'bastion',
      );
      final store = await _pasteConfig(tester, [bastion], 'Host prod\n'
          '  HostName prod.example.com\n'
          '  User deploy\n'
          '  ProxyJump bastion\n');

      await tester.tap(find.byKey(const Key('profile-editor-save')));
      await tester.pumpAndSettle();

      final saved = (await store.load()).firstWhere(
        (p) => p.host == 'prod.example.com',
      );
      expect(saved.jumpIdentityKey, bastion.identityKey);
    });

    testWidgets('R18: an unresolved hop writes NO link and says create first', (
      tester,
    ) async {
      final store = await _pasteConfig(tester, const [], 'Host prod\n'
          '  HostName prod.example.com\n'
          '  User deploy\n'
          '  ProxyJump bastion\n');

      final notes = _notesText(tester);
      expect(notes, contains('bastion'));
      expect(notes.toLowerCase(), contains('create'));

      await tester.tap(find.byKey(const Key('profile-editor-save')));
      await tester.pumpAndSettle();

      final saved = (await store.load()).firstWhere(
        (p) => p.host == 'prod.example.com',
      );
      expect(
        saved.jumpIdentityKey,
        isNull,
        reason: 'never import a dangling jump reference',
      );
    });

    testWidgets('R19: an unsupported ProxyCommand names its reason', (
      tester,
    ) async {
      await _pasteConfig(tester, const [], 'Host prod\n'
          '  HostName prod.example.com\n'
          '  User deploy\n'
          '  ProxyCommand nc -X 5 -x proxy:1080 %h %p\n');

      final notes = _notesText(tester);
      expect(notes, contains('ProxyCommand'));
      expect(notes, contains('nc -X 5 -x proxy:1080 %h %p'));
    });

    testWidgets('R20: a two-hop chain links the intermediate hop too', (
      tester,
    ) async {
      final a = _p('a', 'a.example.com', alias: 'a');
      final b = _p('b', 'b.example.com', alias: 'b');
      final store = await _pasteConfig(tester, [a, b], 'Host prod\n'
          '  HostName prod.example.com\n'
          '  User deploy\n'
          '  ProxyJump a,b\n');

      await tester.tap(find.byKey(const Key('profile-editor-save')));
      await tester.pumpAndSettle();

      final all = await store.load();
      final saved = all.firstWhere((p) => p.host == 'prod.example.com');
      final savedB = all.firstWhere((p) => p.host == 'b.example.com');
      expect(saved.jumpIdentityKey, b.identityKey);
      expect(
        savedB.jumpIdentityKey,
        a.identityKey,
        reason: 'ProxyJump a,b imports as a CHAIN, not just the last link',
      );
    });

    testWidgets('a config without ProxyJump leaves the picker alone', (
      tester,
    ) async {
      await _pasteConfig(tester, const [], 'Host prod\n'
          '  HostName prod.example.com\n'
          '  User deploy\n');
      expect(
        find.byKey(const Key('profile-editor-import-notes')),
        findsNothing,
      );
    });
  });
}
