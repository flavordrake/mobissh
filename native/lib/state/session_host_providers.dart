// Wiring for the task-side session host (#524).
//
// Lazily constructs the [SessionHost] + an in-memory [InMemoryGatewayPair] so
// the IPC contract is exercised even before the controllers physically move
// to the foreground task isolate. The host's `Map<sessionId,
// SshSessionController>` lives in this same Dart isolate today; future work
// relocates it to the task isolate without touching the providers below
// (the gateway is the only seam that changes).

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/session_host.dart';
import '../services/task_ssh_gateway.dart';

/// Holds the gateway pair so the host (task side) and any UI-side proxies
/// share the same in-memory transport. Disposed when the provider container
/// is torn down.
final gatewayPairProvider = Provider<InMemoryGatewayPair>((ref) {
  final pair = InMemoryGatewayPair();
  ref.onDispose(pair.dispose);
  return pair;
});

/// Task-side session host. Reads the gateway pair so each consumer of
/// `gatewayPairProvider` sees a host bound to the same transport.
final sessionHostProvider = Provider<SessionHost>((ref) {
  final pair = ref.watch(gatewayPairProvider);
  final host = SessionHost(gateway: pair.taskSide);
  ref.onDispose(host.dispose);
  return host;
});
