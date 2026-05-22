// Riverpod providers exposing the SSH session lifecycle to the UI layer.
//
// Phase 1 (#501): UI watches `sshSessionDataProvider` for the immutable
// snapshot; mutations go through `sshSessionControllerProvider`.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ssh/ssh_session.dart';

/// Singleton SshSessionController. Disposed when the provider container
/// disposes (i.e. on app shutdown).
final sshSessionControllerProvider =
    Provider<SshSessionController>((ref) {
  final controller = SshSessionController();
  ref.onDispose(() => controller.dispose());
  return controller;
});

/// Streams the controller's state to UI. Falls back to the controller's
/// current snapshot so the UI sees state before the first stream event.
final sshSessionDataProvider = StreamProvider<SshSessionData>((ref) async* {
  final controller = ref.watch(sshSessionControllerProvider);
  yield controller.data;
  yield* controller.stream;
});
