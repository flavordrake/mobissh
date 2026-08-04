// Port-forward add form: the remote port MIRRORS the local port (#1094).
//
// The reported bug: the remote-port field carried `hintText: '8250'`, which
// Flutter paints INSIDE the empty field as grey placeholder text. Typing a
// local port left the user looking at a number in the remote field that reads
// as "auto-filled to match" — but the controller was still EMPTY, so Add threw
// 'Remote port must be 1–65535' and the user had to retype the same number.
//
// The fix makes the common case (local == remote) genuinely true instead of
// merely looking true: the local port is mirrored into the remote-port
// controller as a REAL value until the user types their own remote port.
//
// Driven over the same in-memory gateway pair as the #1054 preview tests (no
// live SSH); the assertion of record is the `forwardAdd` command that actually
// reaches the task side.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';

import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/ssh_session_proxy.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/storage/profiles_store.dart';
import 'package:mobissh/ui/port_forwards_sheet.dart';

const _sessionId = 'ra-server:22:me:1';

class _Harness {
  _Harness()
      : pair = InMemoryGatewayPair(),
        store = ProfilesStore() {
    proxy = SshSessionProxy(sessionId: _sessionId, gateway: pair.uiSide);
    entry = SessionEntry(
      id: _sessionId,
      host: 'ra-server',
      port: 22,
      username: 'me',
      proxy: proxy,
      terminal: Terminal(maxLines: 200),
    );
    // Record every UI → task command so the test can assert what was COMMITTED,
    // not merely what was rendered.
    pair.taskSide.incoming.listen(sent.add);
  }

  final InMemoryGatewayPair pair;
  final ProfilesStore store;
  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
  late final SshSessionProxy proxy;
  late final SessionEntry entry;

  Iterable<Map<String, dynamic>> get forwardAdds =>
      sent.where((m) => m['kind'] == 'forwardAdd');
}

Future<void> _pumpSheet(WidgetTester tester, _Harness h) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: PortForwardsSheet(entry: h.entry, store: h.store)),
    ),
  );
  await tester.pump();
}

String _fieldText(WidgetTester tester, String key) {
  return tester.widget<TextField>(find.byKey(Key(key))).controller!.text;
}

