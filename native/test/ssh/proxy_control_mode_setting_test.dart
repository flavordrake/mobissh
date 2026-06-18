// #913 Part D: the persisted tmux-control-mode SETTING drives the wire field.
//
// The UI proxy's `connect()` reads the per-isolate `tmuxControlMode` global at
// connect time and carries it across the gateway as `SshConnectCommand.controlMode`
// (Part C, #911). Part D makes the persisted SETTING the authoritative source for
// that global (TmuxControlModeNotifier writes it on hydrate + set). These tests
// drive the notifier (the real settings surface) and assert the proxy's connect
// command carries the resulting bit: setting ON → `controlMode:true` on the wire;
// setting OFF → the field is OMITTED (the shipped scrape wire shape is unchanged).
//
// Runs against an `InMemoryGatewayPair` (the same harness as proxy_resize_dedupe):
// the proxy pushes a connect command onto the UI→task channel which we observe on
// the task side and inspect for the `controlMode` key.

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_session_proxy.dart';
import 'package:mobissh/state/tmux_control_mode_setting.dart';
import 'package:mobissh/terminal/tmux_control_mode_flag.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic>? _connectCmd(List<Map<String, dynamic>> seen) {
  for (final p in seen) {
    if (p['kind'] == SshTaskCommandKind.connect.name) return p;
  }
  return null;
}

const _params = SshConnectParams(
  host: 'host',
  port: 22,
  username: 'user',
  auth: SshAuth.password('secret'),
);

Future<void> _settleHydrate() =>
    Future<void>.delayed(const Duration(milliseconds: 10));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late InMemoryGatewayPair pair;
  late List<Map<String, dynamic>> seen;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setTmuxControlModeForTest(false);
    pair = InMemoryGatewayPair();
    seen = <Map<String, dynamic>>[];
    pair.taskSide.incoming.listen(seen.add);
  });

  tearDown(() async {
    setTmuxControlModeForTest(false);
    await pair.dispose();
  });

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test(
    'setting OFF (default): connect omits controlMode (scrape wire unchanged)',
    () async {
      final n = TmuxControlModeNotifier(prefs: SharedPreferences.getInstance());
      addTearDown(n.dispose);
      await _settleHydrate();
      expect(n.state, isFalse);

      final proxy = SshSessionProxy(sessionId: 's1', gateway: pair.uiSide);
      addTearDown(proxy.dispose);
      await proxy.connect(_params);
      await settle();

      final cmd = _connectCmd(seen);
      expect(cmd, isNotNull);
      expect(
        cmd!.containsKey('controlMode'),
        isFalse,
        reason: 'setting OFF must leave the wire shape unchanged — no extra '
            'field, the shipped scrape path',
      );
    },
  );

  test('setting ON: connect carries controlMode:true on the wire', () async {
    final n = TmuxControlModeNotifier(prefs: SharedPreferences.getInstance());
    addTearDown(n.dispose);
    await _settleHydrate();
    // The owner enables the opt-in in Settings.
    await n.set(true);
    expect(tmuxControlMode, isTrue);

    final proxy = SshSessionProxy(sessionId: 's1', gateway: pair.uiSide);
    addTearDown(proxy.dispose);
    await proxy.connect(_params);
    await settle();

    final cmd = _connectCmd(seen);
    expect(cmd, isNotNull);
    expect(
      cmd!['controlMode'],
      isTrue,
      reason: 'enabling the persisted setting must make the next connect carry '
          'control mode across the gateway',
    );

    // Round-trips back into a typed command with the bit set.
    final restored = SshTaskCommand.fromJson(cmd) as SshConnectCommand;
    expect(restored.controlMode, isTrue);
  });

  test('hydrated-ON setting drives connect with no explicit set()', () async {
    SharedPreferences.setMockInitialValues({tmuxControlModePrefKey: true});
    final n = TmuxControlModeNotifier(prefs: SharedPreferences.getInstance());
    addTearDown(n.dispose);
    await _settleHydrate();
    expect(tmuxControlMode, isTrue);

    final proxy = SshSessionProxy(sessionId: 's1', gateway: pair.uiSide);
    addTearDown(proxy.dispose);
    await proxy.connect(_params);
    await settle();

    expect(_connectCmd(seen)!['controlMode'], isTrue);
  });

  test('toggling OFF after ON reverts the wire to omitted', () async {
    final n = TmuxControlModeNotifier(prefs: SharedPreferences.getInstance());
    addTearDown(n.dispose);
    await _settleHydrate();
    await n.set(true);
    await n.set(false);

    final proxy = SshSessionProxy(sessionId: 's2', gateway: pair.uiSide);
    addTearDown(proxy.dispose);
    await proxy.connect(_params);
    await settle();

    expect(_connectCmd(seen)!.containsKey('controlMode'), isFalse);
  });
}
