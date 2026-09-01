// Every keybar TAP gives a haptic click (owner, 2026-09-01: "keybar tap for -
// didn't provide haptic feedback, it should").
//
// Before this, only the #732 auto-repeat ticks clicked; a plain tap on any key
// was silent. The haptic must fire regardless of where the key's bytes land —
// terminal, or the compose buffer via the #1131 route (the owner's `-` case) —
// and for the byte-less keys (Ctrl arm, Reset) too, since the finger did tap.
//
// The tap is exercised by invoking the button's `onPressed` directly rather
// than `tester.tap` — the Material ripple hangs bounded pumps in this harness
// (see keybar_test.dart's skipped tap tests).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/state/compose_sink_provider.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/ui/keybar.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final haptics = <String>[];

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    haptics.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            haptics.add(call.arguments as String);
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<void> pumpKeybar(
    WidgetTester tester, {
    ComposeSink? sink,
  }) async {
    final pair = InMemoryGatewayPair();
    addTearDown(() async {
      await pair.dispose();
    });
    final container = ProviderContainer(
      overrides: [
        taskSshGatewayProvider.overrideWithValue(pair.uiSide),
        if (sink != null) composeSinkProvider.overrideWith((ref) => sink),
      ],
    );
    addTearDown(container.dispose);
    final entry = container
        .read(sessionsProvider.notifier)
        .addOrActivate(
          const SshConnectParams(
            host: 'h',
            port: 22,
            username: 'u',
            auth: SshAuth.password('p'),
          ),
        );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: Scaffold(body: Keybar(activeEntry: entry))),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }

  void press(WidgetTester tester, String id) {
    tester
        .widget<OutlinedButton>(find.byKey(Key('keybar-btn-$id')))
        .onPressed!();
  }

  testWidgets('tapping - with the compose bar OPEN clicks (owner case)', (
    tester,
  ) async {
    final inserted = <String>[];
    await pumpKeybar(
      tester,
      sink: ComposeSink(
        insertText: inserted.add,
        submit: () {},
        hasText: () => false,
      ),
    );
    press(tester, 'keyDash');
    expect(inserted, ['-'], reason: '#1131 route still lands in compose');
    expect(haptics, ['HapticFeedbackType.selectionClick']);
  });

  testWidgets('tapping - with the compose bar CLOSED clicks', (tester) async {
    await pumpKeybar(tester);
    press(tester, 'keyDash');
    expect(haptics, ['HapticFeedbackType.selectionClick']);
  });

  testWidgets('nav, modifier and reset taps each click exactly once', (
    tester,
  ) async {
    await pumpKeybar(tester);
    for (final id in ['keyLeft', 'keyCtrl', 'keyCtrl', 'keyResetInput']) {
      press(tester, id);
    }
    expect(haptics, hasLength(4));
    expect(haptics.toSet(), {'HapticFeedbackType.selectionClick'});
  });
}
