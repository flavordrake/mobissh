// Hardened clipboard write (#845, #924).
//
// #845 — The owner reported that copied text shows in the Android system
// clipboard PREVIEW chip but does NOT reliably surface in Gboard's clipboard
// HISTORY. Root cause: every copy site used Flutter's plain
// `Clipboard.setData(ClipboardData(text:))`, which hands Android a `ClipData`
// built with an EMPTY label (`newPlainText("", text)`). #845's fix routes all
// copy sites through [copyToClipboard], which writes a properly LABELED
// plain-text clip natively via a tiny Kotlin `MethodChannel`
// (`ClipData.newPlainText("MobiSSH", text)` + `setPrimaryClip`). That labeled
// native write is the real win and is preserved.
//
// #924 — The copy still didn't reach CROSS-APP PASTE: the toast fires, the
// preview looks correct, and telemetry logged `verified=true`, yet pasting in
// another app got nothing. `verified=true` only means our OWN post-write
// `Clipboard.getData` self-readback found our text in the primary clip — it
// does NOT prove the clip propagated to the system surface other apps read.
// Worse, reading the clipboard SYNCHRONOUSLY right after `setPrimaryClip` can,
// on some Android 13 builds, race/disturb that very propagation.
//
// #924 fix: the synchronous, awaited self-readback is REMOVED from the write
// path. The native `setPrimaryClip` is authoritative — once it returns, the
// copy is done and we toast. A best-effort diagnostic readback is scheduled on
// a delayed microtask AFTER the write has settled so it can never block or
// interfere with propagation; its result is logged only.
//
// Non-Android hosts (desktop, widget tests) have no native channel: the call
// throws `MissingPluginException` / `PlatformException`, and we fall back to
// the plain `Clipboard.setData` path so those hosts still copy.

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../diagnostics/connect_trace.dart';

/// The native clipboard channel. Mirrors `mobissh/storage_picker` (#529) — a
/// thin custom MethodChannel installed in `MainActivity.configureFlutterEngine`.
@visibleForTesting
const MethodChannel clipboardChannel = MethodChannel('mobissh/clipboard');

/// Label applied to the native `ClipData`. A NON-empty label is the whole point
/// of the fix (#845): empty-label clips don't reliably reach Gboard history.
const String _clipboardLabel = 'MobiSSH';

/// Copies [text] to the Android system clipboard with a labeled plain-text clip
/// and verifies containment. Returns `true` when the write is believed to have
/// succeeded (so the caller may toast "Copied…"), `false` only when there was
/// nothing to copy.
///
/// Behavior:
/// - Empty / whitespace-only [text] → no write, returns `false` (callers also
///   keep their own #810/#828 empty-payload guards).
/// - Native write succeeds → returns `true` immediately. The native
///   `setPrimaryClip` is authoritative; we do NOT block the copy on a readback
///   (#924 — a synchronous readback can disturb Android-13 clip propagation).
///   A best-effort diagnostic readback is scheduled AFTER the write settles and
///   only logged — it never gates the result.
/// - Any platform-channel error (desktop / tests / missing plugin) → falls back
///   to `Clipboard.setData(ClipboardData(text:))` and returns `true` so
///   non-Android hosts and widget tests still copy.
Future<bool> copyToClipboard(String text) async {
  if (text.trim().isEmpty) {
    clifecycle('clipboard', 'skip empty payload (no write)');
    return false;
  }

  try {
    final res = await clipboardChannel.invokeMethod<dynamic>(
      'setText',
      <String, dynamic>{'label': _clipboardLabel, 'text': text},
    );
    if (res is Map) {
      // #962 device diagnostics from the native immediate readback — logged into
      // the connect-trace so a bug report shows EXACTLY what the system held
      // right after setPrimaryClip: model/OS, whether a primary clip exists, if
      // its text matches, the sensitivity flag, and whether the activity had
      // window focus (Android gates cross-app propagation on foreground focus).
      clifecycle(
        'clipboard',
        'native setText model=${res['model']} sdk=${res['sdk']}/${res['release']} '
            'wrote=${res['wroteLen']} hasClip=${res['hasPrimaryClip']} '
            'readback=${res['readbackLen']} matches=${res['matches']} '
            'sensitive=${res['sensitiveReadback']} focus=${res['windowFocus']}',
      );
    } else {
      clifecycle(
        'clipboard',
        'wrote ${text.length} chars (native, labeled "$_clipboardLabel")',
      );
    }
    // Diagnostics-only, deferred so the readback can never race the system
    // clip propagation that #924 was about. NOT awaited — fire and forget.
    _scheduleDeferredReadback(text);
    return true;
  } catch (err) {
    // No native channel (desktop / widget tests / missing plugin), or the
    // native side errored. Fall back to Flutter's plain clipboard write so the
    // copy still happens; the empty-label limitation only matters on-device.
    try {
      await Clipboard.setData(ClipboardData(text: text));
      clifecycle(
        'clipboard',
        'wrote ${text.length} chars (fallback setData; native err: $err)',
      );
      return true;
    } catch (fallbackErr) {
      clifecycle('clipboard', 'write FAILED (fallback err: $fallbackErr)');
      return false;
    }
  }
}

/// How long to wait before the diagnostic readback (#924). The native write is
/// already authoritative; this delay just lets the system clip-propagation
/// settle so the readback observes the steady state instead of racing it.
@visibleForTesting
const Duration clipboardReadbackDelay = Duration(milliseconds: 250);

/// Whether the deferred diagnostic readback is allowed to schedule a timer.
///
/// Defaults to OFF under `flutter test` (the binding rejects pending timers in
/// `testWidgets`, and the readback is on-device-only diagnostics). A single
/// unit test flips it on to verify the deferral/non-blocking contract.
bool _deferredReadbackEnabled = !Platform.environment.containsKey('FLUTTER_TEST');

/// Test hook: force-enable the deferred readback so the deferral contract can be
/// asserted under `flutter test`. Returns the previous value so the test can
/// restore it. NOT for production use.
@visibleForTesting
bool setDeferredReadbackEnabledForTest(bool enabled) {
  final previous = _deferredReadbackEnabled;
  _deferredReadbackEnabled = enabled;
  return previous;
}

/// Schedules a best-effort, DEFERRED clipboard readback purely for telemetry.
///
/// This is NOT awaited by [copyToClipboard] and never affects its result. It
/// exists only so device feedback uploads can show whether our text was still
/// present a moment after the write. Crucially it does NOT run synchronously
/// right after `setPrimaryClip` — that synchronous readback was the #924
/// suspect (it can disturb Android-13 cross-app propagation).
///
/// IMPORTANT: even a `true` readback here does NOT prove cross-app paste works.
/// It only proves OUR process can still read OUR clip. Cross-app availability
/// is only observable by pasting in another app (device validation).
void _scheduleDeferredReadback(String text) {
  if (!_deferredReadbackEnabled) return;
  Future<void>.delayed(clipboardReadbackDelay, () async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final readBack = data?.text;
      final bool? contains =
          (readBack == null || readBack.isEmpty) ? null : readBack.contains(text);
      clifecycle(
        'clipboard',
        'deferred readback contains=$contains '
            '(self-read only; NOT cross-app paste proof)',
      );
    } catch (err) {
      // Readback is best-effort diagnostics; never surface as an error.
      clifecycle('clipboard', 'deferred readback skipped ($err)');
    }
  });
}
