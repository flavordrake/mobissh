// A2 + A7 — jump opener composition and chain lifecycle (#1183, spec
// docs/jump-host.md R7, R11, R12, R13).
//
// A jump connection is an [SshSocketOpener] that dials the hops OUTERMOST-
// FIRST and hands back the forwarded channel for the final leg. No real
// sockets here: [_FakeHop] stands in for the per-hop SSH client
// ([JumpHopConnection]) and records every `forwardLocal` call, so the test
// asserts the CALL ORDER — the thing a "does it connect?" test cannot see.
//
// R12 ownership without touching the session state machine: the socket the
// chain hands back OWNS the hops behind it. Destroying/closing it (which is
// what `SshSessionController.disconnect` does to its socket, via
// `client.close()`) tears the whole chain down. That is why the leak test
// drives teardown through the returned socket as well as through
// `JumpChain.close()`.

import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobissh/ssh/jump_host.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/storage/profiles_store.dart';

/// Inert socket: opens, never speaks, records destruction.
class _FakeSocket implements SSHSocket {
  _FakeSocket(this.label);

  final String label;
  final _streamCtrl = StreamController<Uint8List>();
  final _sinkCtrl = StreamController<List<int>>();
  final _doneCompleter = Completer<void>();
  bool destroyed = false;
  bool closed = false;

  @override
  Stream<Uint8List> get stream => _streamCtrl.stream;

  @override
  StreamSink<List<int>> get sink => _sinkCtrl.sink;

  @override
  Future<void> get done => _doneCompleter.future;

  @override
  Future<void> close() {
    closed = true;
    if (!_doneCompleter.isCompleted) _doneCompleter.complete();
    return done;
  }

  @override
  void destroy() {
    destroyed = true;
    if (!_streamCtrl.isClosed) _streamCtrl.close();
    if (!_sinkCtrl.isClosed) _sinkCtrl.close();
    if (!_doneCompleter.isCompleted) _doneCompleter.complete();
  }

  @override
  String toString() => 'FakeSocket($label)';
}

/// One hop's authenticated SSH client. `forwardLocal` hands back a fresh
/// [_FakeSocket] standing in for dartssh2's `SSHForwardChannel`.
class _FakeHop implements JumpHopConnection {
  _FakeHop(this.profile, this.socket, this.log, {this.forwardError});

  final SavedProfile profile;
  final SSHSocket socket;
  final List<String> log;

  /// When set, `forwardLocal` throws this instead of forwarding (half-open).
  final Object? forwardError;

  final List<SSHSocket> forwarded = <SSHSocket>[];
  bool closedFlag = false;

  @override
  Future<SSHSocket> forwardLocal(String host, int port) async {
    log.add('forward ${profile.host} -> $host:$port');
    if (forwardError != null) throw forwardError!;
    final channel = _FakeSocket('${profile.host}=>$host:$port');
    forwarded.add(channel);
    return channel;
  }

  @override
  Future<void> close() async {
    closedFlag = true;
    log.add('close ${profile.host}');
  }
}

SavedProfile _p(String host, {int port = 22, String user = 'me'}) =>
    SavedProfile(title: host, host: host, port: port, username: user);

/// Records every base-opener dial and the timeout it was handed.
class _BaseOpener {
  _BaseOpener(this.log);

  final List<String> log;
  final List<Duration?> timeouts = <Duration?>[];
  final List<_FakeSocket> opened = <_FakeSocket>[];
  Object? error;

  Future<SSHSocket> call(String host, int port, {Duration? timeout}) async {
    log.add('dial $host:$port');
    timeouts.add(timeout);
    if (error != null) throw error!;
    final s = _FakeSocket('base:$host:$port');
    opened.add(s);
    return s;
  }
}

/// Builds [_FakeHop]s and remembers them in creation order.
class _Connector {
  _Connector(this.log, {this.failAt, this.forwardErrorAt});

  final List<String> log;

  /// 0-based hop index whose connector call throws (auth failure, R11).
  final int? failAt;

  /// 0-based hop index whose `forwardLocal` throws (half-open chain, R13).
  final int? forwardErrorAt;

  final List<_FakeHop> hops = <_FakeHop>[];
  final List<Duration?> timeouts = <Duration?>[];

  Future<JumpHopConnection> call(
    SavedProfile hop,
    SSHSocket socket, {
    Duration? timeout,
  }) async {
    final index = hops.length;
    log.add('auth ${hop.host}');
    timeouts.add(timeout);
    if (failAt == index) throw Exception('auth failed');
    final h = _FakeHop(
      hop,
      socket,
      log,
      forwardError: forwardErrorAt == index ? Exception('channel refused') : null,
    );
    hops.add(h);
    return h;
  }
}

