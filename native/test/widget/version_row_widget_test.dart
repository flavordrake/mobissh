// Widget tests for the Settings panel app-version row.
//
// The owner had no on-screen way to see/screenshot the running build — he
// could only get it from a bug-report upload. This row shows the SAME build
// string the bug-report carries (`[<version>+<build> <gitHash>]`) and copies
// it to the clipboard on tap. (relates to #897.)
//
// Asserts:
//   - the row renders the injected version string when the panel is expanded.
//   - tapping the row routes the full string through copyToClipboard (the
//     hardened `mobissh/clipboard` channel) — i.e. the clipboard ends up
//     containing the version.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ui/settings_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _fixedVersion = '[0.1.10+69 F01111D9]';

Future<void> pumpSettings(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SettingsPanel(
              versionResolver: () async => _fixedVersion,
            ),
          ),
        ),
      ),
    ),
  );
  // Bounded pumps to let the hydrate Futures + the version FutureBuilder resolve.
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

// #897: the panel is flat — every control is top-level, no expander tap needed.
// A few bounded pumps let the version FutureBuilder resolve.
Future<void> settleSettings(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Mock clipboard so the copy doesn't hit a real platform channel. Mirrors
  // connect_log_panel_test.dart: copyToClipboard() routes through the hardened
  // `mobissh/clipboard` native channel and reads back via SystemChannels.platform.
  final clipboard = <String, dynamic>{};

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    clipboard.clear();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('mobissh/clipboard'),
      (call) async {
        if (call.method == 'setText') {
          clipboard['text'] = (call.arguments as Map)['text'];
          return true;
        }
        return null;
      },
    );
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard['text'] = (call.arguments as Map)['text'];
      }
      if (call.method == 'Clipboard.getData') {
        return <String, dynamic>{'text': clipboard['text']};
      }
      return null;
    });
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('mobissh/clipboard'),
      null,
    );
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('renders the build version string from the resolver',
      (tester) async {
    await pumpSettings(tester);
    await settleSettings(tester);

    final tile = find.byKey(const ValueKey('app-version-tile'));
    expect(tile, findsOneWidget);

    final value = tester.widget<Text>(
      find.byKey(const ValueKey('app-version-value')),
    );
    expect(value.data, _fixedVersion);
  });

  testWidgets('tapping the version row copies the full string to the clipboard',
      (tester) async {
    await pumpSettings(tester);
    await settleSettings(tester);

    await tester.tap(find.byKey(const ValueKey('app-version-tile')));
    // Settle the async copyToClipboard + read-back + toast.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(clipboard['text'], _fixedVersion);
  });
}
