// ignore_for_file: prefer_initializing_formals
// Abstraction over the UI ↔ foreground-task isolate channel (#524).
//
// The real implementation forwards through `FlutterForegroundTask.sendData…`
// / `addTaskDataCallback`. Tests use an in-memory pair of `StreamController`s
// so the wire contract can be exercised without binding to platform method
// channels (and without spinning up a real task isolate).
//
// Both sides see the gateway as: send a payload, listen for payloads. The
// payload is always `Map<String, dynamic>` so the same code path can encode
// to whatever the plugin's IPC marshaller expects.

import 'dart:async';

/// One half of the UI ↔ task channel. The UI proxy holds the
/// "ui-side" instance; the task-side session host holds the "task-side"
/// instance. They share the underlying transport.
abstract class TaskSshGateway {
  /// Push a JSON-shaped payload across the channel.
  void send(Map<String, dynamic> payload);

  /// Inbound payloads from the other side.
  Stream<Map<String, dynamic>> get incoming;

  /// Tear down. After dispose, [send] is a no-op and [incoming] is closed.
  Future<void> dispose();
}

/// Same-isolate gateway pair: UI side and task side both back to the same
/// pair of `StreamController`s but with the streams crossed. Used in tests
/// AND in production today — the real foreground task isolate work is
/// deferred (see issue #524 plan). The UI-side and task-side controllers
/// share the same Dart isolate; the gateway pattern is the abstraction that
/// makes the *future* split possible without rewiring callers.
class InMemoryGatewayPair {
  InMemoryGatewayPair()
      : _toTask = StreamController<Map<String, dynamic>>.broadcast(),
        _toUi = StreamController<Map<String, dynamic>>.broadcast();

  final StreamController<Map<String, dynamic>> _toTask;
  final StreamController<Map<String, dynamic>> _toUi;

  /// Gateway given to the UI proxy. Sends to the task, receives from the
  /// task.
  late final TaskSshGateway uiSide = _InMemoryGateway(
    sender: _toTask,
    receiver: _toUi.stream,
  );

  /// Gateway given to the task-side session host. Sends to the UI, receives
  /// from the UI.
  late final TaskSshGateway taskSide = _InMemoryGateway(
    sender: _toUi,
    receiver: _toTask.stream,
  );

  bool _disposed = false;

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (!_toTask.isClosed) await _toTask.close();
    if (!_toUi.isClosed) await _toUi.close();
  }
}

class _InMemoryGateway implements TaskSshGateway {
  _InMemoryGateway({
    required StreamController<Map<String, dynamic>> sender,
    required Stream<Map<String, dynamic>> receiver,
  })  : _sender = sender,
        incoming = receiver;

  final StreamController<Map<String, dynamic>> _sender;

  @override
  final Stream<Map<String, dynamic>> incoming;

  bool _disposed = false;

  @override
  void send(Map<String, dynamic> payload) {
    if (_disposed) return;
    if (_sender.isClosed) return;
    _sender.add(payload);
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
  }
}