void main() {
  group('A2 — opener composition (R7)', () {
    test('a single hop dials the bastion, then forwards to the target', () async {
      final log = <String>[];
      final base = _BaseOpener(log);
      final connector = _Connector(log);
      final chain = JumpChain(
        hops: [_p('bastion.example')],
        base: base.call,
        connector: connector.call,
      );

      final socket = await chain.opener('target.example', 22);

      expect(log, [
        'dial bastion.example:22',
        'auth bastion.example',
        'forward bastion.example -> target.example:22',
      ]);
      expect(
        identical(socket, connector.hops.single.forwarded.single),
        isTrue,
        reason: 'the opener must return the FORWARDED channel, not the base '
            'socket — that channel is the target session transport',
      );
    });

    test('three hops dial OUTERMOST-FIRST and chain each channel', () async {
      final log = <String>[];
      final base = _BaseOpener(log);
      final connector = _Connector(log);
      final chain = JumpChain(
        hops: [
          _p('outer.example'),
          _p('mid.example', port: 2022),
          _p('inner.example'),
        ],
        base: base.call,
        connector: connector.call,
      );

      final socket = await chain.opener('target.example', 2222);

      expect(log, [
        'dial outer.example:22',
        'auth outer.example',
        'forward outer.example -> mid.example:2022',
        'auth mid.example',
        'forward mid.example -> inner.example:22',
        'auth inner.example',
        'forward inner.example -> target.example:2222',
      ]);
      expect(
        base.opened,
        hasLength(1),
        reason: 'only the OUTERMOST hop uses a real TCP dial; every inner leg '
            'rides a direct-tcpip channel',
      );
      expect(identical(socket, connector.hops.last.forwarded.single), isTrue);
    });

    test('each hop is authenticated over the channel the previous hop opened', () async {
      final log = <String>[];
      final base = _BaseOpener(log);
      final connector = _Connector(log);
      final chain = JumpChain(
        hops: [_p('outer.example'), _p('inner.example')],
        base: base.call,
        connector: connector.call,
      );

      await chain.opener('target.example', 22);

      expect(identical(connector.hops[0].socket, base.opened.single), isTrue);
      expect(
        identical(connector.hops[1].socket, connector.hops[0].forwarded.single),
        isTrue,
      );
    });

    test('the connect timeout propagates to the base dial AND to every hop', () async {
      final log = <String>[];
      final base = _BaseOpener(log);
      final connector = _Connector(log);
      final chain = JumpChain(
        hops: [_p('outer.example'), _p('inner.example')],
        base: base.call,
        connector: connector.call,
      );

      const t = Duration(seconds: 7);
      await chain.opener('target.example', 22, timeout: t);

      expect(base.timeouts, [t]);
      expect(connector.timeouts, [t, t]);
    });

    test('an EMPTY hop list passes straight through to the base opener', () async {
      final log = <String>[];
      final base = _BaseOpener(log);
      final connector = _Connector(log);
      final chain = JumpChain(
        hops: const <SavedProfile>[],
        base: base.call,
        connector: connector.call,
      );

      final socket = await chain.opener('target.example', 22);

      expect(log, ['dial target.example:22']);
      expect(identical(socket, base.opened.single), isTrue);
      expect(connector.hops, isEmpty);
    });

    test('jumpSocketOpener() is a usable SshSocketOpener for the same chain', () async {
      final log = <String>[];
      final base = _BaseOpener(log);
      final connector = _Connector(log);

      final SshSocketOpener opener = jumpSocketOpener(
        hops: [_p('bastion.example')],
        base: base.call,
        connector: connector.call,
      );
      await opener('target.example', 22);

      expect(log, [
        'dial bastion.example:22',
        'auth bastion.example',
        'forward bastion.example -> target.example:22',
      ]);
    });
  });

  group('A6 — hop errors name the hop (R11)', () {
    test('a hop auth failure throws JumpHopError naming that hop', () async {
      final log = <String>[];
      final base = _BaseOpener(log);
      final connector = _Connector(log, failAt: 1);
      final chain = JumpChain(
        hops: [_p('outer.example'), _p('inner.example')],
        base: base.call,
        connector: connector.call,
      );

      await expectLater(
        chain.opener('target.example', 22),
        throwsA(
          isA<JumpHopError>()
              .having((e) => e.hopLabel, 'hopLabel', contains('inner.example'))
              .having(
                (e) => e.toString(),
                'reads as the HOP refusing, not the target',
                allOf(contains('inner.example'), isNot(contains('target.example'))),
              ),
        ),
      );
    });

    test('a failed OUTER dial names the bastion, not the target', () async {
      final log = <String>[];
      final base = _BaseOpener(log)..error = Exception('connection refused');
      final connector = _Connector(log);
      final chain = JumpChain(
        hops: [_p('bastion.example')],
        base: base.call,
        connector: connector.call,
      );

      await expectLater(
        chain.opener('target.example', 22),
        throwsA(
          isA<JumpHopError>().having(
            (e) => e.toString(),
            'names the bastion',
            contains('bastion.example'),
          ),
        ),
      );
    });

    test('a hop that cannot open the next channel names that hop', () async {
      final log = <String>[];
      final base = _BaseOpener(log);
      final connector = _Connector(log, forwardErrorAt: 0);
      final chain = JumpChain(
        hops: [_p('bastion.example')],
        base: base.call,
        connector: connector.call,
      );

      await expectLater(
        chain.opener('target.example', 22),
        throwsA(
          isA<JumpHopError>().having(
            (e) => e.hopLabel,
            'hopLabel',
            contains('bastion.example'),
          ),
        ),
      );
    });
  });

  group('A7 — chain lifecycle (R12, R13)', () {
    test('close() tears down every live hop', () async {
      final log = <String>[];
      final base = _BaseOpener(log);
      final connector = _Connector(log);
      final chain = JumpChain(
        hops: [_p('outer.example'), _p('inner.example')],
        base: base.call,
        connector: connector.call,
      );
      await chain.opener('target.example', 22);
      expect(chain.liveHops, hasLength(2));

      await chain.close();

      expect(connector.hops.every((h) => h.closedFlag), isTrue);
      expect(chain.liveHops, isEmpty);
    });

    test('destroying the returned socket tears the chain down (R12 ownership)', () async {
      // `SshSessionController.disconnect` closes its client, which closes the
      // transport socket. That socket IS the forwarded channel — the chain must
      // follow it down without any new controller parameter.
      final log = <String>[];
      final base = _BaseOpener(log);
      final connector = _Connector(log);
      final chain = JumpChain(
        hops: [_p('bastion.example')],
        base: base.call,
        connector: connector.call,
      );

      final socket = await chain.opener('target.example', 22);
      socket.destroy();
      await Future<void>.delayed(Duration.zero);

      expect(
        connector.hops.single.closedFlag,
        isTrue,
        reason: 'the jump client must not outlive the session socket it serves',
      );
      expect(chain.liveHops, isEmpty);
    });

    test('a reconnect re-dials the WHOLE chain (R13)', () async {
      final log = <String>[];
      final base = _BaseOpener(log);
      final connector = _Connector(log);
      final chain = JumpChain(
        hops: [_p('bastion.example')],
        base: base.call,
        connector: connector.call,
      );

      await chain.opener('target.example', 22);
      await chain.close();
      await chain.opener('target.example', 22);

      expect(base.opened, hasLength(2), reason: 'a fresh TCP dial per attempt');
      expect(connector.hops, hasLength(2), reason: 'a fresh hop client per attempt');
      expect(chain.liveHops, hasLength(1));
    });

    test('10 reconnects leak no jump clients (R12)', () async {
      final log = <String>[];
      final base = _BaseOpener(log);
      final connector = _Connector(log);
      final chain = JumpChain(
        hops: [_p('outer.example'), _p('inner.example')],
        base: base.call,
        connector: connector.call,
      );

      for (var i = 0; i < 10; i++) {
        await chain.opener('target.example', 22);
        expect(
          chain.liveHops,
          hasLength(2),
          reason: 'attempt $i must hold exactly the chain, never a stack of them',
        );
        await chain.close();
        expect(chain.liveHops, isEmpty);
      }

      expect(connector.hops, hasLength(20));
      expect(
        connector.hops.where((h) => !h.closedFlag),
        isEmpty,
        reason: 'every hop client opened across the storm was closed',
      );
    });

    test('a half-open chain closes the hops it opened and surfaces the error', () async {
      // bastion up, target leg refused. Nothing may be left holding the bastion.
      final log = <String>[];
      final base = _BaseOpener(log);
      final connector = _Connector(log, forwardErrorAt: 0);
      final chain = JumpChain(
        hops: [_p('bastion.example')],
        base: base.call,
        connector: connector.call,
      );

      await expectLater(
        chain.opener('target.example', 22),
        throwsA(isA<JumpHopError>()),
      );

      expect(chain.liveHops, isEmpty);
      expect(connector.hops.single.closedFlag, isTrue);
    });

    test('a half-open chain never presents the session as connected (R13)', () async {
      final log = <String>[];
      final base = _BaseOpener(log);
      final connector = _Connector(log, forwardErrorAt: 0);
      final chain = JumpChain(
        hops: [_p('bastion.example')],
        base: base.call,
        connector: connector.call,
      );
      final controller = SshSessionController(socketOpener: chain.opener);
      addTearDown(controller.dispose);

      await controller.connect(
        const SshConnectParams(
          host: 'target.example',
          port: 22,
          username: 'me',
          auth: SshAuth.password('x'),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(controller.data.state, SshSessionState.failed);
      expect(controller.data.error, contains('bastion.example'));
      expect(chain.liveHops, isEmpty);
    });
  });
}
