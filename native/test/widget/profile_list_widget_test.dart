// Widget tests for [ProfileList] (#501).
//
// Asserts:
//   - empty-state hint renders when no profiles exist
//   - populated list renders one tile per profile
//   - tapping a tile fires onSelect with the correct profile

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
    testWidgets('renders empty-state hint when store has no profiles',
        (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: ProfileList(onSelect: (_) {}),
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
      // Seed prefs via a real ProfilesStore, then override the provider so
      // the widget's load() goes through the same store.
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final store = ProfilesStore();
      await store.save(<SavedProfile>[
        SavedProfile(
          title: 'Home', host: 'home.example', port: 22, username: 'me',
        ),
        SavedProfile(
          title: 'Work', host: 'work.example', port: 2222, username: 'me',
          color: '#ff8800',
        ),
      ]);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            profilesStoreProvider.overrideWithValue(store),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: ProfileList(onSelect: (_) {}),
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

    testWidgets('tapping a tile fires onSelect with the correct profile',
        (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final store = ProfilesStore();
      await store.save(<SavedProfile>[
        SavedProfile(
          title: 'A', host: 'a.example', port: 22, username: 'u1',
        ),
        SavedProfile(
          title: 'B', host: 'b.example', port: 22, username: 'u2',
        ),
      ]);

      SavedProfile? selected;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            profilesStoreProvider.overrideWithValue(store),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: ProfileList(onSelect: (p) => selected = p),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Tap the B tile.
      await tester.tap(find.byKey(const Key('profile-tile-b.example:22:u2')));
      await tester.pump();

      expect(selected, isNotNull);
      expect(selected!.host, 'b.example');
      expect(selected!.username, 'u2');
    });
  });
}
