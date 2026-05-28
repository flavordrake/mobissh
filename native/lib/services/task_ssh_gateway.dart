// ignore_for_file: prefer_initializing_formals
// Abstraction over the UI ↔ foreground-task isolate channel (#524, #531).
//
// The production implementation forwards through
// `FlutterForegroundTask.sendData…` / `addTaskDataCallback`
// (see [FlutterForegroundSshGateway] + [TaskSideForegroundGateway]). Tests
// use an in-memory pair of `StreamController`s so the wire contract can be
// exercised without binding to platform method channels (and without
// spinning up a real task isolate).
//
// Both sides see the gateway as: send a payload, listen for payloads. The
// payload is always `Map<String, dynamic>` so the same code path can encode
// to whatever the plugin's IPC marshaller expects.

import 'dart:async';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../diagnostics/connect_trace.dart';

/// Build a one-line trace label for a gateway payload. Includes the message
/// `kind` and (when present) the `host:port` portion of the sessionId so
/// multi-session traces show which session each event belongs to —
/// previously every `recv state` / `recv closed` looked identical regardless
/// of session, making it impossible to tell which session dropped.
String _gwLabel(Map<String, dynamic> p) {
  final kind = p['kind'] ?? p['type'] ?? '?';
  final sid = p['sessionId'];
  if (sid is String && sid.isNotEmpty) {
    final parts = sid.split(':');
    // sessionId format: host:port:user:createdAtMs — host:port is the unique
    // human-readable handle that maps cleanly to a profile.
    if (parts.length >= 2) return '$kind sid=${parts[0]}:${parts[1]}';
    return '$kind sid=$sid';
  }
  return '$kind';
}

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
  }) : _sender = sender,
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

// ---------------------------------------------------------------------------
// Production gateway (#531) — `flutter_foreground_task`-backed transport.
// ---------------------------------------------------------------------------

/// Low-level transport used by the FFT-backed gateways. Production wires this
/// to `FlutterForegroundTask` static methods; tests inject [StubFftTransport]
/// so the gateway logic is exercised without binding to platform channels.
///
/// The transport is direction-aware: the UI side and the task side speak
/// different methods (UI → task uses `sendDataToTask`, task → UI uses
/// `sendDataToMain`). Both sides listen via callbacks (`addTaskDataCallback`
/// on the UI side; `TaskHandler.onReceiveData` on the task side).
abstract class FftTransport {
  /// Push a payload toward the other end.
  void send(Object payload);

  /// Register a listener invoked when the other end sends us a payload.
  /// Returns a cancel function the gateway will call on dispose.
  void Function() registerReceiver(void Function(Object data) onData);
}

/// Production transport for the UI isolate. Uses
/// `FlutterForegroundTask.sendDataToTask` to push commands toward the task,
/// and `FlutterForegroundTask.addTaskDataCallback` to receive events from the
/// task.
class UiSideFftTransport implements FftTransport {
  const UiSideFftTransport();

  @override
  void send(Object payload) {
    FlutterForegroundTask.sendDataToTask(payload);
  }

  @override
  void Function() registerReceiver(void Function(Object data) onData) {
    FlutterForegroundTask.addTaskDataCallback(onData);
    return () => FlutterForegroundTask.removeTaskDataCallback(onData);
  }
}

/// Production transport for the task isolate. Uses
/// `FlutterForegroundTask.sendDataToMain` to push events toward the UI, and
/// a manual receiver register because the task isolate's inbound payloads
/// arrive through `TaskHandler.onReceiveData` — the host wires that to the
/// transport via [TaskSideFftTransport.deliver].
class TaskSideFftTransport implements FftTransport {
  TaskSideFftTransport();

  void Function(Object data)? _receiver;

  /// Called by [KeepaliveTaskHandler.onReceiveData] to push an incoming
  /// payload through to whatever receiver the gateway registered.
  void deliver(Object data) {
    final r = _receiver;
    if (r != null) r(data);
  }

  @override
  void send(Object payload) {
    FlutterForegroundTask.sendDataToMain(payload);
  }

  @override
  void Function() registerReceiver(void Function(Object data) onData) {
    _receiver = onData;
    return () {
      if (_receiver == onData) _receiver = null;
    };
  }
}

/// Shared encoder/decoder. The transport carries `Object` (because FFT's
/// SendPort is `Object?`-typed); the gateway always serializes to
/// `Map<String, dynamic>`. When the platform marshaller hands us a typed-key
/// `Map` we coerce to `Map<String, dynamic>` so downstream `fromJson` calls
/// see the expected type.
Map<String, dynamic>? _coercePayload(Object? raw) {
  if (raw is Map<String, dynamic>) return raw;
  if (raw is Map) {
    return raw.map((k, v) => MapEntry(k.toString(), v));
  }
  return null;
}

/// Production [TaskSshGateway] for the UI isolate side.
///
/// #539: `startService` is async and the task isolate's `onStart` (which builds
/// the `SessionHost` and registers the receiver) runs later still. A command
/// sent via `sendDataToTask` in that gap is dropped — the task isn't listening
/// yet — which deadlocked connect at `idle`. To close the gap the gateway
/// BUFFERS outbound payloads until it has seen the first inbound payload from
/// the task (typically a [SshTaskReadyEvent]). Once ready, the buffer flushes
/// front-to-back (preserving connect → input → resize order) and subsequent
/// sends pass through immediately.
class FlutterForegroundSshGateway implements TaskSshGateway {
  FlutterForegroundSshGateway({FftTransport? transport})
    : _transport = transport ?? const UiSideFftTransport() {
    _cancel = _transport.registerReceiver(_onData);
  }

