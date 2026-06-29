// Relative-time formatter for the SFTP file browser (#951).
//
// Ports the PWA's relative-age rendering (public/native-time.js `ago`, the
// build-install-page formatter), extended to the file-explorer scale the issue
// asks for: seconds / minutes / hours / yesterday / days / weeks / months /
// years. PURE + injectable `now` so it is deterministically unit-testable with
// no clock or plugin dependency.
//
// Contract:
//   - null or non-positive epoch → '' (never render a 1969 date). The caller
//     omits the time segment entirely on an empty result.
//   - a future timestamp (clock skew) → 'just now'.

/// Format [epochSeconds] (seconds since the Unix epoch) as a short relative age
/// like `3d ago` / `yesterday` / `5m ago`, measured against [now]
/// (defaults to `DateTime.now()`).
///
/// Returns '' for a null or non-positive epoch so callers can drop the segment.
String formatRelative(int? epochSeconds, {DateTime? now}) {
  if (epochSeconds == null || epochSeconds <= 0) return '';
  final nowDt = now ?? DateTime.now();
  final then = DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000);
  final seconds = nowDt.difference(then).inSeconds;
  if (seconds < 0) return 'just now'; // clock skew: file mtime in the future
  if (seconds < 60) return '${seconds}s ago';
  final minutes = seconds ~/ 60;
  if (minutes < 60) return '${minutes}m ago';
  final hours = minutes ~/ 60;
  if (hours < 24) return '${hours}h ago';
  final days = hours ~/ 24;
  if (days == 1) return 'yesterday';
  if (days < 7) return '${days}d ago';
  if (days < 30) return '${days ~/ 7}w ago';
  if (days < 365) return '${days ~/ 30}mo ago';
  return '${days ~/ 365}y ago';
}
