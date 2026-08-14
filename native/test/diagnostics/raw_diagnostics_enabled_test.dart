// #1109-A: the ENABLED path of the raw-content diagnostics gate.
//
// The gate [kRawContentDiagnosticsEnabled] is a COMPILE-TIME const, so the plain
// fast gate (`flutter test`, no --dart-define) runs it as false — the assertions
// below then SKIP. To exercise the tracing-enabled internal build, run:
//
//   flutter test --dart-define=MOBISSH_RAW_DIAGNOSTICS=true \
//     test/diagnostics/raw_diagnostics_enabled_test.dart
//
// With the flag on, the raw byteTrace flows into the payload (developers still
// get full replay traces). This locks that the gate is a switch, not a deletion.

import 'package:flutter_test/flutter_test.dart';

import 'package:mobissh/diagnostics/diagnostics_config.dart';
import 'package:mobissh/ui/feedback_overlay.dart';

void main() {
  test('byteTrace flows when raw diagnostics are compiled in', () {
    if (!kRawContentDiagnosticsEnabled) {
      markTestSkipped(
        'run with --dart-define=MOBISSH_RAW_DIAGNOSTICS=true to exercise this',
      );
      return;
    }
    final payload = buildFeedbackPayload(
      comment: 'scroll stuck',
      version: '[v]',
      byteTrace: const [
        {'tMs': 0, 'b64': 'aGVsbG8='}, // "hello"
      ],
    );
    expect(payload.containsKey('byteTrace'), isTrue);
    expect((payload['byteTrace'] as List), hasLength(1));
  });
}