  final FftTransport _transport;
  final StreamController<Map<String, dynamic>> _incoming =
      StreamController<Map<String, dynamic>>.broadcast();
  void Function()? _cancel;
  bool _disposed = false;

  /// Whether the task has signalled it is listening. Until true, [send]
  /// queues into [_outboundBuffer] instead of hitting the transport.
  bool _ready = false;

  /// FIFO queue of payloads sent before the task became ready. Flushed in
  /// order once the first inbound payload arrives.
  final List<Map<String, dynamic>> _outboundBuffer = [];

  @override
  Stream<Map<String, dynamic>> get incoming => _incoming.stream;

  @override
  void send(Map<String, dynamic> payload) {
    if (_disposed) return;
    if (!_ready) {
      _outboundBuffer.add(payload);
      ctrace(
        'ui.gw',
        'send ${_gwLabel(payload)} BUFFERED (not ready, n=${_outboundBuffer.length})',
      );
      return;
    }
    ctrace('ui.gw', 'send ${_gwLabel(payload)} → transport (ready)');
    _transport.send(payload);
  }

  void _onData(Object data) {
    if (_disposed) return;
    final map = _coercePayload(data);
    if (map == null) {
      ctrace('ui.gw', 'recv: uncoercible payload ${data.runtimeType}');
      return;
    }
    // First inbound payload proves the task isolate is alive and listening:
    // flush anything we buffered during spin-up, in order (#539).
    if (!_ready) {
      _ready = true;
      final buffered = List<Map<String, dynamic>>.from(_outboundBuffer);
      _outboundBuffer.clear();
      ctrace(
        'ui.gw',
        'recv ${_gwLabel(map)} → READY; flushing ${buffered.length} buffered',
      );
      for (final p in buffered) {
        _transport.send(p);
      }
    } else {
      ctrace('ui.gw', 'recv ${_gwLabel(map)}');
    }
    if (!_incoming.isClosed) _incoming.add(map);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _outboundBuffer.clear();
    _cancel?.call();
    _cancel = null;
    if (!_incoming.isClosed) await _incoming.close();
  }
}

/// Production [TaskSshGateway] for the task isolate side. Built by
/// [KeepaliveTaskHandler] inside the foreground task isolate. The transport
/// is fed inbound payloads via `TaskHandler.onReceiveData` →
/// [TaskSideFftTransport.deliver].
class TaskSideForegroundGateway implements TaskSshGateway {
  TaskSideForegroundGateway({required TaskSideFftTransport transport})
    : _transport = transport {
    _cancel = _transport.registerReceiver(_onData);
  }

  final TaskSideFftTransport _transport;
  final StreamController<Map<String, dynamic>> _incoming =
      StreamController<Map<String, dynamic>>.broadcast();
  void Function()? _cancel;
  bool _disposed = false;

  @override
  Stream<Map<String, dynamic>> get incoming => _incoming.stream;

  @override
  void send(Map<String, dynamic> payload) {
    if (_disposed) return;
    _transport.send(payload);
  }

  void _onData(Object data) {
    if (_disposed) return;
    final map = _coercePayload(data);
    if (map == null) return;
    if (!_incoming.isClosed) _incoming.add(map);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _cancel?.call();
    _cancel = null;
    if (!_incoming.isClosed) await _incoming.close();
  }
}

/// Test transport that lets a UI-side and task-side gateway share an
/// in-process channel without binding to FFT statics. Pairs are constructed
/// via [StubFftTransportPair].
class StubFftTransport implements FftTransport {
  StubFftTransport._(this._outbound, this._inbound);

  /// Where this side's outbound payloads end up. The OTHER side's transport
  /// adds them to its `_inbound` controller.
  final StreamController<Object> _outbound;

  /// What the other side has sent us. Listened to lazily on
  /// [registerReceiver].
  final Stream<Object> _inbound;

  StreamSubscription<Object>? _sub;

  @override
  void send(Object payload) {
    if (_outbound.isClosed) return;
    _outbound.add(payload);
  }

  @override
  void Function() registerReceiver(void Function(Object data) onData) {
    _sub?.cancel();
    _sub = _inbound.listen(onData);
    return () {
      _sub?.cancel();
      _sub = null;
    };
  }
}

/// Pair of [StubFftTransport]s that mirror the FFT topology: UI side's
/// outbound goes to the task side's inbound, and vice versa. Used in
/// [task_isolate_handover_test.dart] so the gateway code is exercised
/// end-to-end.
class StubFftTransportPair {
  StubFftTransportPair()
    : _uiOutbound = StreamController<Object>.broadcast(),
      _taskOutbound = StreamController<Object>.broadcast() {
    uiSide = StubFftTransport._(_uiOutbound, _taskOutbound.stream);
    taskSide = StubFftTransport._(_taskOutbound, _uiOutbound.stream);
  }

  final StreamController<Object> _uiOutbound;
  final StreamController<Object> _taskOutbound;

  late final StubFftTransport uiSide;
  late final StubFftTransport taskSide;

  Future<void> dispose() async {
    if (!_uiOutbound.isClosed) await _uiOutbound.close();
    if (!_taskOutbound.isClosed) await _taskOutbound.close();
  }
}
