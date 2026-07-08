// Feedback bundle assembler (#553).
//
// Gathers the diagnostic essentials the owner needs to surface a device-only
// bug off the phone — connect-log ring buffer + last crash report + crash
// environment + app version/git-hash + device/OS info — into one well-formed
// JSON blob suitable for the Android share sheet (share_plus) or an optional
// upload POST.
//
// **Security contract (#553, rules/security.md).** The bundle must contain NO
// credential material. The connect log already logs lengths only, but the
// assembler defends in depth: every string that enters the bundle (connect-log
// lines and the embedded crash report) is run through [scrubSecrets], which
// redacts password/token/key-looking substrings. A scrubbed value becomes the
// marker `[REDACTED]` so the line stays diagnostically useful (you still see
// *where* a secret would have been) without leaking the secret itself.

import 'dart:convert';

import 'crash_environment.dart';

/// Schema version stamped into every feedback bundle. Bump when the format
/// changes so a collection endpoint can detect mismatches.
const int feedbackBundleSchemaVersion = 1;

/// Marker substituted for any redacted secret material.
const String redactionMarker = '[REDACTED]';

/// Patterns that signal credential material. Each match is replaced wholesale
/// with [redactionMarker]. Defensive — the connect log should never carry
/// these, but a future logging mistake (or a crash report `error` string that
/// echoes a credential) must not leak through.
final List<RegExp> _secretPatterns = <RegExp>[
  // key=value where the key smells like a secret. Captures the value up to a
  // whitespace boundary. Case-insensitive.
  RegExp(
    r'(?:password|passwd|passphrase|secret|token|apikey|api_key|auth|bearer)'
    r'\s*[:=]\s*\S+',
    caseSensitive: false,
  ),
  // PEM / OpenSSH private-key blocks (and the bare BEGIN marker). The DOTALL
  // form catches a full multi-line key; the bare-marker alternative catches a
  // truncated/inline mention so the test's planted marker is also scrubbed.
  RegExp(
    r'-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----',
  ),
  RegExp(r'BEGIN [A-Z]*\s*PRIVATE KEY'),
  // A `privateKey: <value>` style mention.
  RegExp(r'private[_ ]?key\s*[:=]\s*\S+', caseSensitive: false),
];

/// Redacts credential-looking substrings from [input], replacing each with
/// [redactionMarker]. Idempotent and never throws.
String scrubSecrets(String input) {
  var out = input;
  for (final pattern in _secretPatterns) {
    out = out.replaceAll(pattern, redactionMarker);
  }
  return out;
}

/// Assemble a feedback bundle into a single JSON text blob.
///
/// [info] supplies app version + git hash (`buildSha`) + device/OS info.
/// [connectLog] is the connect-trace ring-buffer snapshot (newest last).
/// [crashJson] is the raw text of the most recent crash report file, if any —
/// it is parsed and embedded as `lastCrash` when it is valid JSON, otherwise
/// preserved verbatim under `lastCrashRaw`. All free text is scrubbed of
/// secrets before it enters the bundle.
///
/// Returns a pretty-printed JSON string. Never throws.
/// Cap on how many recent detection-exception entries ride in the bundle
/// (#995). The COUNT always reports the full corpus size.
const int maxDetectionExceptionsInBundle = 20;

String assembleFeedbackBundle({
  required CrashEnvironmentInfo info,
  required List<String> connectLog,
  List<String> gestureLog = const <String>[],
  List<String> lifecycleLog = const <String>[],
  List<String> controlModeTrace = const <String>[],
  List<String> detectionExceptions = const <String>[],
  String? crashJson,
}) {
  final scrubbedLog = connectLog.map(scrubSecrets).toList(growable: false);
  // #699: gesture-trace ring (touch->cell mapping diagnostics) carried off the
  // device for the Ghostty selection-offset bug. Scrubbed like the connect log.
  final scrubbedGestureLog = gestureLog
      .map(scrubSecrets)
      .toList(growable: false);
  // #759: dedicated lifecycle-event ring (resume-liveness probe outcomes,
  // reconnect decisions). Survives the 200-event connect-ring churn so the next
  // wake-frozen occurrence is diagnosable from the bundle alone.
  final scrubbedLifecycleLog = lifecycleLog
      .map(scrubSecrets)
      .toList(growable: false);
  // #906: dedicated control-mode (`-CC`) trace ring — attach path, window-list
  // snapshots, parsed notifications, gesture resolutions — so ONE report fully
  // diagnoses a "not switching" control-mode issue. Scrubbed like the others;
  // it carries only ids/indices/commands, never terminal content. Empty when
  // control mode is OFF.
  final scrubbedControlModeTrace = controlModeTrace
      .map(scrubSecrets)
      .toList(growable: false);
  // #995: the saved "Not a URL" / "Not a file" reports (oldest first, so the
  // RECENT entries are the tail). Count carries the full corpus size; the
  // entry list is capped so a large corpus can't bloat the bundle. These are
  // the raw material for turning recurring false-positive CLASSES into
  // upstream detector fixes. Scrubbed like every other free-text ring.
  final recentExceptions = detectionExceptions.length >
          maxDetectionExceptionsInBundle
      ? detectionExceptions.sublist(
          detectionExceptions.length - maxDetectionExceptionsInBundle,
        )
      : detectionExceptions;
  final scrubbedExceptions = recentExceptions
      .map(scrubSecrets)
      .toList(growable: false);

  Object? lastCrash;
  String? lastCrashRaw;
  if (crashJson != null && crashJson.trim().isNotEmpty) {
    final scrubbed = scrubSecrets(crashJson);
    try {
      lastCrash = jsonDecode(scrubbed);
    } catch (_) {
      // Corrupt / non-JSON crash file — keep the (scrubbed) raw text so the
      // recipient still has something, without breaking the bundle's JSON.
      lastCrashRaw = scrubbed;
    }
  }

  final payload = <String, Object?>{
    'schema': feedbackBundleSchemaVersion,
    'kind': 'feedback',
    'ts': DateTime.now().toUtc().toIso8601String(),
    'appVersion': info.appVersion,
    'buildSha': info.buildSha,
    'platformVersion': info.platformVersion,
    'deviceModel': info.deviceModel,
    'connectLog': scrubbedLog,
    'gestureLog': scrubbedGestureLog,
    'lifecycleLog': scrubbedLifecycleLog,
    'controlModeTrace': scrubbedControlModeTrace,
    'detectionExceptionCount': detectionExceptions.length,
    'detectionExceptions': scrubbedExceptions,
    'lastCrash': lastCrash,
    // Null-aware element: the entry is omitted entirely when there is no raw
    // (non-JSON) crash blob to preserve.
    'lastCrashRaw': ?lastCrashRaw,
  };

  return const JsonEncoder.withIndent('  ').convert(payload);
}
