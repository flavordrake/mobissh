// Unit tests for the AppLifecycleState provider (#525).
//
// Verifies the provider's contract:
//   - default state is AppLifecycleState.resumed (app is foregrounded at boot)
//   - writing a new state updates the provider's current value
//   - ref.listen callback fires on each transition (paused, then resumed)
//
// The widget-layer hook that wires WidgetsBindingObserver to this provider is
// exercised in test/widget/app_lifecycle_test.dart. This file is pure-state.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/state/lifecycle_providers.dart';

void main() {
  group('lifecycleProvider', () {
    test('default state is AppLifecycleState.resumed', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(lifecycleProvider), AppLifecycleState.resumed);
    });

    test('writing a new state updates the current value', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(lifecycleProvider.notifier).state =
          AppLifecycleState.paused;
      expect(container.read(lifecycleProvider), AppLifecycleState.paused);

      container.read(lifecycleProvider.notifier).state =
          AppLifecycleState.resumed;
      expect(container.read(lifecycleProvider), AppLifecycleState.resumed);
    });

    test('ref.listen fires on each transition (paused → resumed)', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final emissions = <AppLifecycleState>[];
      container.listen<AppLifecycleState>(
        lifecycleProvider,
        (prev, next) => emissions.add(next),
      );

      container.read(lifecycleProvider.notifier).state =
          AppLifecycleState.paused;
      container.read(lifecycleProvider.notifier).state =
          AppLifecycleState.resumed;

      expect(emissions, <AppLifecycleState>[
        AppLifecycleState.paused,
        AppLifecycleState.resumed,
      ]);
    });
  });
}
