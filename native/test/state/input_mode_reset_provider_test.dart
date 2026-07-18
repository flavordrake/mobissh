// Unit tests for the per-session input-mode reset signal (keybar Reset key).

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/state/input_mode_reset_provider.dart';

void main() {
  ProviderContainer makeContainer() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  group('InputModeResetNotifier', () {
    test('starts empty', () {
      final c = makeContainer();
      expect(c.read(inputModeResetProvider), isEmpty);
    });

    test('requestReset bumps the session counter monotonically', () {
      final c = makeContainer();
      final n = c.read(inputModeResetProvider.notifier);
      n.requestReset('s1');
      expect(c.read(inputModeResetProvider)['s1'], 1);
      n.requestReset('s1');
      expect(
        c.read(inputModeResetProvider)['s1'],
        2,
        reason: 'a second tap must fire again (counter, not a bool)',
      );
    });

    test('resets are isolated per session', () {
      final c = makeContainer();
      final n = c.read(inputModeResetProvider.notifier);
      n.requestReset('s1');
      n.requestReset('s1');
      n.requestReset('s2');
      final state = c.read(inputModeResetProvider);
      expect(state['s1'], 2);
      expect(state['s2'], 1);
    });
  });
}
