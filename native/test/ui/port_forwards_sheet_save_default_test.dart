// Port-forward add form: "Save to profile" is a checkbox that defaults ON.
//
// Owner report (rc.4, 2026-09-04): "Forwards are still not persisting from
// session to session … give me the option … as a check that defaults to true."
// Before this, persistence was an opt-in per-row star that was easy to miss:
// Add armed the forward on the live session only, and the next connect had no
// memory of it. Now, when the session has a saved profile, Add ALSO writes the
// forward to the profile unless the user unchecks the box. Ad-hoc sessions
// (no saved profile) get no checkbox — we never materialize a profile (#640).
//
// Same in-memory gateway harness as the #1094 mirror tests.

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
const _identityKey = 'ra-server:22:me';

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
    pair.taskSide.incoming.listen(sent.add);
  }

  final InMemoryGatewayPair pair;
  final ProfilesStore store;
  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
  late final SshSessionProxy proxy;
  late final SessionEntry entry;

  Iterable<Map<String, dynamic>> get forwardAdds =>
      sent.where((m) => m['kind'] == 'forwardAdd');

  Future<void> saveProfile({List<ProfileForward> forwards = const []}) {
    return store.save(<SavedProfile>[
      SavedProfile(
        title: 'RA',
        host: 'ra-server',
        port: 22,
        username: 'me',
        authType: 'password',
        forwards: forwards,
      ),
    ]);
  }

  Future<List<ProfileForward>> savedForwards() async {
    final profiles = await store.load();
    return profiles.singleWhere((p) => p.identityKey == _identityKey).forwards;
  }
}

Future<void> _pumpSheet(WidgetTester tester, _Harness h) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: PortForwardsSheet(entry: h.entry, store: h.store)),
    ),
  );
  // Let _loadDefaults() settle so _hasProfile reflects the store.
  await tester.pump();
  await tester.pump();
}

Future<void> _add(WidgetTester tester, String localPort) async {
  await tester.enterText(find.byKey(const Key('forward-local-port')), localPort);
  await tester.pump();
  await tester.tap(find.byKey(const Key('forward-add-submit')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

Finder get _checkbox => find.byKey(const Key('forward-save-default'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('checkbox is present and checked by default with a saved profile',
      (tester) async {
    final h = _Harness();
    addTearDown(h.proxy.dispose);
    addTearDown(h.pair.dispose);
    await h.saveProfile();
    await _pumpSheet(tester, h);

    expect(_checkbox, findsOneWidget);
    final box = tester.widget<Checkbox>(
      find.descendant(of: _checkbox, matching: find.byType(Checkbox)),
    );
    expect(box.value, isTrue, reason: 'owner-specified default is ON');
  });

  testWidgets('Add persists the forward to the profile by default',
      (tester) async {
    final h = _Harness();
    addTearDown(h.proxy.dispose);
    addTearDown(h.pair.dispose);
    await h.saveProfile();
    await _pumpSheet(tester, h);

    await _add(tester, '8080');

    // Still armed on the live session…
    expect(h.forwardAdds, hasLength(1));
    // …AND remembered for the next connect.
    final saved = await h.savedForwards();
    expect(saved, hasLength(1));
    expect(saved.single.localPort, 8080);
    expect(saved.single.remoteHost, '127.0.0.1');
    expect(saved.single.remotePort, 8080);
  });

  testWidgets('Add merges with existing profile forwards (no clobber)',
      (tester) async {
    final h = _Harness();
    addTearDown(h.proxy.dispose);
    addTearDown(h.pair.dispose);
    await h.saveProfile(forwards: const [
      ProfileForward(localPort: 5432, remoteHost: 'db', remotePort: 5432),
    ]);
    await _pumpSheet(tester, h);

    await _add(tester, '8080');

    final saved = await h.savedForwards();
    expect(saved.map((f) => f.localPort), unorderedEquals(<int>[5432, 8080]));
    expect(
      saved.singleWhere((f) => f.localPort == 5432).remoteHost,
      'db',
      reason: 'a pre-existing default must survive an unrelated Add',
    );
  });

  testWidgets('unchecked → Add arms the session only', (tester) async {
    final h = _Harness();
    addTearDown(h.proxy.dispose);
    addTearDown(h.pair.dispose);
    await h.saveProfile();
    await _pumpSheet(tester, h);

    await tester.tap(_checkbox);
    await tester.pump();
    await _add(tester, '8080');

    expect(h.forwardAdds, hasLength(1));
    expect(await h.savedForwards(), isEmpty);
  });

  testWidgets('no checkbox for an ad-hoc session (no saved profile)',
      (tester) async {
    final h = _Harness();
    addTearDown(h.proxy.dispose);
    addTearDown(h.pair.dispose);
    await _pumpSheet(tester, h);

    expect(_checkbox, findsNothing);
    await _add(tester, '8080');
    expect(h.forwardAdds, hasLength(1));
    // Never materialize a profile for an ad-hoc session (#640 idiom).
    expect(await h.store.load(), isEmpty);
  });
}
