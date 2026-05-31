// Widget tests for [ProfileList] (#501, #579).
//
// Asserts:
//   - empty-state hint renders when no profiles exist
//   - populated list renders one tile per profile
//   - tapping a tile fires onConnect (tap-to-connect, #579) with the right profile
//   - tapping the row's edit pencil fires onEdit with the right profile (#579)

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/state/profiles_providers.dart';
import 'package:mobissh/storage/profiles_store.dart';
import 'package:mobissh/ui/profile_list.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ProfileList', () {
    testWidgets('renders empty-state hint when store has no profiles', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: ProfileList(onConnect: (_) {}, onEdit: (_) {}),
            ),
          ),
        ),
      );
      // Wait for the FutureProvider to resolve.
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('profile-list-empty')), findsOneWidget);
      expect(find.byKey(const Key('profile-list-populated')), findsNothing);
    });

    testWidgets('renders one tile per saved profile', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final store = ProfilesStore();
      await store.save(<SavedProfile>[
        SavedProfile(
          title: 'Home',
          host: 'home.example',
          port: 22,
          username: 'me',
        ),
        SavedProfile(
          title: 'Work',
          host: 'work.example',
          port: 2222,
          username: 'me',
          color: '#ff8800',
        ),
      ]);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [profilesStoreProvider.overrideWithValue(store)],
          child: MaterialApp(
            home: Scaffold(
              body: ProfileList(onConnect: (_) {}, onEdit: (_) {}),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('profile-list-populated')), findsOneWidget);
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Work'), findsOneWidget);
      expect(find.text('me@home.example:22'), findsOneWidget);
      expect(find.text('me@work.example:2222'), findsOneWidget);
    });

    testWidgets('tapping a tile fires onConnect with the correct profile', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final store = ProfilesStore();
      await store.save(<SavedProfile>[
        SavedProfile(title: 'A', host: 'a.example', port: 22, username: 'u1'),
        SavedProfile(title: 'B', host: 'b.example', port: 22, username: 'u2'),
      ]);

      SavedProfile? connected;
      SavedProfile? edited;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [profilesStoreProvider.overrideWithValue(store)],
          child: MaterialApp(
            home: Scaffold(
              body: ProfileList(
                onConnect: (p) => connected = p,
                onEdit: (p) => edited = p,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Tap the B tile body → connect, NOT edit.
      await tester.tap(find.byKey(const Key('profile-tile-b.example:22:u2')));
      await tester.pump();

      expect(connected, isNotNull);
      expect(connected!.host, 'b.example');
      expect(connected!.username, 'u2');
      expect(edited, isNull, reason: 'row tap must connect, not edit');
    });

    testWidgets(
      'tapping the edit pencil fires onEdit with the correct profile',
      (tester) async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final store = ProfilesStore();
        await store.save(<SavedProfile>[
          SavedProfile(title: 'A', host: 'a.example', port: 22, username: 'u1'),
          SavedProfile(title: 'B', host: 'b.example', port: 22, username: 'u2'),
        ]);

        SavedProfile? connected;
        SavedProfile? edited;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [profilesStoreProvider.overrideWithValue(store)],
            child: MaterialApp(
              home: Scaffold(
                body: ProfileList(
                  onConnect: (p) => connected = p,
                  onEdit: (p) => edited = p,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Tap A's edit pencil → edit, NOT connect.
        await tester.tap(find.byKey(const Key('profile-edit-a.example:22:u1')));
        await tester.pump();

        expect(edited, isNotNull);
        expect(edited!.host, 'a.example');
        expect(edited!.username, 'u1');
        expect(connected, isNull, reason: 'pencil must edit, not connect');
      },
    );
  });
}
