// Connect-path tracing (#539 diagnosis).
//
// Every hop in the connect flow calls `ctrace(where, msg)`. Output lands in
// logcat (both the UI isolate and the foreground-task isolate route
// debugPrint through the Flutter engine → logcat) tagged `[CONNECT]` so a
// single `adb logcat | grep CONNECT` shows the full path and the exact hop
// where it stalls.
//
// `where` convention: `ui.form`, `ui.sessions`, `ui.keepalive`, `ui.gw`,
// `ui.proxy` for UI-isolate hops; `task`, `task.host`, `task.ssh` for the
// foreground-task isolate.
//
// In addition to logcat, every call appends a timestamped line to an in-memory
// ring buffer (`connectLog`) so the trace is visible on-device via the
// Diagnostics → Connect log tile — no Termux/adb needed (#543). The ring buffer
// is NOT gated behind kDebugMode: it populates in release builds too.
//
// NOTE (#543): `ctrace` calls in the foreground-task isolate (`task`,
// `task.host`, `task.ssh`) run in a SEPARATE isolate and append to *that*
// isolate's ring buffer, which the UI never reads. Only UI-isolate hops appear
// in the on-device viewer. Piping task-isolate trace lines back over the
// existing gateway as a diagnostic event is a follow-up — not built here.

import 'package:flutter/foundation.dart';

/// Maximum number of lines retained by the [connectLog] ring buffer. Older
/// lines are dropped once the cap is exceeded.
///
/// 600, up from 200 (#879): with 4+ streaming sessions the 200-line ring
/// churned in ~14 seconds, so by the time the owner long-pressed Feedback the
/// evidence window had already been eaten — three device reports in a row
/// shipped with the failure moment missing. 600 lines ≈ a 45–60s window under
/// the same load; memory cost is trivial (short strings).
const int connectLogCapacity = 600;

/// Maximum number of lines retained by the dedicated [lifecycleLog] ring
/// buffer (#759). Lifecycle events (resume-liveness probe OUTCOME, reconnect
/// decisions) are LOW-frequency but HIGH-signal, and the 200-event connect ring
/// churns them off the tail before the +Ns probe RESULT lands (the original
/// #759 telemetry gap: the report was filed DURING the 4s probe, the outcome
/// fell off the buffer). This second, smaller ring is reserved for those events
/// so the NEXT occurrence is unambiguous from telemetry alone. The feedback
/// bundle ships both rings.
const int lifecycleLogCapacity = 80;

final List<String> _ring = <String>[];
final List<String> _lifecycleRing = <String>[];

/// Optional sink invoked with every formatted lifecycle line as it is recorded
/// by [clifecycle] (#766). The lifecycle ring is written ONLY in the
/// foreground-task isolate, but the feedback bundle is assembled in the UI
/// isolate — a SEPARATE per-isolate copy of [_lifecycleRing] the bundle reads
/// is otherwise always empty (the #766 meta-bug: real device reports shipped
/// with NO lifecycle log). The task isolate sets this forwarder (see
/// `SessionHost`) so each lifecycle line is shipped across the UI↔task gateway
/// to the UI isolate, where the gateway calls [recordLifecycleLine] to land it
/// in the UI-side ring the bundle reads.
///
/// Null by default: pure diagnostics with NO IPC coupling. Only the task
/// isolate's host arms it; clearing it (set to null) on host dispose detaches
/// the forwarder.
void Function(String line)? lifecycleForwarder;

// Consecutive-duplicate suppression: when the same `[where] msg` repeats
// back-to-back (e.g. keepalive `recv`/`send` pings), collapse it into the last
// line as ` (×N)` instead of spamming a new line per occurrence — both in the
// on-device ring and in logcat.
String? _lastKey;
int _lastCount = 0;

final ValueNotifier<List<String>> _connectLog = ValueNotifier<List<String>>(
  const <String>[],
);

/// Live, read-only view of the connect-trace ring buffer. The newest line is
/// last. Rebuilds whenever a new trace line is appended or the log is cleared.
ValueListenable<List<String>> get connectLog => _connectLog;

/// Read-only snapshot of the current connect-trace ring buffer, newest line
/// last. Returned as an unmodifiable copy so callers (e.g. the feedback bundle
/// assembler, #553) can read the log without holding a listener or mutating
/// the underlying ring.
List<String> connectLogSnapshot() => List<String>.unmodifiable(_ring);

final ValueNotifier<List<String>> _lifecycleLog = ValueNotifier<List<String>>(
  const <String>[],
);

/// Live, read-only view of the dedicated lifecycle-event ring (#759). The
/// newest line is last.
ValueListenable<List<String>> get lifecycleLog => _lifecycleLog;