String _preview(WidgetTester tester) {
  return tester.widget<Text>(find.byKey(const Key('forward-preview'))).data!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('local port alone commits a forward with remotePort == localPort',
      (tester) async {
    final h = _Harness();
    addTearDown(h.proxy.dispose);
    addTearDown(h.pair.dispose);
    await _pumpSheet(tester, h);

    // The ONLY thing the user types is the local port — the exact reported flow.
    await tester.enterText(find.byKey(const Key('forward-local-port')), '8888');
    await tester.pump();
    await tester.tap(find.byKey(const Key('forward-add-submit')));
    await tester.pump();

    // No "retype the same number" error.
    expect(find.byKey(const Key('forward-form-error')), findsNothing);
    expect(find.text('Remote port must be 1–65535'), findsNothing);

    // And the forward was ACTUALLY committed, mirrored end to end.
    await tester.pump(const Duration(milliseconds: 50));
    expect(h.forwardAdds, hasLength(1));
    final add = h.forwardAdds.single;
    expect(add['localPort'], 8888);
    expect(add['remotePort'], 8888);
    expect(add['remoteHost'], '127.0.0.1');
  });

  testWidgets('the mirrored value is visible in the field and the preview',
      (tester) async {
    final h = _Harness();
    addTearDown(h.proxy.dispose);
    addTearDown(h.pair.dispose);
    await _pumpSheet(tester, h);

    await tester.enterText(find.byKey(const Key('forward-local-port')), '8080');
    await tester.pump();

    // A real controller value, not a hint that merely looks like one.
    expect(_fieldText(tester, 'forward-remote-port'), '8080');
    expect(_preview(tester), '8080  →  127.0.0.1:8080');
  });

  testWidgets('a user-typed remote port is never clobbered by later local edits',
      (tester) async {
    final h = _Harness();
    addTearDown(h.proxy.dispose);
    addTearDown(h.pair.dispose);
    await _pumpSheet(tester, h);

    await tester.enterText(find.byKey(const Key('forward-local-port')), '8080');
    await tester.pump();
    // The deliberate 8080 → 80 mapping.
    await tester.enterText(find.byKey(const Key('forward-remote-port')), '80');
    await tester.pump();
    expect(_fieldText(tester, 'forward-remote-port'), '80');

    // Changing the local port must NOT overwrite the explicit remote port.
    await tester.enterText(find.byKey(const Key('forward-local-port')), '9090');
    await tester.pump();
    expect(_fieldText(tester, 'forward-remote-port'), '80');
    expect(_preview(tester), '9090  →  127.0.0.1:80');

    await tester.tap(find.byKey(const Key('forward-add-submit')));
    await tester.pump(const Duration(milliseconds: 50));
    expect(h.forwardAdds, hasLength(1));
    expect(h.forwardAdds.single['localPort'], 9090);
    expect(h.forwardAdds.single['remotePort'], 80);
  });

  testWidgets('clearing the local port strands no stale mirrored value',
      (tester) async {
    final h = _Harness();
    addTearDown(h.proxy.dispose);
    addTearDown(h.pair.dispose);
    await _pumpSheet(tester, h);

    await tester.enterText(find.byKey(const Key('forward-local-port')), '8080');
    await tester.pump();
    expect(_fieldText(tester, 'forward-remote-port'), '8080');

    await tester.enterText(find.byKey(const Key('forward-local-port')), '');
    await tester.pump();
    expect(_fieldText(tester, 'forward-remote-port'), '');
    expect(_preview(tester), '·  →  127.0.0.1:·');
  });

  testWidgets('clearing the remote port re-arms the mirror', (tester) async {
    final h = _Harness();
    addTearDown(h.proxy.dispose);
    addTearDown(h.pair.dispose);
    await _pumpSheet(tester, h);

    await tester.enterText(find.byKey(const Key('forward-local-port')), '8080');
    await tester.pump();
    await tester.enterText(find.byKey(const Key('forward-remote-port')), '80');
    await tester.pump();
    // Wiping the explicit value hands the field back to the mirror; it does NOT
    // refill on the spot (that would corrupt backspace-then-retype).
    await tester.enterText(find.byKey(const Key('forward-remote-port')), '');
    await tester.pump();
    expect(_fieldText(tester, 'forward-remote-port'), '');

    await tester.enterText(find.byKey(const Key('forward-local-port')), '9090');
    await tester.pump();
    expect(_fieldText(tester, 'forward-remote-port'), '9090');
  });

  testWidgets('the add form resets to mirroring after a successful add',
      (tester) async {
    final h = _Harness();
    addTearDown(h.proxy.dispose);
    addTearDown(h.pair.dispose);
    await _pumpSheet(tester, h);

    await tester.enterText(find.byKey(const Key('forward-local-port')), '8080');
    await tester.pump();
    await tester.enterText(find.byKey(const Key('forward-remote-port')), '80');
    await tester.pump();
    await tester.tap(find.byKey(const Key('forward-add-submit')));
    await tester.pump();

    // Both port fields are emptied, and the next entry mirrors again.
    expect(_fieldText(tester, 'forward-local-port'), '');
    expect(_fieldText(tester, 'forward-remote-port'), '');

    await tester.enterText(find.byKey(const Key('forward-local-port')), '5900');
    await tester.pump();
    expect(_fieldText(tester, 'forward-remote-port'), '5900');
  });

  testWidgets('no numeric hint can be mistaken for a committed port value',
      (tester) async {
    final h = _Harness();
    addTearDown(h.proxy.dispose);
    addTearDown(h.pair.dispose);
    await _pumpSheet(tester, h);

    for (final key in const ['forward-local-port', 'forward-remote-port']) {
      final hint = tester
          .widget<TextField>(find.byKey(Key(key)))
          .decoration
          ?.hintText;
      expect(
        hint,
        anyOf(isNull, isNot(matches(RegExp(r'\d')))),
        reason: '$key hint must not look like a real port value (#1094)',
      );
    }
  });
}
