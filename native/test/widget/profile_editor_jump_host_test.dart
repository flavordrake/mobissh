// A3 (+ R16) — the Details tab's "Jump host" picker (#1183, spec
// docs/jump-host.md R14, R15, R16).
//
// PINNED KEYS / STRINGS (the implementation must use these exactly; the
// picker lives on the Details tab, which is the editor's default tab):
//   Key('profile-editor-jump-host') — a DropdownButton<String?> whose value is
//       the profile's `jumpIdentityKey` (null = no jump host). Items are the
//       eligible OTHER profiles (value = their `identityKey`, label = their
//       title) plus one null-valued item labelled 'None'.
//   'Jump host'   — the field label.
//   'None'        — the clear option (R14).
//   Key('profile-jump-badge') — the profile-list row affordance naming the
//       jump host, so a chained connection is never invisible (R16).
//
// R15: the picker excludes the profile itself and any profile that would close
// a cycle — a cycle is rejected at SAVE time, which means it must not be
// OFFERABLE in the first place.
//
// Monochrome glyph only, no emoji (feedback_monochrome_icons_no_emoji).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/state/profiles_providers.dart';
import 'package:mobissh/storage/profiles_store.dart';
import 'package:mobissh/storage/secrets_store.dart';
import 'package:mobissh/ui/profile_editor.dart';
import 'package:mobissh/ui/profile_list.dart';

const _pickerKey = Key('profile-editor-jump-host');

SavedProfile _p(
  String title,
  String host, {
  String? jump,
  int port = 22,
  String user = 'me',
}) => SavedProfile(
  title: title,
  host: host,
  port: port,
  username: user,
  authType: 'password',
  jumpIdentityKey: jump,
);

