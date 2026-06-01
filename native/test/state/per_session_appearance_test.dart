// Per-session terminal theme + font size (#601, #571).
//
// These tests assert ISOLATION (memory: feedback_feature_scoping_and_isolation
// _tests), not merely that a per-session knob exists:
//   - Two sessions carry independent theme + font size; mutating one leaves the
//     other UNCHANGED (no leakage).
//   - Switching the active session does not mutate either session's values.
//   - A new session inherits the persisted global default, not another live
//     session's value.
//
// On the OLD global providers these would be RED: a single StateNotifier holds
// one index / one font size, so changing it for "session A" changes it for B.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/state/ui_prefs_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

ProviderContainer _makeContainer() {
  final pair = InMemoryGatewayPair();
  final container = ProviderContainer(
    overrides: [taskSshGatewayProvider.overrideWithValue(pair.uiSide)],
  );
  addTearDown(() async {
    await pair.dispose();
  });
  addTearDown(container.dispose);
  return container;
}

SessionEntry _add(ProviderContainer c, String host) {
  return c
      .read(sessionsProvider.notifier)
      .addOrActivate(
        SshConnectParams(
          host: host,
          port: 22,
          username: 'u',
          auth: const SshAuth.password('p'),
        ),
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('per-session terminal theme', () {
    test('changing one session theme does not leak to the other', () {
      final c = _makeContainer();
      final a = _add(c, 'host-a');
      final b = _add(c, 'host-b');

      final appearance = c.read(sessionAppearanceProvider.notifier);
      appearance.setTheme(a.id, 1);

      expect(c.read(sessionThemeProvider(a.id)), 1);
      expect(
        c.read(sessionThemeProvider(b.id)),
        terminalThemeDefault,
        reason: 'session B theme must be untouched by a change to A',
      );
    });

    test('cycle advances ONLY the named session', () {
      final c = _makeContainer();
      final a = _add(c, 'host-a');
      final b = _add(c, 'host-b');

      final appearance = c.read(sessionAppearanceProvider.notifier);
      appearance.cycleTheme(a.id);

      expect(c.read(sessionThemeProvider(a.id)), 1);
      expect(c.read(sessionThemeProvider(b.id)), terminalThemeDefault);
    });

    test('activeSessionTheme resolves the active session palette', () {
      final c = _makeContainer();
      final a = _add(c, 'host-a');
      final b = _add(c, 'host-b'); // b is now active

      c.read(sessionAppearanceProvider.notifier).setTheme(a.id, 1);

      // Active is b → still default palette.
      expect(
        c.read(activeSessionThemeProvider).label,
        terminalPalettes[terminalThemeDefault].label,
      );

      c.read(sessionsProvider.notifier).setActive(a.id);
      expect(
        c.read(activeSessionThemeProvider).label,
        terminalPalettes[1].label,
      );

      // Switching active did NOT change either stored value.
      expect(c.read(sessionThemeProvider(a.id)), 1);
      expect(c.read(sessionThemeProvider(b.id)), terminalThemeDefault);
    });
  });

  group('per-session font size', () {
    test('changing one session font does not leak to the other', () {
      final c = _makeContainer();
      final a = _add(c, 'host-a');
      final b = _add(c, 'host-b');

      c.read(sessionAppearanceProvider.notifier).setFontSize(a.id, 22);

      expect(c.read(sessionFontSizeProvider(a.id)), 22);
      expect(
        c.read(sessionFontSizeProvider(b.id)),
        fontSizeDefault,
        reason: 'session B font must be untouched by a change to A',
      );
    });

    test('adjustFont steps and clamps the named session only', () {
      final c = _makeContainer();
      final a = _add(c, 'host-a');
      final b = _add(c, 'host-b');

      final appearance = c.read(sessionAppearanceProvider.notifier);
      appearance.adjustFontSize(a.id, 2);
      expect(c.read(sessionFontSizeProvider(a.id)), fontSizeDefault + 2);
      expect(c.read(sessionFontSizeProvider(b.id)), fontSizeDefault);

      // Clamp below min.
      appearance.setFontSize(a.id, kFontSizeMin);
      appearance.adjustFontSize(a.id, -100);
      expect(c.read(sessionFontSizeProvider(a.id)), kFontSizeMin);

      // Clamp above max.
      appearance.setFontSize(a.id, kFontSizeMax);
      appearance.adjustFontSize(a.id, 100);
      expect(c.read(sessionFontSizeProvider(a.id)), kFontSizeMax);
    });

    test('switching active does not mutate any session font', () {
      final c = _makeContainer();
      final a = _add(c, 'host-a');
      final b = _add(c, 'host-b');

      final appearance = c.read(sessionAppearanceProvider.notifier);
      appearance.setFontSize(a.id, 20);
      appearance.setFontSize(b.id, 10);

      c.read(sessionsProvider.notifier).setActive(a.id);
      c.read(sessionsProvider.notifier).setActive(b.id);

      expect(c.read(sessionFontSizeProvider(a.id)), 20);
      expect(c.read(sessionFontSizeProvider(b.id)), 10);
    });
  });

  group('defaults + new-session inheritance', () {
    test('a fresh session reads the defaults', () {
      final c = _makeContainer();
      final a = _add(c, 'host-a');
      expect(c.read(sessionThemeProvider(a.id)), terminalThemeDefault);
      expect(c.read(sessionFontSizeProvider(a.id)), fontSizeDefault);
    });

    test('a new session inherits the persisted global default, not a live '
        'sibling value', () {
      final c = _makeContainer();
      final a = _add(c, 'host-a');

      // The owner shrinks + recolors session A. This must NOT become the value
      // a brand-new session B inherits — B inherits the persisted default.
      c.read(sessionAppearanceProvider.notifier).setFontSize(a.id, 26);
      c.read(sessionAppearanceProvider.notifier).setTheme(a.id, 1);

      final b = _add(c, 'host-b');
      expect(c.read(sessionFontSizeProvider(b.id)), fontSizeDefault);
      expect(c.read(sessionThemeProvider(b.id)), terminalThemeDefault);
    });

    // #616: the global default can change AFTER a session's terminal first
    // reads its per-session font — most importantly when the persisted default
    // hydrates from SharedPreferences asynchronously on a real device (the test
    // harness mocks prefs synchronously to empty, so this never reproduced
    // headlessly before). An un-customized session must TRACK the global
    // default: the family provider has to rebuild when the global notifier
    // changes, not just when the per-session map changes. On the old code these
    // are RED — the family providers only `watch` the map and `read` the
    // globals, so they never rebuild on a global change.
    test('an un-customized session tracks a later global font-size change', () {
      final c = _makeContainer();
      final a = _add(c, 'host-a');
      expect(c.read(sessionFontSizeProvider(a.id)), fontSizeDefault);

      // Global default changes (e.g. async prefs hydration / a future global
      // settings control). The session has no override, so it must follow.
      c.read(fontSizeProvider.notifier).set(20);
      expect(
        c.read(sessionFontSizeProvider(a.id)),
        20,
        reason: 'an un-customized session must reflect the new global default',
      );

      // Once the session HAS its own override, the global no longer leaks in.
      c.read(sessionAppearanceProvider.notifier).setFontSize(a.id, 11);
      c.read(fontSizeProvider.notifier).set(24);
      expect(
        c.read(sessionFontSizeProvider(a.id)),
        11,
        reason: 'a per-session override pins the value against global changes',
      );
    });

    test('an un-customized session tracks a later global theme change', () {
      final c = _makeContainer();
      final a = _add(c, 'host-a');
      expect(c.read(sessionThemeProvider(a.id)), terminalThemeDefault);

      c.read(terminalThemeProvider.notifier).set(1);
      expect(
        c.read(sessionThemeProvider(a.id)),
        1,
        reason: 'an un-customized session must reflect the new global theme',
      );

      c.read(sessionAppearanceProvider.notifier).setTheme(a.id, 0);
      c.read(terminalThemeProvider.notifier).set(2);
      expect(
        c.read(sessionThemeProvider(a.id)),
        0,
        reason: 'a per-session override pins the value against global changes',
      );
    });
  });
}
