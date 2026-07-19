// #1086 — keybar visibility resolution + the explicit-choice flag.
//
// resolveKeybarVisible is the pure decision the layout sites use: hide the
// keybar by default in large-landscape (hardware keyboard assumed) UNLESS the
// user has explicitly toggled it, in which case the stored value wins verbatim.
// setKeybarVisible must record that explicit choice so it survives the layout
// default.

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
  addTearDown(() async => pair.dispose());
  addTearDown(container.dispose);
  return container;
}

SessionEntry _add(ProviderContainer c, String host) {
  return c.read(sessionsProvider.notifier).addOrActivate(
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

  group('resolveKeybarVisible (#1086)', () {
    test('no explicit choice, phone → keybar shown (default)', () {
      expect(
        resolveKeybarVisible(
          visible: keybarVisibleDefault,
          explicit: false,
          largeLandscape: false,
        ),
        isTrue,
      );
    });

    test('no explicit choice, large-landscape → keybar hidden by default', () {
      expect(
        resolveKeybarVisible(
          visible: keybarVisibleDefault,
          explicit: false,
          largeLandscape: true,
        ),
        isFalse,
      );
    });

    test('explicit visible wins even in large-landscape', () {
      expect(
        resolveKeybarVisible(
          visible: true,
          explicit: true,
          largeLandscape: true,
        ),
        isTrue,
      );
    });

    test('explicit hidden wins even on a phone', () {
      expect(
        resolveKeybarVisible(
          visible: false,
          explicit: true,
          largeLandscape: false,
        ),
        isFalse,
      );
    });
  });

  group('SessionAppearance keybar explicit flag (#1086)', () {
    test('a fresh session has not made an explicit keybar choice', () {
      final c = _makeContainer();
      final a = _add(c, 'host-a');
      expect(c.read(sessionKeybarVisibleExplicitProvider(a.id)), isFalse);
      expect(c.read(sessionKeybarVisibleProvider(a.id)), keybarVisibleDefault);
    });

    test('setKeybarVisible marks the choice explicit', () {
      final c = _makeContainer();
      final a = _add(c, 'host-a');
      c.read(sessionAppearanceProvider.notifier).setKeybarVisible(a.id, false);
      expect(c.read(sessionKeybarVisibleProvider(a.id)), isFalse);
      expect(c.read(sessionKeybarVisibleExplicitProvider(a.id)), isTrue);
    });

    test('the explicit flag is per-session (no leakage)', () {
      final c = _makeContainer();
      final a = _add(c, 'host-a');
      final b = _add(c, 'host-b');
      c.read(sessionAppearanceProvider.notifier).setKeybarVisible(a.id, true);
      expect(c.read(sessionKeybarVisibleExplicitProvider(a.id)), isTrue);
      expect(
        c.read(sessionKeybarVisibleExplicitProvider(b.id)),
        isFalse,
        reason: 'B made no choice; A toggling must not mark B explicit',
      );
    });

    test('copyWith preserves the explicit flag when not overridden', () {
      const base = SessionAppearance(
        themeIndex: 0,
        fontSize: 13,
        keybarVisibleExplicit: true,
      );
      expect(base.copyWith(fontSize: 20).keybarVisibleExplicit, isTrue);
      expect(
        base.copyWith(keybarVisibleExplicit: false).keybarVisibleExplicit,
        isFalse,
      );
    });

    test('equality + hashCode account for the explicit flag', () {
      const a = SessionAppearance(themeIndex: 0, fontSize: 13);
      const b = SessionAppearance(
        themeIndex: 0,
        fontSize: 13,
        keybarVisibleExplicit: true,
      );
      expect(a == b, isFalse);
      expect(a.hashCode == b.hashCode, isFalse);
    });
  });
}
