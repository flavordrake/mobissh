// Widget tests for the DiagnosticsSection on the Connect form.
//
// Asserts:
//   - "Share last crash" button hidden when no crashes exist.
//   - "Share last crash" button visible when a crash file is present.
//   - "Force upload" button always present, triggers uploadPending().

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:mobissh/diagnostics/crash_environment.dart';
import 'package:mobissh/diagnostics/crash_reporter.dart';
import 'package:mobissh/ui/diagnostics_section.dart';

void main() {
  late Directory tempRoot;
  late FakeCrashEnvironment env;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('mobissh_dx_widget_');
    env = FakeCrashEnvironment(dir: Directory('${tempRoot.path}/crashes')
      ..createSync(recursive: true));
    CrashReporter.reset();
  });

  tearDown(() async {
    CrashReporter.reset();
    try {
      await tempRoot.delete(recursive: true);
    } catch (_) {
      // Ignore lock contention on Windows; the OS cleans tempdirs.
    }
  });

  Future<void> pumpBounded(WidgetTester tester) async {
    // Several small pumps so the FutureBuilder's async work resolves without
    // pumpAndSettle (which can hang on lingering animations or stream subs
    // under the test runner's fake async). We sandwich a runAsync block in
    // the middle because flutter_test's fake-async clock does NOT advance
    // real-world filesystem ops (Directory.list is real I/O); runAsync gives
    // the Dart runtime a chance to process those microtasks.
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// Seeds the env's crashes dir with [count] JSON files directly (bypassing
  /// the reporter's write path) so the widget tests don't depend on async
  /// fsync paths under flutter_test's runner. Returns the seeded files in
  /// timestamp order.
  List<File> seedCrashes(int count) {
    final files = <File>[];
    for (var i = 0; i < count; i++) {
      final stamp = '20260522T1000${i.toString().padLeft(2, '0')}';
      final file = File('${env.dir.path}/$stamp-dart.json');
      file.writeAsStringSync('{"schema":1,"kind":"dart","seq":$i,"error":"seed-$i"}');
      files.add(file);
    }
    return files;
  }

  Future<void> pumpWithCrashes(WidgetTester tester, int count) async {
    CrashReporter.configure(env: env);
    seedCrashes(count);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: DiagnosticsSection()),
      ),
    );
    await pumpBounded(tester);
  }

  testWidgets('share button hidden when no crashes exist',
      (tester) async {
    await pumpWithCrashes(tester, 0);

    await tester.tap(find.byKey(const ValueKey('diagnostics-section')));
    await pumpBounded(tester);

    expect(find.byKey(const ValueKey('share-last-crash-button')), findsNothing);
    expect(find.text('No crash report on disk.'), findsOneWidget);
  });

  testWidgets('share button visible when one crash exists',
      (tester) async {
    await pumpWithCrashes(tester, 1);

    await tester.tap(find.byKey(const ValueKey('diagnostics-section')));
    await pumpBounded(tester);

    expect(
        find.byKey(const ValueKey('share-last-crash-button')), findsOneWidget);
  },
      // TODO(#501): flutter_test's fake-async clock doesn't reliably drive
      // Directory.list() to completion within bounded pumps. The unit-test
      // suite (test/diagnostics/crash_reporter_test.dart) covers the same
      // logic against real I/O. Re-enable once we have a `runAsync`-friendly
      // wrapper around the FutureBuilder, or switch the widget to a
      // Listenable model that updates synchronously.
      skip: true);

  testWidgets('force upload button triggers uploadPending and shows snackbar',
      (tester) async {
    var calls = 0;
    CrashReporter.configure(
      env: env,
      httpClient: MockClient((req) async {
        calls++;
        return http.Response('ok', 200);
      }),
      endpoint: 'http://fake/endpoint',
    );
    seedCrashes(1);

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: DiagnosticsSection())),
    );
    // Bounded pumps only — pumpAndSettle waits for the snackbar's 4s
    // dismiss animation and we don't need it.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    await tester.tap(find.byKey(const ValueKey('diagnostics-section')));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.byKey(const ValueKey('force-upload-button')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(calls, 1);
    expect(
        find.textContaining('Uploaded'), findsOneWidget,
        reason: 'snackbar should report upload result');
  },
      // TODO(#501): see skip note on "share button visible when one crash"
      // — same fake-async + file-system interaction issue. Force-upload
      // logic is covered by crash_reporter_test.dart's uploadPending tests.
      skip: true);

  testWidgets('share button invokes injected handler with latest file',
      (tester) async {
    CrashReporter.configure(env: env);
    seedCrashes(2); // last file's stamp sorts highest lexicographically

    File? sharedFile;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DiagnosticsSection(
            onShare: (file) async {
              sharedFile = file;
            },
          ),
        ),
      ),
    );
    await pumpBounded(tester);
    await tester.tap(find.byKey(const ValueKey('diagnostics-section')));
    await pumpBounded(tester);
    await tester.tap(find.byKey(const ValueKey('share-last-crash-button')));
    await pumpBounded(tester);

    expect(sharedFile, isNotNull);
    final body = await sharedFile!.readAsString();
    // seedCrashes(2) writes seed-0 then seed-1; lexicographic sort places
    // seed-1's file last so it should be selected as the latest.
    expect(body, contains('seed-1'),
        reason: 'share button should fire with the most recent crash');
  },
      // TODO(#501): see skip note on "share button visible when one crash".
      // Share-handler invocation is exercised via the injected `onShare`
      // hook in DiagnosticsSection — once we move to a Listenable model the
      // assertion is one extra line.
      skip: true);
}
