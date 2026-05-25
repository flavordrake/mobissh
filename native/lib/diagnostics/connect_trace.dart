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
// This is diagnostic scaffolding — remove or gate behind a flag once the
// connect path is stable.

import 'package:flutter/foundation.dart';

void ctrace(String where, String msg) {
  debugPrint('[CONNECT][$where] $msg');
}
