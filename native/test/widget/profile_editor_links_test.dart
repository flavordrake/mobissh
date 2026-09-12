// #1140 (PR B of #1117): the profile editor's `Links` section. Spec:
// docs/deep-link-intents.md §10, R5, R10, R12, R13.
//
// PINNED KEYS / STRINGS (the implementation must use these exactly; the
// section lives on the Details tab, which is the editor's default tab):
//   Key('profile-editor-links-section')    — the section header widget
//   Key('profile-editor-link-alias')        — TextField for linkAlias
//   Key('profile-editor-link-auto-connect') — SwitchListTile, title
//                                             'Always allow links to open this profile'
//   Key('profile-editor-link-url')          — SelectableText with the
//                                             profile's own link:
//       alias set:  mobissh://connect?name=<alias>
//       no alias:   mobissh://connect?host=<host>&port=<port>&user=<user>
//   Key('profile-editor-link-copy')         — Copy button for that link
//   inline field error on a duplicate alias (rendered by the alias field's
//   InputDecoration.errorText): 'Alias already used by another profile'
//
// R13: `linkAutoConnect` is bound to the identity it was granted for. When
// `_persist` saves with `newIdentity != _originalIdentityKey` (host, port
// OR username changed) it persists false regardless of the switch position.
// An identity-preserving save keeps the switch's value.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/state/profiles_providers.dart';
import 'package:mobissh/storage/profiles_store.dart';
import 'package:mobissh/storage/secrets_store.dart';
import 'package:mobissh/ui/profile_editor.dart';

const _aliasKey = Key('profile-editor-link-alias');
const _switchKey = Key('profile-editor-link-auto-connect');
const _linkKey = Key('profile-editor-link-url');
const _duplicateAliasError = 'Alias already used by another profile';

SavedProfile _box({String? linkAlias, bool linkAutoConnect = false}) =>
    SavedProfile(
      title: 'Box',
      host: 'home.example',
      port: 22,
      username: 'me',
      authType: 'password',
      linkAlias: linkAlias,
      linkAutoConnect: linkAutoConnect,
    );

/// Seed the store with [profiles], open the editor on the first one.
Future<ProfilesStore> _pumpWith(
  WidgetTester tester,
  List<SavedProfile> profiles,
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
      child: MaterialApp(home: ProfileEditor(profile: (await store.load()).first)),
    ),
  );
  await tester.pumpAndSettle();
  return store;
}

Future<void> _tapSave(WidgetTester tester) async {
  final save = find.byKey(const Key('profile-editor-save'));
  await tester.ensureVisible(save);
  await tester.pumpAndSettle();
  await tester.tap(save);
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, String key, String text) async {
  final field = find.byKey(Key(key));
  await tester.ensureVisible(field);
  await tester.pumpAndSettle();
  await tester.enterText(field, text);
  await tester.pumpAndSettle();
}

String _linkText(WidgetTester tester) =>
    tester.widget<SelectableText>(find.byKey(_linkKey)).data ?? '';

bool _switchValue(WidgetTester tester) =>
    tester.widget<SwitchListTile>(find.byKey(_switchKey)).value;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Links section — render', () {
    testWidgets('shows the section, alias field and switch reflecting the '
        'stored values', (tester) async {
      await _pumpWith(tester, [_box(linkAlias: 'box', linkAutoConnect: true)]);

      expect(find.byKey(const Key('profile-editor-links-section')),
          findsOneWidget);
      expect(
        tester.widget<TextField>(find.byKey(_aliasKey)).controller?.text,
        'box',
      );
      expect(_switchValue(tester), isTrue);
      expect(
        find.text('Always allow links to open this profile'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('profile-editor-link-copy')), findsOneWidget);
    });

    testWidgets('renders the name= link when an alias is set', (tester) async {
      await _pumpWith(tester, [_box(linkAlias: 'box')]);
      expect(_linkText(tester), 'mobissh://connect?name=box');
    });

    testWidgets('renders the identity-form link when no alias is set',
        (tester) async {
      await _pumpWith(tester, [_box()]);
      expect(
        _linkText(tester),
        'mobissh://connect?host=home.example&port=22&user=me',
      );
    });
  });

  group('Links section — save', () {
    testWidgets('a typed alias persists as linkAlias', (tester) async {
      final store = await _pumpWith(tester, [_box()]);

      await _enter(tester, 'profile-editor-link-alias', 'home-box');
      await _tapSave(tester);

      expect((await store.load()).single.linkAlias, 'home-box');
    });

    testWidgets('switching auto-connect on persists true when the identity '
        'is unchanged', (tester) async {
      final store = await _pumpWith(tester, [_box()]);

      final sw = find.byKey(_switchKey);
      await tester.ensureVisible(sw);
      await tester.pumpAndSettle();
      await tester.tap(sw);
      await tester.pumpAndSettle();
      await _tapSave(tester);

      expect((await store.load()).single.linkAutoConnect, isTrue);
    });

    testWidgets('a title-only edit keeps linkAutoConnect true', (tester) async {
      final store = await _pumpWith(tester, [_box(linkAutoConnect: true)]);

      await _enter(tester, 'profile-editor-title', 'Renamed box');
      await _tapSave(tester);

      final saved = (await store.load()).single;
      expect(saved.title, 'Renamed box');
      expect(saved.linkAutoConnect, isTrue);
    });
  });

  group('R13 — identity edit resets linkAutoConnect', () {
    testWidgets('changing the host with the switch ON persists false',
        (tester) async {
      final store = await _pumpWith(tester, [_box(linkAutoConnect: true)]);
      expect(_switchValue(tester), isTrue);

      await _enter(tester, 'profile-editor-host', 'other.example');
      await _tapSave(tester);

      final saved = (await store.load()).single;
      expect(saved.host, 'other.example');
      expect(saved.linkAutoConnect, isFalse);
    });

    testWidgets('changing the port with the switch ON persists false',
        (tester) async {
      final store = await _pumpWith(tester, [_box(linkAutoConnect: true)]);

      await _enter(tester, 'profile-editor-port', '2222');
      await _tapSave(tester);

      final saved = (await store.load()).single;
      expect(saved.port, 2222);
      expect(saved.linkAutoConnect, isFalse);
    });

    testWidgets('changing the username with the switch ON persists false',
        (tester) async {
      final store = await _pumpWith(tester, [_box(linkAutoConnect: true)]);

      await _enter(tester, 'profile-editor-username', 'someone');
      await _tapSave(tester);

      final saved = (await store.load()).single;
      expect(saved.username, 'someone');
      expect(saved.linkAutoConnect, isFalse);
    });
  });

  group('Links section — duplicate alias', () {
    testWidgets('shows the inline error and does not save', (tester) async {
      final store = await _pumpWith(tester, [
        _box(),
        SavedProfile(
          title: 'Other',
          host: 'other.example',
          port: 22,
          username: 'me',
          linkAlias: 'taken',
        ),
      ]);

      await _enter(tester, 'profile-editor-title', 'Renamed box');
      await _enter(tester, 'profile-editor-link-alias', 'taken');
      await _tapSave(tester);

      expect(find.text(_duplicateAliasError), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byKey(_aliasKey)).decoration?.errorText,
        _duplicateAliasError,
      );
      final list = await store.load();
      final box = list.firstWhere((p) => p.host == 'home.example');
      expect(box.title, 'Box', reason: 'refused save writes nothing');
      expect(box.linkAlias, isNull);
      expect(
        list.firstWhere((p) => p.host == 'other.example').linkAlias,
        'taken',
      );
    });
  });
}
