// Hardened clipboard write (#845).
//
// The owner reported that copied text shows in the Android system clipboard
// PREVIEW chip but does NOT reliably surface in Gboard's clipboard HISTORY
// ("the icon looks empty, then I tap it and it fills in"). There is no lazy /
// custom clipboard service — every copy site used Flutter's plain
// `Clipboard.setData(ClipboardData(text:))`, which hands Android a `ClipData`
// built with an EMPTY label (`newPlainText("", text)`). Some Gboard /
// clipboard-history implementations index or display poorly on empty-label
// clips, which matches the "lazy-fills on tap" symptom.
//
// Fix: route ALL copy sites through [copyToClipboard], which writes a properly
// LABELED plain-text clip natively via a tiny Kotlin `MethodChannel`
// (`ClipData.newPlainText("MobiSSH", text)` + `setPrimaryClip`). It then READS
// BACK the clipboard to prove containment ("make very sure the clipboard
// actually contains the thing we're copying" — the owner's exact ask) and logs
// the outcome to the diagnostic ring so containment is provable from device
// telemetry alone (the owner debugs via Feedback upload).
//
// Non-Android hosts (desktop, widget tests) have no native channel: the call
// throws `MissingPluginException` / `PlatformException`, and we fall back to
// the plain `Clipboard.setData` path so those hosts still copy.

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
/// - Native write succeeds → reads back via `Clipboard.getData(text/plain)` and
///   confirms the read-back CONTAINS what we wrote. A null read-back (Android
///   can deny clipboard READ when focus just changed) is NOT a failure — the
///   write path is authoritative, so we return `true` and log `verified=null`.
/// - Any platform-channel error (desktop / tests / missing plugin) → falls back
///   to `Clipboard.setData(ClipboardData(text:))` and returns `true` so
///   non-Android hosts and widget tests still copy.
Future<bool> copyToClipboard(String text) async {
  if (text.trim().isEmpty) {
    clifecycle('clipboard', 'skip empty payload (no write)');
    return false;
  }

  try {
    await clipboardChannel.invokeMethod<bool>('setText', <String, dynamic>{
      'label': _clipboardLabel,
      'text': text,
    });
    final verified = await _readBackVerified(text);
    clifecycle(
      'clipboard',
      'wrote ${text.length} chars (native), verified=$verified',
    );
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

/// Reads the clipboard back and reports whether it CONTAINS [text]. Returns:
/// - `true`  — read-back text contains what we wrote (containment proof).
/// - `false` — read-back returned non-null text that does NOT contain it
///   (genuine mismatch — the real bug, if it ever happens).
/// - `null`  — read-back returned null/empty (READ denied or empty); NOT a
///   failure, the write path is authoritative.
Future<bool?> _readBackVerified(String text) async {
  try {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final readBack = data?.text;
    if (readBack == null || readBack.isEmpty) return null;
    return readBack.contains(text);
  } catch (_) {
    // Read-back itself is best-effort diagnostics; never let it fail the copy.
    return null;
  }
}