/// Read-only snapshot of the lifecycle-event ring, newest line last (#759).
/// Bundled into the feedback upload alongside [connectLogSnapshot] so the
/// resume-liveness probe outcome survives the connect-ring churn.
List<String> lifecycleLogSnapshot() =>
    List<String>.unmodifiable(_lifecycleRing);

String _timestamp(DateTime now) {
  String two(int n) => n.toString().padLeft(2, '0');
  String three(int n) => n.toString().padLeft(3, '0');
  return '${two(now.hour)}:${two(now.minute)}:${two(now.second)}'
      '.${three(now.millisecond)}';
}

void ctrace(String where, String msg) {
  final key = '[$where] $msg';
  final ts = _timestamp(DateTime.now());

  // Collapse a run of identical lines into the most recent entry as ` (×N)`.
  if (key == _lastKey && _ring.isNotEmpty) {
    _lastCount++;
    _ring[_ring.length - 1] = '$ts $key (×$_lastCount)';
    _connectLog.value = List<String>.unmodifiable(_ring);
    return;
  }

  _lastKey = key;
  _lastCount = 1;
  debugPrint('[CONNECT]$key');

  _ring.add('$ts $key');
  while (_ring.length > connectLogCapacity) {
    _ring.removeAt(0);
  }
  // Emit a fresh copy so ValueListenableBuilder (which compares by identity)
  // rebuilds on every append.
  _connectLog.value = List<String>.unmodifiable(_ring);
}

/// Record a HIGH-signal lifecycle event (#759): resume-liveness probe outcome,
/// reconnect decision. Appends to the dedicated [lifecycleLog] ring (which
/// survives the 200-event connect-ring churn) AND to the connect ring (so the
/// event also appears in-context) AND to logcat. Never suppressed/collapsed —
/// every lifecycle decision is its own line.
void clifecycle(String where, String msg) {
  final key = '[$where] $msg';
  final ts = _timestamp(DateTime.now());
  final line = '$ts $key';

  // Dedicated lifecycle ring — the durable record.
  _lifecycleRing.add(line);
  while (_lifecycleRing.length > lifecycleLogCapacity) {
    _lifecycleRing.removeAt(0);
  }
  _lifecycleLog.value = List<String>.unmodifiable(_lifecycleRing);

  // Also surface in the connect ring + logcat for in-context reading. Reset the
  // collapse state so this line is never merged into a preceding ` (×N)` run.
  _lastKey = null;
  _lastCount = 0;
  debugPrint('[CONNECT]$key');
  _ring.add(line);
  while (_ring.length > connectLogCapacity) {
    _ring.removeAt(0);
  }
  _connectLog.value = List<String>.unmodifiable(_ring);

  // Ship the formatted line across the isolate boundary if a forwarder is armed
  // (#766). Defensive: a forwarder failure must never break telemetry capture.
  final forward = lifecycleForwarder;
  if (forward != null) {
    try {
      forward(line);
    } catch (_) {
      // Swallow — diagnostics must not throw into the lifecycle hot path.
    }
  }
}

/// Records an already-formatted lifecycle [line] (`HH:mm:ss.SSS [where] msg`)
/// into the dedicated [lifecycleLog] ring AND the connect ring (#766).
///
/// Counterpart to [clifecycle] for lines that ORIGINATED in another isolate:
/// the foreground-task isolate forwards each lifecycle line across the gateway,
/// and the UI-side gateway calls this so the line lands in the UI isolate's
/// ring — the one the feedback bundle reads. The line is stored verbatim (its
/// original task-side timestamp preserved), and the forwarder is NOT re-invoked
/// (no echo back across the boundary). Never collapsed into a preceding ×N run.
void recordLifecycleLine(String line) {
  _lifecycleRing.add(line);
  while (_lifecycleRing.length > lifecycleLogCapacity) {
    _lifecycleRing.removeAt(0);
  }
  _lifecycleLog.value = List<String>.unmodifiable(_lifecycleRing);

  _lastKey = null;
  _lastCount = 0;
  debugPrint('[CONNECT]$line');
  _ring.add(line);
  while (_ring.length > connectLogCapacity) {
    _ring.removeAt(0);
  }
  _connectLog.value = List<String>.unmodifiable(_ring);
}

/// Clears the on-device connect-log + lifecycle-event ring buffers. Does not
/// affect logcat.
void clearConnectLog() {
  _ring.clear();
  _lifecycleRing.clear();
  _lastKey = null;
  _lastCount = 0;
  _connectLog.value = const <String>[];
  _lifecycleLog.value = const <String>[];
}
