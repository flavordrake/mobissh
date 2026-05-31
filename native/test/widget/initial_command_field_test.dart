// Widget test: the connect form's "Initial command" field (#558).
//
//   1. The field exists on the connect form.
//   2. Tapping a saved profile that carries an `initialCommand` prefills it.
//   3. A profile without an `initialCommand` leaves the field empty.
//
// The form's profile list reads `savedProfilesProvider`; we override it with a
// fixed list so no real ProfilesStore IO happens. The chosen profiles have no
// vault references, so `_prefillFromVault` never runs.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/state/profiles_providers.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/storage/profiles_store.dart';
import 'package:mobissh/ui/connect_form.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _app(List<SavedProfile> profiles, InMemoryGatewayPair pair) {
  return ProviderScope(
    overrides: [
      savedProfilesProvider.overrideWith((ref) async => profiles),
      taskSshGatewayProvider.overrideWithValue(pair.uiSide),
    ],
    child: const MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: ConnectForm())),
    ),
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('connect form renders an initial-command field', (tester) async {
    final pair = InMemoryGatewayPair();
    addTearDown(() async => pair.dispose());
    await tester.pumpWidget(_app(const [], pair));
    await _settle(tester);

    expect(find.byKey(const Key('connect-initial-command')), findsOneWidget);
  });

  testWidgets('tapping a profile prefills its initialCommand', (tester) async {
    final pair = InMemoryGatewayPair();
    addTearDown(() async => pair.dispose());
    final profile = SavedProfile(
      title: 'Box',
      host: 'box.example',
      port: 22,
      username: 'me',
      initialCommand: 'tmux attach || tmux new',
    );
    await tester.pumpWidget(_app([profile], pair));
    await _settle(tester);

    await tester.tap(find.byKey(Key('profile-tile-${profile.identityKey}')));
    await _settle(tester);

    final field = tester.widget<TextField>(
      find.byKey(const Key('connect-initial-command')),
    );
    expect(field.controller?.text, 'tmux attach || tmux new');
  });

  testWidgets('profile without initialCommand leaves the field empty', (
    tester,
  ) async {
    final pair = InMemoryGatewayPair();
    addTearDown(() async => pair.dispose());
    final profile = SavedProfile(
      title: 'Plain',
      host: 'plain.example',
      port: 22,
      username: 'me',
    );
    await tester.pumpWidget(_app([profile], pair));
    await _settle(tester);

    await tester.tap(find.byKey(Key('profile-tile-${profile.identityKey}')));
    await _settle(tester);

    final field = tester.widget<TextField>(
      find.byKey(const Key('connect-initial-command')),
    );
    expect(field.controller?.text, isEmpty);
  });
}
