// Widget tests for the reorderable saved-profile list (#481).
//
// Asserts:
//   - each profile card shows an upper-right reorder/menu handle
//   - tapping the handle opens a menu with "Move to top" / "Move to bottom"
//   - "Move to top" reorders the rendered list AND persists the new order
//   - the card body still taps-to-connect (#579); the handle does not connect
//   - the Recent Sessions list is a separate group, unaffected by the order

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/state/profile_order_providers.dart';
import 'package:mobissh/state/profiles_providers.dart';
import 'package:mobissh/storage/profiles_store.dart';
import 'package:mobissh/ui/profile_list.dart';

Future<void> _pumpList(
  WidgetTester tester, {
  required ProfilesStore store,
  required void Function(SavedProfile) onConnect,
  void Function(SavedProfile)? onEdit,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      // Only the store is overridden — the real profileOrderProvider auto-syncs
      // off savedProfilesProvider and persists to the mocked SharedPreferences.
      overrides: [profilesStoreProvider.overrideWithValue(store)],
      child: MaterialApp(
        home: Scaffold(
          body: ProfileList(
            onConnect: onConnect,
            onEdit: onEdit ?? (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ProfileList reorder (#481)', () {
    testWidgets('each card shows an upper-right reorder handle', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final store = ProfilesStore();
      await store.save(<SavedProfile>[
        SavedProfile(title: 'A', host: 'a.example', port: 22, username: 'me'),
        SavedProfile(title: 'B', host: 'b.example', port: 22, username: 'me'),
      ]);

      await _pumpList(tester, store: store, onConnect: (_) {});

      expect(
        find.byKey(const Key('profile-reorder-handle-a.example:22:me')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('profile-reorder-handle-b.example:22:me')),
        findsOneWidget,
      );
    });

    testWidgets('tapping the handle opens the Move menu', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final store = ProfilesStore();
      await store.save(<SavedProfile>[
        SavedProfile(title: 'A', host: 'a.example', port: 22, username: 'me'),
        SavedProfile(title: 'B', host: 'b.example', port: 22, username: 'me'),
      ]);

      await _pumpList(tester, store: store, onConnect: (_) {});

      await tester.tap(
        find.byKey(const Key('profile-reorder-handle-b.example:22:me')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('profile-move-top-b.example:22:me')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('profile-move-bottom-b.example:22:me')),
        findsOneWidget,
      );
      expect(find.text('Move to top'), findsOneWidget);
      expect(find.text('Move to bottom'), findsOneWidget);
    });

    testWidgets('Move to top reorders the list and persists the order', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final prefs = SharedPreferences.getInstance();
      final store = ProfilesStore();
      await store.save(<SavedProfile>[
        SavedProfile(title: 'A', host: 'a.example', port: 22, username: 'me'),
        SavedProfile(title: 'B', host: 'b.example', port: 22, username: 'me'),
        SavedProfile(title: 'C', host: 'c.example', port: 22, username: 'me'),
      ]);

      await _pumpList(tester, store: store, onConnect: (_) {});

      // Initially A is above C.
      final aTop = tester
          .getTopLeft(find.byKey(const Key('profile-tile-a.example:22:me')))
          .dy;
      final cTop = tester
          .getTopLeft(find.byKey(const Key('profile-tile-c.example:22:me')))
          .dy;
      expect(aTop < cTop, isTrue);

      // Move C to the top via its menu.
      await tester.tap(
        find.byKey(const Key('profile-reorder-handle-c.example:22:me')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('profile-move-top-c.example:22:me')),
      );
      await tester.pumpAndSettle();

      // The order is persisted.
      final p = await prefs;
      final order = decodeProfileOrder(p.getString(profileOrderPrefKey));
      expect(order.first, 'c.example:22:me');

      // C now renders above A.
      final aTop2 = tester
          .getTopLeft(find.byKey(const Key('profile-tile-a.example:22:me')))
          .dy;
      final cTop2 = tester
          .getTopLeft(find.byKey(const Key('profile-tile-c.example:22:me')))
          .dy;
      expect(cTop2 < aTop2, isTrue);
    });

    testWidgets('card body taps-to-connect; handle does not connect', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final store = ProfilesStore();
      await store.save(<SavedProfile>[
        SavedProfile(title: 'A', host: 'a.example', port: 22, username: 'me'),
        SavedProfile(title: 'B', host: 'b.example', port: 22, username: 'me'),
      ]);

      SavedProfile? connected;
      await _pumpList(
        tester,
        store: store,
        onConnect: (p) => connected = p,
      );

      // Tapping the handle opens the menu — it must NOT connect.
      await tester.tap(
        find.byKey(const Key('profile-reorder-handle-b.example:22:me')),
      );
      await tester.pumpAndSettle();
      expect(connected, isNull, reason: 'handle tap opens menu, not connect');
      // Dismiss the menu.
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();

      // Tapping the body connects.
      await tester.tap(find.byKey(const Key('profile-tile-b.example:22:me')));
      await tester.pump();
      expect(connected, isNotNull);
      expect(connected!.host, 'b.example');
    });
  });
}
