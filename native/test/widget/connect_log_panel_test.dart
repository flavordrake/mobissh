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
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
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
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<void> pumpBounded(WidgetTester tester) async {
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> expandAll(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('diagnostics-section')));
    await pumpBounded(tester);
    await tester.tap(find.byKey(const ValueKey('connect-log-tile')));
    await pumpBounded(tester);
  }

  testWidgets('renders ctrace lines in order when expanded', (tester) async {
    ctrace('ui.form', 'submit');
    ctrace('ui.sessions', 'open');
    ctrace('ui.gw', 'flush');

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: DiagnosticsSection())),
    );
    await pumpBounded(tester);
    await expandAll(tester);

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
      const MaterialApp(home: Scaffold(body: DiagnosticsSection())),
    );
    await pumpBounded(tester);
    await expandAll(tester);

    await tester.tap(find.byKey(const ValueKey('connect-log-copy-button')));
    await pumpBounded(tester);

    expect(clipboard['text'], isNotNull);
    expect(clipboard['text'] as String, contains('[ui.form] submit'));
    expect(clipboard['text'] as String, contains('[ui.gw] flush'));
  });

  testWidgets('clear button empties the output', (tester) async {
    ctrace('ui.form', 'submit');

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: DiagnosticsSection())),
    );
    await pumpBounded(tester);
    await expandAll(tester);

    expect(connectLog.value, isNotEmpty);

    await tester.tap(find.byKey(const ValueKey('connect-log-clear-button')));
    await pumpBounded(tester);

    expect(connectLog.value, isEmpty);
    expect(find.text('No connect trace yet. Start a connection.'),
        findsOneWidget);
  });
}