/// Seed the store with [profiles] and open the editor on the one whose host is
/// [editHost].
Future<ProfilesStore> _pumpEditor(
  WidgetTester tester,
  List<SavedProfile> profiles, {
  required String editHost,
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final store = ProfilesStore();
  await store.save(profiles);
  final secrets = SecretsStore(backend: InMemorySecretsBackend());

  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final loaded = await store.load();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        profilesStoreProvider.overrideWithValue(store),
        secretsStoreProvider.overrideWithValue(secrets),
      ],
      child: MaterialApp(
        home: ProfileEditor(
          profile: loaded.firstWhere((p) => p.host == editHost),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return store;
}

DropdownButton<String?> _picker(WidgetTester tester) =>
    tester.widget<DropdownButton<String?>>(find.byKey(_pickerKey));

List<String?> _optionValues(WidgetTester tester) =>
    _picker(tester).items!.map((i) => i.value).toList();

Future<void> _choose(WidgetTester tester, String label) async {
  await tester.ensureVisible(find.byKey(_pickerKey));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(_pickerKey));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Future<void> _tapSave(WidgetTester tester) async {
  final save = find.byKey(const Key('profile-editor-save'));
  await tester.ensureVisible(save);
  await tester.pumpAndSettle();
  await tester.tap(save);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('A3 / R14 — the picker renders on the Details tab', () {
    testWidgets('shows a Jump host field with a None option', (tester) async {
      await _pumpEditor(
        tester,
        [_p('Target', 'target.example'), _p('Bastion', 'bastion.example')],
        editHost: 'target.example',
      );

      expect(find.byKey(_pickerKey), findsOneWidget);
      expect(find.text('Jump host'), findsOneWidget);
      expect(
        _optionValues(tester),
        contains(null),
        reason: 'R14 — "None" is an option, not an empty selection',
      );
    });

    testWidgets('seeds its value from the stored jumpIdentityKey', (tester) async {
      await _pumpEditor(
        tester,
        [
          _p('Target', 'target.example', jump: 'bastion.example:22:me'),
          _p('Bastion', 'bastion.example'),
        ],
        editHost: 'target.example',
      );

      expect(_picker(tester).value, 'bastion.example:22:me');
    });

    testWidgets('a profile with no jump host shows None selected', (tester) async {
      await _pumpEditor(
        tester,
        [_p('Target', 'target.example'), _p('Bastion', 'bastion.example')],
        editHost: 'target.example',
      );

      expect(_picker(tester).value, isNull);
    });
  });

  group('A3 / R15 — the picker excludes self and cycle-closers', () {
    testWidgets('the profile being edited is never offered as its own hop',
        (tester) async {
      await _pumpEditor(
        tester,
        [_p('Target', 'target.example'), _p('Bastion', 'bastion.example')],
        editHost: 'target.example',
      );

      expect(
        _optionValues(tester),
        isNot(contains('target.example:22:me')),
        reason: 'R15/R4 — a self-reference must not be offerable',
      );
      expect(_optionValues(tester), contains('bastion.example:22:me'));
    });

    testWidgets('a profile that already jumps THROUGH this one is excluded',
        (tester) async {
      // b -> target. Offering b as target's hop would close a 2-cycle.
      await _pumpEditor(
        tester,
        [
          _p('Target', 'target.example'),
          _p('B', 'b.example', jump: 'target.example:22:me'),
          _p('Free', 'free.example'),
        ],
        editHost: 'target.example',
      );

      expect(_optionValues(tester), isNot(contains('b.example:22:me')));
      expect(_optionValues(tester), contains('free.example:22:me'));
    });

    testWidgets('a TRANSITIVE cycle-closer is excluded too', (tester) async {
      // c -> b -> target. Choosing c would make target -> c -> b -> target.
      await _pumpEditor(
        tester,
        [
          _p('Target', 'target.example'),
          _p('B', 'b.example', jump: 'target.example:22:me'),
          _p('C', 'c.example', jump: 'b.example:22:me'),
        ],
        editHost: 'target.example',
      );

      expect(_optionValues(tester), isNot(contains('c.example:22:me')));
      expect(
        _optionValues(tester).where((v) => v != null),
        isEmpty,
        reason: 'every other profile in this fixture closes a cycle',
      );
    });

    testWidgets('with no other profiles the picker offers only None',
        (tester) async {
      await _pumpEditor(tester, [_p('Target', 'target.example')],
          editHost: 'target.example');

      expect(_optionValues(tester), [null]);
    });
  });

  group('A3 — saving writes the field, None clears it', () {
    testWidgets('choosing a profile then Save writes jumpIdentityKey',
        (tester) async {
      final store = await _pumpEditor(
        tester,
        [_p('Target', 'target.example'), _p('Bastion', 'bastion.example')],
        editHost: 'target.example',
      );

      await _choose(tester, 'Bastion');
      await _tapSave(tester);

      final saved = (await store.load())
          .firstWhere((p) => p.host == 'target.example');
      expect(saved.jumpIdentityKey, 'bastion.example:22:me');
    });

    testWidgets('choosing None then Save clears jumpIdentityKey to null',
        (tester) async {
      final store = await _pumpEditor(
        tester,
        [
          _p('Target', 'target.example', jump: 'bastion.example:22:me'),
          _p('Bastion', 'bastion.example'),
        ],
        editHost: 'target.example',
      );

      await _choose(tester, 'None');
      await _tapSave(tester);

      final saved = (await store.load())
          .firstWhere((p) => p.host == 'target.example');
      expect(
        saved.jumpIdentityKey,
        isNull,
        reason: 'the clear must reach storage — not merely reset the widget',
      );
    });

    testWidgets('a save that touches nothing else preserves the jump host',
        (tester) async {
      // The editor rebuilds the whole entry on save; the same class of bug as
      // the lost `forwards` (owner report 2026-09-04).
      final store = await _pumpEditor(
        tester,
        [
          _p('Target', 'target.example', jump: 'bastion.example:22:me'),
          _p('Bastion', 'bastion.example'),
        ],
        editHost: 'target.example',
      );

      await _tapSave(tester);

      final saved = (await store.load())
          .firstWhere((p) => p.host == 'target.example');
      expect(saved.jumpIdentityKey, 'bastion.example:22:me');
    });
  });

  group('R16 — a chained connection is visible in the profile list', () {
    testWidgets('a profile with a jump host renders a badge naming it',
        (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final store = ProfilesStore();
      await store.save([
        _p('Bastion', 'bastion.example'),
        _p('Target', 'target.example', jump: 'bastion.example:22:me'),
      ]);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [profilesStoreProvider.overrideWithValue(store)],
          child: MaterialApp(
            home: Scaffold(body: ProfileList(onConnect: (_) {}, onEdit: (_) {})),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('profile-jump-badge')), findsOneWidget);
      expect(
        find.textContaining('Bastion'),
        findsWidgets,
        reason: 'R16 — the row names the hop it routes through',
      );
    });

    testWidgets('a profile without a jump host renders no badge', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final store = ProfilesStore();
      await store.save([_p('Target', 'target.example')]);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [profilesStoreProvider.overrideWithValue(store)],
          child: MaterialApp(
            home: Scaffold(body: ProfileList(onConnect: (_) {}, onEdit: (_) {})),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('profile-jump-badge')), findsNothing);
    });
  });
}
