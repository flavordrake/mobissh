// Widget tests for the AppLifecycleState observer wiring (#525).
//
// Pumps a `ProviderScope`-wrapped widget that mounts the
// `AppLifecycleObserver`, simulates a pause → resume cycle via
// `WidgetsBinding.instance.handleAppLifecycleStateChanged`, and asserts the
// `lifecycleProvider` reflects each transition.
//
// This is the integration point that the Phase 4 PR (#524) will hook into
// for SshSessionController rebind. Here we only verify the event becomes
// addressable.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/state/lifecycle_providers.dart';

void main() {
  testWidgets('AppLifecycleObserver mirrors pause/resume into the provider',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final emissions = <AppLifecycleState>[];
    container.listen<AppLifecycleState>(
      lifecycleProvider,
      (prev, next) => emissions.add(next),
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const AppLifecycleObserver(child: SizedBox.shrink()),
      ),
    );

    // Sanity: default state is resumed (app is foregrounded at boot).
    expect(container.read(lifecycleProvider), AppLifecycleState.resumed);

    // Simulate the framework dispatching a lifecycle change.
    WidgetsBinding.instance
        .handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(container.read(lifecycleProvider), AppLifecycleState.paused);

    WidgetsBinding.instance
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(container.read(lifecycleProvider), AppLifecycleState.resumed);

    expect(emissions, <AppLifecycleState>[
      AppLifecycleState.paused,
      AppLifecycleState.resumed,
    ]);
  });

  testWidgets('AppLifecycleObserver removes itself on dispose', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const AppLifecycleObserver(child: SizedBox.shrink()),
      ),
    );

    // Replace the tree with an empty one so the observer disposes.
    await tester.pumpWidget(const SizedBox.shrink());

    // After dispose, dispatching a lifecycle change must not touch the
    // (now-disposed) container. We assert by verifying the provider read is
    // safe and reflects whatever was last written before dispose.
    final beforeDispatch = container.read(lifecycleProvider);
    WidgetsBinding.instance
        .handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(container.read(lifecycleProvider), beforeDispatch);
  });
}
