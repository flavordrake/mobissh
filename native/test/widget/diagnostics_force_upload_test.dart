// Widget tests for the DiagnosticsSection's crash-upload / share / audit glue
// (backfill #1164; complements diagnostics_section_widget_test.dart, whose
// crash-file-backed cases are skipped because bounded fake-clock pumps never
// drive the FutureBuilder's real `Directory.list()` to completion).
//
// The fix here is the feedback_share_widget_test.dart pattern: every tap that
// awaits real filesystem I/O is driven INSIDE `tester.runAsync` so the whole
// handler runs against the real Dart event loop, then frames are pumped so
// the resulting rebuild / toast land.
//
// Pins:
//   - (d) Connection Audit button pushes the ConnectionAuditScreen route.
//   - (e) Force upload: success → summary toast + list refresh (pending count
//         drops, crash file gone); failed POST → summary toast reporting the
//         failure, crash file kept, pending count unchanged. The reporter is
//         re-entrancy guarded; the BUTTON itself is never disabled (there is
//         no in-flight flag in the widget) — pinned as-is, see PR body.
//   - (f) Share last crash: the injected share handler throwing surfaces a
//         `Share failed:` toast and does not crash the section.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/diagnostics/crash_environment.dart';
import 'package:mobissh/diagnostics/crash_reporter.dart';
import 'package:mobissh/ui/diagnostics_section.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempRoot;
  late FakeCrashEnvironment env;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tempRoot = await Directory.systemTemp.createTemp('mobissh_dx_upload_');
    env = FakeCrashEnvironment(
      dir: Directory('${tempRoot.path}/crashes')..createSync(recursive: true),
    );
    CrashReporter.reset();
  });

  tearDown(() async {
    CrashReporter.reset();
    try {
      await tempRoot.delete(recursive: true);
    } catch (_) {
      // Best-effort cleanup.
    }
  });

  /// Real-clock tick so `Directory.list()` (FutureBuilder load, uploadPending,
  /// latestCrashFile) completes, then fake-clock frames so the rebuild lands.
  Future<void> settleIo(WidgetTester tester) async {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// Toasts (#667) arm a 2s Timer + a 220ms fade on the fake clock — drain
  /// them so the test ends without pending timers.
  Future<void> drainToasts(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  List<File> seedCrashes(int count) {
    final files = <File>[];
    for (var i = 0; i < count; i++) {
      final stamp = '20260916T1000${i.toString().padLeft(2, '0')}';
      final file = File('${env.dir.path}/$stamp-dart.json');
      file.writeAsStringSync(
        '{"schema":1,"kind":"dart","seq":$i,"error":"seed-$i"}',
      );
      files.add(file);
    }
    return files;
  }

  Future<void> pumpSection(
    WidgetTester tester, {
    Future<void> Function(File file)? onShare,
  }) async {
    // Tall viewport so the whole flat section is on-screen + hit-testable.
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // Mount INSIDE runAsync: the FutureBuilder's `_load()` is created in
    // initState, and a real `Directory.list()` started under the fake-async
    // zone never resolves (the reason the sibling file's crash-backed cases
    // are skipped). Under the real zone it completes within the delay.
    await tester.runAsync(() async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: DiagnosticsSection(
                  onShare: onShare,
                  onShareFeedback: (_) async {},
                ),
              ),
            ),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await settleIo(tester);
  }

  /// Tap under the real zone, then settle TWICE: the handler's own I/O
  /// (upload / latestCrashFile) lands on the first pass; `_refresh()` starts
  /// a second `_load()` whose FutureBuilder subscription is only attached on
  /// the rebuild, so its result needs one more real-zone tick + frame.
  Future<void> tapWithIo(WidgetTester tester, Key key) async {
    await tester.runAsync(() async {
      await tester.tap(find.byKey(key));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await settleIo(tester);
    await settleIo(tester);
  }

  testWidgets('(d) Connection Audit button pushes the audit screen', (
    tester,
  ) async {
    CrashReporter.configure(env: env);
    await pumpSection(tester);

    await tester.tap(find.byKey(const ValueKey('connection-audit-button')));
    // Route push transition.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.widgetWithText(AppBar, 'Connection Audit'), findsOneWidget);
    expect(find.textContaining('No active sessions.'), findsOneWidget);
    expect(
      find.byType(BackButton),
      findsOneWidget,
      reason: 'pushed as a route (not replaced) — Back returns to Settings',
    );
  });

  testWidgets(
    '(e) force upload success → summary toast, crash file removed, pending '
    'status refreshes to zero',
    (tester) async {
      var posts = 0;
      CrashReporter.configure(
        env: env,
        httpClient: MockClient((req) async {
          posts++;
          return http.Response('ok', 200);
        }),
        endpoint: 'http://fake/endpoint',
      );
      final seeded = seedCrashes(1);
      await pumpSection(tester);

      expect(find.text('1 crash report pending upload.'), findsOneWidget);

      await tapWithIo(tester, const ValueKey('force-upload-button'));

      expect(posts, 1, reason: 'one pending crash → one POST');
      expect(
        find.text('Uploaded 1 of 1 (failed: 0)'),
        findsOneWidget,
        reason: 'UploadSummary toast',
      );
      expect(seeded.first.existsSync(), isFalse, reason: 'uploaded → deleted');
      expect(
        find.text('No crashes pending upload.'),
        findsOneWidget,
        reason: '_refresh() after upload must re-read the pending count',
      );
      await drainToasts(tester);
    },
  );

  testWidgets(
    '(e) force upload with a failing POST → failure summary toast, file kept, '
    'pending status unchanged',
    (tester) async {
      CrashReporter.configure(
        env: env,
        httpClient: MockClient((req) async => http.Response('nope', 500)),
        endpoint: 'http://fake/endpoint',
      );
      final seeded = seedCrashes(1);
      await pumpSection(tester);

      await tapWithIo(tester, const ValueKey('force-upload-button'));

      expect(find.text('Uploaded 0 of 1 (failed: 1)'), findsOneWidget);
      expect(seeded.first.existsSync(), isTrue, reason: 'failed → retained');
      expect(find.text('1 crash report pending upload.'), findsOneWidget);
      await drainToasts(tester);
    },
  );

  testWidgets(
    '(e) force upload with nothing pending → "No crashes to upload" toast, '
    'no POST',
    (tester) async {
      var posts = 0;
      CrashReporter.configure(
        env: env,
        httpClient: MockClient((req) async {
          posts++;
          return http.Response('ok', 200);
        }),
        endpoint: 'http://fake/endpoint',
      );
      await pumpSection(tester);

      await tapWithIo(tester, const ValueKey('force-upload-button'));

      expect(posts, 0);
      expect(find.text('No crashes to upload'), findsOneWidget);
      expect(find.text('No crashes pending upload.'), findsOneWidget);
      await drainToasts(tester);
    },
  );

  testWidgets(
    '(e) button stays enabled while an upload is in flight; the reporter '
    'guards re-entrancy and the second tap toasts "already in progress"',
    (tester) async {
      // A POST that never completes until we release it keeps the first
      // upload in flight across the second tap.
      final release = Completer<http.Response>();
      var posts = 0;
      CrashReporter.configure(
        env: env,
        httpClient: MockClient((req) {
          posts++;
          return release.future;
        }),
        endpoint: 'http://fake/endpoint',
      );
      seedCrashes(1);
      await pumpSection(tester);

      await tapWithIo(tester, const ValueKey('force-upload-button'));
      expect(posts, 1);

      // No in-flight flag in the widget: the button is still tappable.
      final button = tester.widget<OutlinedButton>(
        find.byKey(const ValueKey('force-upload-button')),
      );
      expect(
        button.onPressed,
        isNotNull,
        reason: 'the widget never disables the button (pinned as-is)',
      );

      await tapWithIo(tester, const ValueKey('force-upload-button'));
      expect(posts, 1, reason: 'reporter re-entrancy guard: no second POST');
      expect(find.text('Upload already in progress'), findsOneWidget);

      // Release the first upload so it completes and the summary lands.
      release.complete(http.Response('ok', 200));
      await settleIo(tester);
      expect(find.text('Uploaded 1 of 1 (failed: 0)'), findsOneWidget);
      await drainToasts(tester);
    },
  );

  testWidgets(
    '(f) share handler throwing → "Share failed" toast, section still mounted',
    (tester) async {
      CrashReporter.configure(env: env);
      seedCrashes(1);
      await pumpSection(
        tester,
        onShare: (_) async => throw StateError('share sheet unavailable'),
      );

      expect(
        find.byKey(const ValueKey('share-last-crash-button')),
        findsOneWidget,
        reason: 'a crash on disk exposes the share button',
      );

      await tapWithIo(tester, const ValueKey('share-last-crash-button'));

      expect(
        find.textContaining('Share failed: Bad state: share sheet unavailable'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('diagnostics-section')), findsOneWidget);
      expect(tester.takeException(), isNull, reason: 'no crash');
      await drainToasts(tester);
    },
  );

  testWidgets('(f) share handler receives the latest crash file', (
    tester,
  ) async {
    CrashReporter.configure(env: env);
    seedCrashes(2);
    File? shared;
    await pumpSection(
      tester,
      onShare: (file) async {
        shared = file;
      },
    );

    await tapWithIo(tester, const ValueKey('share-last-crash-button'));

    expect(shared, isNotNull);
    expect(shared!.readAsStringSync(), contains('seed-1'));
    expect(find.byKey(const Key('top-toast')), findsNothing);
  });
}
