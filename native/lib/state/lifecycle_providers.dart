// AppLifecycleState awareness for the native rewrite (#525).
//
// Exposes the current Flutter `AppLifecycleState` as a Riverpod provider so
// consumers (Phase 4 #524: SshSessionController rebind on resume) can
// `ref.listen` for transitions. This module only makes the lifecycle event
// addressable — it does NOT itself rebind, reconnect, or alter keepalive
// behavior. That's the Phase 4 PR's job.
//
// Wiring: `AppLifecycleObserver` is mounted near the top of the widget tree
// (see `main.dart`). It registers a `WidgetsBindingObserver` on init and
// mirrors `didChangeAppLifecycleState` callbacks into `lifecycleProvider`.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Current Flutter app-lifecycle state. Defaults to `resumed` because the
/// widget tree is only built while the app is in the foreground; the observer
/// will update this as the framework dispatches lifecycle changes.
final lifecycleProvider =
    StateProvider<AppLifecycleState>((ref) => AppLifecycleState.resumed);

/// Widget that bridges Flutter's `WidgetsBindingObserver` into Riverpod.
///
/// Mount once, high in the tree (above any consumer of `lifecycleProvider`).
/// On `didChangeAppLifecycleState` it writes the new state to the provider so
/// `ref.listen(lifecycleProvider, ...)` callbacks fire on every transition.
///
/// Inert by design: this widget does not itself trigger reconnects or rebinds.
/// The Phase 4 PR (#524) wires a listener that drives those side effects.
class AppLifecycleObserver extends ConsumerStatefulWidget {
  const AppLifecycleObserver({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<AppLifecycleObserver> createState() =>
      _AppLifecycleObserverState();
}

class _AppLifecycleObserverState extends ConsumerState<AppLifecycleObserver>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Guard against post-dispose dispatches.
    if (!mounted) return;
    ref.read(lifecycleProvider.notifier).state = state;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
