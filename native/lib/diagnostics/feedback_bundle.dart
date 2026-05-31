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
String assembleFeedbackBundle({
  required CrashEnvironmentInfo info,
  required List<String> connectLog,
  String? crashJson,
}) {
  final scrubbedLog = connectLog.map(scrubSecrets).toList(growable: false);

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
    'lastCrash': lastCrash,
    // Null-aware element: the entry is omitted entirely when there is no raw
    // (non-JSON) crash blob to preserve.
    'lastCrashRaw': ?lastCrashRaw,
  };

  return const JsonEncoder.withIndent('  ').convert(payload);
}
