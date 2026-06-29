// Widget tests for the Connect log tile in DiagnosticsSection (#543).
//
// Asserts:
//   - ctrace lines render in order inside the expanded tile.
//   - Copy button puts the joined log on the (mock) clipboard.
//   - Clear button empties the buffer.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobissh/diagnostics/connect_trace.dart';
import 'package:mobissh/ui/diagnostics_section.dart';

void main() {
  // Mock clipboard so Clipboard.setData doesn't hit a real platform channel.
  final clipboard = <String, dynamic>{};

  setUp(() {
    clearConnectLog();
    clipboard.clear();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    // The Copy button now routes through the hardened `mobissh/clipboard`
    // native channel (#845) + reads back via the platform `Clipboard.getData`.
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
    clearConnectLog();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('mobissh/clipboard'),
      null,
    );
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<void> pumpBounded(WidgetTester tester) async {
    // #897: the section is flat now — the connect-log block + Copy/Clear sit at
    // the bottom of a scroll view. Use a tall viewport so every control fits
    // on-screen and is hit-testable without a scroll.
    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  // #897: the diagnostics section + connect-log block are flat now — the output
  // and Copy/Clear are visible with no expander taps. A bounded settle is still
  // needed for the FutureBuilder snapshot.
  Future<void> settleAll(WidgetTester tester) async {
    await pumpBounded(tester);
  }

  testWidgets('renders ctrace lines in order when expanded', (tester) async {
    ctrace('ui.form', 'submit');
    ctrace('ui.sessions', 'open');
    ctrace('ui.gw', 'flush');

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: DiagnosticsSection()),
        ),
      ),
    );
    await pumpBounded(tester);
    await settleAll(tester);

    final output = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('connect-log-output')),
        matching: find.byType(Text),
      ),
    );
    final text = output.data!;
    expect(text, contains('[ui.form] submit'));
    expect(text, contains('[ui.sessions] open'));
    expect(text, contains('[ui.gw] flush'));
    // Order: form before sessions before gw.
    expect(text.indexOf('submit'), lessThan(text.indexOf('open')));
    expect(text.indexOf('open'), lessThan(text.indexOf('flush')));
  });

  testWidgets('copy button puts the joined log on the clipboard',
      (tester) async {
    ctrace('ui.form', 'submit');
    ctrace('ui.gw', 'flush');

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: DiagnosticsSection()),
        ),
      ),
    );
    await pumpBounded(tester);
    await settleAll(tester);

    await tester.tap(find.byKey(const ValueKey('connect-log-copy-button')));
    await pumpBounded(tester);

    expect(clipboard['text'], isNotNull);
    expect(clipboard['text'] as String, contains('[ui.form] submit'));
    expect(clipboard['text'] as String, contains('[ui.gw] flush'));
  });

  testWidgets('clear button empties the output', (tester) async {
    ctrace('ui.form', 'submit');

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: DiagnosticsSection()),
        ),
      ),
    );
    await pumpBounded(tester);
    await settleAll(tester);

    expect(connectLog.value, isNotEmpty);

    await tester.tap(find.byKey(const ValueKey('connect-log-clear-button')));
    await pumpBounded(tester);

    expect(connectLog.value, isEmpty);
    expect(find.text('No connect trace yet. Start a connection.'),
        findsOneWidget);
  });
}
