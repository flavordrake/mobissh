// Wiring for the task-side session host (#524, #531).
//
// The UI-side gateway resolved here is what `SshSessionProxy` consumers talk
// to. Two flavors exist:
//
//   - Production: `FlutterForegroundTaskGateway`, wired to FFT statics. The
//     actual `SessionHost` (and the `SSHClient` instances it owns) lives in
//     the foreground task isolate, constructed by `KeepaliveTaskHandler` so
//     the socket survives the UI isolate being killed (#531 acceptance).
//
//   - Test: `InMemoryGatewayPair`, a pair of in-isolate `StreamController`s.
//     Lets widget tests exercise the full IPC contract without binding to
//     platform method channels.
//
// Tests override [taskSshGatewayProvider] directly via
// `ProviderScope.overrides`; production code reads it through
// `sshSessionProxyProvider` (TODO follow-up) or directly.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/session_host.dart';
import '../services/task_ssh_gateway.dart';

/// In-memory gateway pair used by tests + by the legacy in-process host
/// resolver below. Disposed when the provider container tears down.
final gatewayPairProvider = Provider<InMemoryGatewayPair>((ref) {
  final pair = InMemoryGatewayPair();
  ref.onDispose(pair.dispose);
  return pair;
});

/// UI-side gateway the proxy + UI consumers talk to. Production resolves to a
/// [FlutterForegroundSshGateway] bound to FFT statics; tests override this
/// provider with a [TaskSshGateway] backed by `InMemoryGatewayPair.uiSide`.
final taskSshGatewayProvider = Provider<TaskSshGateway>((ref) {
  final gateway = FlutterForegroundSshGateway();
  ref.onDispose(gateway.dispose);
  return gateway;
});

/// Legacy in-process [SessionHost] provider — kept so the widget rebind test
/// and the existing UI scaffolding continue to resolve a host even when the
/// production gateway hasn't been swapped in. Production callers should NOT
/// read this provider; the task isolate constructs its own host via
/// [KeepaliveTaskHandler].
///
/// Tests that want to inspect host state use this provider directly so they
/// can call `host.ingestOutputForTest(...)` without crossing the gateway.
final sessionHostProvider = Provider<SessionHost>((ref) {
  final pair = ref.watch(gatewayPairProvider);
  final host = SessionHost(gateway: pair.taskSide);
  ref.onDispose(host.dispose);
  return host;
});
