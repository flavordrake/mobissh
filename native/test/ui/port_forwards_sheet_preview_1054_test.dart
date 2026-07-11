// Port-forward sheet live preview + direction semantics (#1054).
//
// The refinement over #1047 is UI-only: an add-form effect line that reads
// `localPort → remoteHost:remotePort` live as the fields change, a
// plain-language semantics line naming the session host, and list rows that
// render the same compact mapping. These tests drive the real widget over an
// in-memory gateway pair (no live SSH) and seed the forward table by pushing a
// SshForwardListEvent from the task side.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';

import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/ssh_session_proxy.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/storage/profiles_store.dart';
import 'package:mobissh/ui/port_forwards_sheet.dart';

const _sessionId = 'ra-server:22:me:1';
const _sessionHost = 'ra-server';

class _Harness {
  _Harness()
      : pair = InMemoryGatewayPair(),
        store = ProfilesStore() {
    proxy = SshSessionProxy(sessionId: _sessionId, gateway: pair.uiSide);
    entry = SessionEntry(
      id: _sessionId,
      host: _sessionHost,
      port: 22,
      username: 'me',
      proxy: proxy,
      terminal: Terminal(maxLines: 200),
    );
  }

  final InMemoryGatewayPair pair;
  final ProfilesStore store;
  late final SshSessionProxy proxy;
  late final SessionEntry entry;

  /// Push an authoritative forward table from the task side → proxy → sheet.
  void pushForwards(List<ForwardInfo> forwards) {
    pair.taskSide.send(
      SshForwardListEvent(sessionId: _sessionId, forwards: forwards).toJson(),
    );
  }
}

Future<void> _pumpSheet(WidgetTester tester, _Harness h) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: PortForwardsSheet(entry: h.entry, store: h.store),
      ),
    ),
  );
  await tester.pump();
}

String _text(WidgetTester tester, Key key) {
  return tester.widget<Text>(find.byKey(key)).data!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('previewMapping: blank remote host resolves to 127.0.0.1', () {
    expect(
      PortForwardsSheet.previewMapping('8888', '', '8250'),
      '8888  →  127.0.0.1:8250',
    );
    expect(
      PortForwardsSheet.previewMapping('8888', 'hostname', '8250'),
      '8888  →  hostname:8250',
    );
  });

  test('previewSemantics threads the session host + endpoints', () {
    final line =
        PortForwardsSheet.previewSemantics('8888', 'hostname', '8250', 'ra-server');
    expect(line, contains('127.0.0.1:8888'));
    expect(line, contains('hostname:8250'));
    expect(line, contains('ra-server'));
  });

  testWidgets('preview + semantics update live as fields change', (tester) async {
    final h = _Harness();
    addTearDown(h.proxy.dispose);
    await _pumpSheet(tester, h);

    // Blank form: default remote host is shown, ports are placeholders.
    expect(
      _text(tester, const Key('forward-preview')),
      contains('127.0.0.1'),
    );

    await tester.enterText(find.byKey(const Key('forward-local-port')), '8888');
    await tester.pump();
    // Blank remote host still resolves to the default in the live preview.
    expect(
      _text(tester, const Key('forward-preview')),
      '8888  →  127.0.0.1:·',
    );

    await tester.enterText(
      find.byKey(const Key('forward-remote-host')),
      'hostname',
    );
    await tester.enterText(
      find.byKey(const Key('forward-remote-port')),
      '8250',
    );
    await tester.pump();

    expect(
      _text(tester, const Key('forward-preview')),
      '8888  →  hostname:8250',
    );

    final semantics = _text(tester, const Key('forward-preview-semantics'));
    expect(semantics, contains('127.0.0.1:8888'));
    expect(semantics, contains('hostname:8250'));
    // The session host is threaded read-only into the direction sentence.
    expect(semantics, contains(_sessionHost));
  });

  testWidgets('list row renders the compact L → host:R mapping', (tester) async {
    final h = _Harness();
    addTearDown(h.proxy.dispose);
    await _pumpSheet(tester, h);

    h.pushForwards(const [
      ForwardInfo(
        localPort: 8888,
        remoteHost: 'hostname',
        remotePort: 8250,
        status: ForwardStatus.active,
      ),
    ]);
    // Two broadcast hops (gateway → proxy → sheet); let the event loop turn.
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump();

    expect(find.byKey(const Key('forward-row-8888')), findsOneWidget);
    expect(find.text('8888  →  hostname:8250'), findsOneWidget);
    // Status label is present alongside the mapping.
    expect(find.text('Active'), findsOneWidget);
  });
}
