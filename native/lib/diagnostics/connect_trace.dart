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
const int connectLogCapacity = 200;

final List<String> _ring = <String>[];

final ValueNotifier<List<String>> _connectLog =
    ValueNotifier<List<String>>(const <String>[]);

/// Live, read-only view of the connect-trace ring buffer. The newest line is
/// last. Rebuilds whenever a new trace line is appended or the log is cleared.
ValueListenable<List<String>> get connectLog => _connectLog;

String _timestamp(DateTime now) {
  String two(int n) => n.toString().padLeft(2, '0');
  String three(int n) => n.toString().padLeft(3, '0');
  return '${two(now.hour)}:${two(now.minute)}:${two(now.second)}'
      '.${three(now.millisecond)}';
}

void ctrace(String where, String msg) {
  debugPrint('[CONNECT][$where] $msg');

  _ring.add('${_timestamp(DateTime.now())} [$where] $msg');
  while (_ring.length > connectLogCapacity) {
    _ring.removeAt(0);
  }
  // Emit a fresh copy so ValueListenableBuilder (which compares by identity)
  // rebuilds on every append.
  _connectLog.value = List<String>.unmodifiable(_ring);
}

/// Clears the on-device connect-log ring buffer. Does not affect logcat.
void clearConnectLog() {
  _ring.clear();
  _connectLog.value = const <String>[];
}
