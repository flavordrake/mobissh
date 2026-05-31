// Widget test for the "Share feedback" action on the DiagnosticsSection (#553).
//
// Asserts:
//   - The "Share feedback" button is present in the Diagnostics section.
//   - Tapping it assembles a feedback bundle and routes it through the share
//     path (here intercepted via the injected `onShareFeedback` handler so the
//     real share_plus platform channel is never invoked).
//   - The captured bundle carries the diagnostic essentials (app version, git
//     hash, a connect-log line) and NO planted credential material.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobissh/diagnostics/connect_trace.dart';
import 'package:mobissh/diagnostics/crash_environment.dart';
import 'package:mobissh/diagnostics/crash_reporter.dart';
import 'package:mobissh/ui/diagnostics_section.dart';

void main() {
  late Directory tempRoot;
  late FakeCrashEnvironment env;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp(
      'mobissh_feedback_widget_',
    );
    env = FakeCrashEnvironment(
      dir: Directory('${tempRoot.path}/crashes')..createSync(recursive: true),
      info: const CrashEnvironmentInfo(
        appVersion: '2.0.0+99',
        buildSha: 'feedbeef99',
        platformVersion: 'Android 34 (14)',
        deviceModel: 'Pixel WidgetTest',
      ),
    );
    CrashReporter.reset();
    CrashReporter.configure(env: env);
    clearConnectLog();
  });

  tearDown(() async {
    CrashReporter.reset();
    clearConnectLog();
    try {
      await tempRoot.delete(recursive: true);
    } catch (_) {
      // Best-effort cleanup.
    }
  });

  Future<void> pumpBounded(WidgetTester tester) async {
    await tester.pump();
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('Share feedback button is present in Diagnostics', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DiagnosticsSection(onShareFeedback: (_) async {})),
      ),
    );
    await pumpBounded(tester);

    await tester.tap(find.byKey(const ValueKey('diagnostics-section')));
    await pumpBounded(tester);

    expect(find.byKey(const ValueKey('share-feedback-button')), findsOneWidget);
    expect(find.text('Share feedback'), findsOneWidget);
  });

  testWidgets(
    'tapping Share feedback assembles a scrubbed bundle and shares it',
    (tester) async {
      // Seed the connect log with a benign line AND a line that (defensively)
      // carries a planted secret — the bundle must scrub it.
      ctrace('ui.form', 'connect tapped host=example.com');
      ctrace('ui.proxy', 'password=PLANTED-SECRET-pw len=15');

      String? captured;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DiagnosticsSection(
              onShareFeedback: (bundle) async {
                captured = bundle;
              },
            ),
          ),
        ),
      );
      await pumpBounded(tester);

      await tester.tap(find.byKey(const ValueKey('diagnostics-section')));
      await pumpBounded(tester);

      // _shareFeedback awaits real filesystem I/O (latestCrashContent →
      // Directory.list()), which the fake-async clock does not advance. Drive
      // the tap *inside* a runAsync block so the whole handler — including the
      // real I/O — runs against the real Dart runtime and the injected handler
      // fires.
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('share-feedback-button')));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await pumpBounded(tester);

      expect(
        captured,
        isNotNull,
        reason: 'share path must fire with the assembled bundle',
      );
      final blob = captured!;

      // Diagnostic essentials present.
      expect(blob, contains('2.0.0+99'), reason: 'app version');
      expect(blob, contains('feedbeef99'), reason: 'git hash / build sha');
      expect(
        blob,
        contains('connect tapped host=example.com'),
        reason: 'a connect-log line must be present',
      );

      // No credential material.
      expect(
        blob.contains('PLANTED-SECRET-pw'),
        isFalse,
        reason: 'planted password must be scrubbed from the shared bundle',
      );

      // Well-formed.
      final decoded = jsonDecode(blob) as Map<String, Object?>;
      expect(decoded['kind'], 'feedback');
    },
  );
}
