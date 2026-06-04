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
import 'session_messages.dart';

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

  /// Push a CONTROL payload straight to the transport, REGARDLESS of readiness
  /// (#731). Unlike [send], this never lands in the not-ready buffer — a
  /// re-handshake hello must reach a live task even before the gateway has been
  /// flipped to ready, otherwise it would deadlock waiting on the very ready
  /// signal it is trying to trigger. The default implementation defers to
  /// [send] (correct for in-isolate test pairs, which are never not-ready).
  void sendControl(Map<String, dynamic> payload) => send(payload);

  /// Whether the gateway has seen the task's readiness handshake. UI-side
  /// gateways buffer until this is true; in-isolate pairs are always ready.
  bool get isReady => true;

  /// Tell the gateway the foreground service was found "already running" while
  /// the gateway is still not-ready (#731 — the service outlived the UI
  /// process). Arms a short timeout: if no readiness handshake arrives, the
  /// gateway re-sends the hello once and then surfaces a visible error rather
  /// than buffering a `connect` silently forever. No-op when already ready or
  /// for in-isolate test pairs.
  void markServiceAlreadyRunning() {}

  /// Inbound payloads from the other side.
  Stream<Map<String, dynamic>> get incoming;

  /// Signal that the foreground task isolate was STOPPED. The next isolate
  /// generation is a fresh process that re-sends its readiness handshake, so
  /// the gateway must go back to not-ready and re-buffer outbound commands
  /// until that handshake arrives — otherwise a reconnect fires its `connect`
  /// at the dead transport and is lost (#564). No-op for in-isolate test pairs.
  void markServiceStopped() {}

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
  void sendControl(Map<String, dynamic> payload) => send(payload);

  @override
  bool get isReady => true;

  @override
  void markServiceAlreadyRunning() {
    // In-isolate test pair: always ready, never a stuck not-ready buffer.
  }

  @override
  void markServiceStopped() {
    // In-isolate test pair: no real service to stop, nothing to re-buffer.
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
  FlutterForegroundSshGateway({
    FftTransport? transport,
    Duration rehandshakeTimeout = const Duration(seconds: 3),
    Timer Function(Duration, void Function())? scheduleTimer,
  }) : _transport = transport ?? const UiSideFftTransport(),
       _rehandshakeTimeout = rehandshakeTimeout,
       _scheduleTimer = scheduleTimer ?? Timer.new {
    _cancel = _transport.registerReceiver(_onData);
  }

  final FftTransport _transport;

  /// How long to wait for a readiness handshake after the service was found
  /// "already running" before re-sending the hello / surfacing an error (#731).
  final Duration _rehandshakeTimeout;

  /// Injectable timer factory so `fakeAsync` tests can drive the re-handshake
  /// timeout deterministically without real delays. Defaults to [Timer.new].
  final Timer Function(Duration, void Function()) _scheduleTimer;

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

  /// Pending re-handshake timeout (#731). Non-null while we are waiting on a
  /// readiness handshake after the service was found "already running".
  Timer? _rehandshakeTimer;

  /// Whether we've already re-sent the hello once during the current
  /// not-ready window. The second timeout surfaces an error instead of looping.
  bool _helloRetried = false;

  @override
  bool get isReady => _ready;

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

  @override
  void sendControl(Map<String, dynamic> payload) {
    if (_disposed) return;
    // Control payloads (the re-handshake hello, #731) MUST bypass the not-ready
    // buffer — they exist precisely to PROVOKE the readiness the buffer waits
    // on. Buffering one would deadlock the very flush it triggers.
    ctrace('ui.gw', 'sendControl ${_gwLabel(payload)} → transport (bypass)');
    _transport.send(payload);
  }

  @override
  void markServiceAlreadyRunning() {
    if (_disposed || _ready) return;
    // The foreground service was found running but THIS gateway never saw a
    // ready handshake (#731 — service outlived the UI process). Arm a timeout:
    // if no readiness arrives, re-send the hello once, then surface a visible
    // error rather than buffering forever. Idempotent — re-arming just resets
    // the window.
    _rehandshakeTimer?.cancel();
    _rehandshakeTimer = _scheduleTimer(
      _rehandshakeTimeout,
      _onRehandshakeTimeout,
    );
  }

  void _onRehandshakeTimeout() {
    if (_disposed || _ready) return;
    if (!_helloRetried) {
      _helloRetried = true;
      ctrace(
        'ui.gw',
        'rehandshake timeout — re-sending hello (n buffered=${_outboundBuffer.length})',
      );
      sendControl(const SshUiHelloCommand().toJson());
      _rehandshakeTimer = _scheduleTimer(
        _rehandshakeTimeout,
        _onRehandshakeTimeout,
      );
      return;
    }
    // Second window elapsed with no readiness — stop hanging silently. Surface a
    // visible error scoped to the buffered command's session so the UI proxy
    // turns it into a session error (and the user sees something other than
    // "tapped, nothing happened"). Drop the dead buffer.
    final sid = _outboundBuffer
        .map((p) => p['sessionId'])
        .whereType<String>()
        .firstWhere((s) => s.isNotEmpty, orElse: () => '');
    ctrace(
      'ui.gw',
      'rehandshake FAILED — surfacing error for sid=$sid, dropping '
          '${_outboundBuffer.length} buffered',
    );
    _outboundBuffer.clear();
    if (!_incoming.isClosed) {
      _incoming.add(
        SshErrorEvent(
          sessionId: sid,
          message:
              'Background service is unresponsive. Force-stop MobiSSH in '
              'Android Settings → Apps, then reconnect.',
        ).toJson(),
      );
    }
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
      _rehandshakeTimer?.cancel();
      _rehandshakeTimer = null;
      _helloRetried = false;
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
  void markServiceStopped() {
    // The isolate that proved us "ready" is gone. Re-buffer until the NEXT
    // isolate generation re-handshakes (its first inbound flips _ready again
    // and flushes). Clear any stale buffer — those commands targeted the dead
    // isolate. Without this, a reconnect's `connect` is sent to a dead
    // transport and lost → stuck idle (#564).
    if (!_ready && _outboundBuffer.isEmpty) return;
    ctrace(
      'ui.gw',
      'markServiceStopped → not-ready (was ready=$_ready, '
          'dropping ${_outboundBuffer.length} buffered)',
    );
    _ready = false;
    _outboundBuffer.clear();
    _rehandshakeTimer?.cancel();
    _rehandshakeTimer = null;
    _helloRetried = false;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _outboundBuffer.clear();
    _rehandshakeTimer?.cancel();
    _rehandshakeTimer = null;
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

  @override
  void sendControl(Map<String, dynamic> payload) => send(payload);

  @override
  bool get isReady => true;

  @override
  void markServiceAlreadyRunning() {
    // Task side IS the service; readiness handshakes are a UI-side concern.
  }

  @override
  void markServiceStopped() {
    // Task side IS the service; its own teardown is onDestroy. No-op here.
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
