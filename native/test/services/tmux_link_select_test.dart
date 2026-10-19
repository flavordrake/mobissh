// #1242 S1 — find OUR tmux client over the session's own connection, then
// switch it to a link's session/window/pane (`window=@N`, `pane=%N`).
//
// Pure Dart: the exec channel is a fake that records every line and replies
// from a script, so the tests pin the exact command lines (constant templates
// + re-validated tokens, single-quoted), their ORDER (verify before any
// change, switch before selects), the AMBIGUOUS fall-back reasons, and that
// the telemetry never carries the tty path or an id.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/tmux_link_select.dart';

const _probeOk = 'V tmux 3.4\nT /dev/pts/3\nC /dev/pts/3 main\nC /dev/pts/9 laptop\n';

class _Exec {
  _Exec(this.replies);
  final Map<String, TmuxExecResult> replies;
  final List<String> lines = [];
  bool probeTimesOut = false;

  Future<TmuxExecResult> call(String line) async {
    lines.add(line);
    if (line == tmuxFindClientExecLine && probeTimesOut) {
      throw TimeoutException('probe');
    }
    return replies[line] ?? (exit: 1, out: '');
  }
}

TmuxExecResult _ok([String out = '']) => (exit: 0, out: out);

void main() {
  group('parseTmuxClientProbe', () {
    test('exactly one of our ptys is a tmux client → matched', () {
      final p = parseTmuxClientProbe(_probeOk);
      expect(p.matched, isTrue);
      expect(p.tty, '/dev/pts/3');
      expect(p.session, 'main');
    });

    test('a session name with spaces survives (rest of the line)', () {
      final p = parseTmuxClientProbe(
          'V tmux 3.2a\nT /dev/pts/3\nC /dev/pts/3 my work\n');
      expect(p.session, 'my work');
    });

    final cases = <String, String>{
      'no-client': 'V tmux 3.4\nT /dev/pts/3\nC /dev/pts/9 laptop\n',
      'no-client ': 'V tmux 3.4\nT /dev/pts/3\n',
      'multi-client':
          'V tmux 3.4\nT /dev/pts/3\nC /dev/pts/3 a\nC /dev/pts/3 b\n',
      'multi-pty':
          'V tmux 3.4\nT /dev/pts/3\nT /dev/pts/4\nC /dev/pts/3 a\n',
      'no-pty': 'V tmux 3.4\nC /dev/pts/3 a\n',
      'old-tmux': 'V tmux 3.1c\nT /dev/pts/3\nC /dev/pts/3 a\n',
      'old-tmux ': 'V tmux 2.9\nT /dev/pts/3\nC /dev/pts/3 a\n',
      'version-unknown': 'V tmux master\nT /dev/pts/3\nC /dev/pts/3 a\n',
      'no-tmux': 'X notmux\n',
      'no-proc': 'X noproc\n',
      'no-sshd': 'X nosshd\n',
      'no-reply': '',
    };
    cases.forEach((reason, out) {
      test('ambiguous: $reason', () {
        final p = parseTmuxClientProbe(out);
        expect(p.matched, isFalse);
        expect(p.reason, reason.trim());
      });
    });

    test('3.2 and a next-3.5 build clear the floor; duplicate T lines are '
        'one pty', () {
      expect(
          parseTmuxClientProbe('V tmux 3.2\nT /dev/pts/3\nC /dev/pts/3 a\n')
              .matched,
          isTrue);
      expect(
          parseTmuxClientProbe(
                  'V tmux next-3.5\nT /dev/pts/3\nT /dev/pts/3\nC /dev/pts/3 a\n')
              .matched,
          isTrue);
    });

    test('a tty outside /dev/pts/N never matches (token is re-validated)', () {
      final p = parseTmuxClientProbe(
          "V tmux 3.4\nT /dev/pts/3';x\nC /dev/pts/3';x a\n");
      expect(p.matched, isFalse);
    });
  });

  group('TmuxLinkTarget', () {
    test('refuses tokens outside the grammar', () {
      expect(() => TmuxLinkTarget('a:b'), throwsArgumentError);
      expect(() => TmuxLinkTarget('main', window: "@3';x"),
          throwsArgumentError);
      expect(() => TmuxLinkTarget('main', pane: '@3'), throwsArgumentError);
      expect(() => TmuxLinkTarget('main', pane: '%1.2'), throwsArgumentError);
    });
  });

  group('runTmuxLinkSelect — live session', () {
    late List<String> log;
    setUp(() => log = []);

    Future<TmuxLinkOutcome> run(_Exec exec, TmuxLinkTarget t,
            {bool live = true}) =>
        runTmuxLinkSelect(target: t, live: live, exec: exec.call, log: log.add);

    test('matched on another session: verify, switch, window, pane — in '
        'order, nothing else', () async {
      final exec = _Exec({
        tmuxFindClientExecLine: _ok(_probeOk),
        "tmux display -p -t '@3' '#{session_name}'": _ok('work\n'),
        "tmux display -p -t '%12' '#{session_name} #{window_id}'":
            _ok('work @3\n'),
        "tmux switch-client -c '/dev/pts/3' -t '=work'": _ok(),
        "tmux select-window -t '@3'": _ok(),
        "tmux select-pane -t '%12'": _ok(),
      });
      final out = await run(
          exec, TmuxLinkTarget('work', window: '@3', pane: '%12'));
      expect(out, TmuxLinkOutcome.selected);
      expect(exec.lines, [
        tmuxFindClientExecLine,
        "tmux display -p -t '@3' '#{session_name}'",
        "tmux display -p -t '%12' '#{session_name} #{window_id}'",
        "tmux switch-client -c '/dev/pts/3' -t '=work'",
        "tmux select-window -t '@3'",
        "tmux select-pane -t '%12'",
      ]);
    });

    test('already on the link session → no switch-client', () async {
      final exec = _Exec({
        tmuxFindClientExecLine: _ok(_probeOk),
        "tmux display -p -t '@3' '#{session_name}'": _ok('main\n'),
        "tmux select-window -t '@3'": _ok(),
      });
      final out = await run(exec, TmuxLinkTarget('main', window: '@3'));
      expect(out, TmuxLinkOutcome.selected);
      expect(exec.lines.any((l) => l.contains('switch-client')), isFalse);
    });

    test('named window + pane verifies the window NAME', () async {
      final exec = _Exec({
        tmuxFindClientExecLine: _ok(_probeOk),
        "tmux display -p -t '=main:=beta' '#{session_name}'": _ok('main\n'),
        "tmux display -p -t '%4' '#{session_name} #{window_name}'":
            _ok('main beta\n'),
        "tmux select-window -t '=main:=beta'": _ok(),
        "tmux select-pane -t '%4'": _ok(),
      });
      expect(
          await run(exec,
              TmuxLinkTarget('main', window: 'beta', pane: '%4')),
          TmuxLinkOutcome.selected);
    });

    test('pane alone also selects the pane\'s window', () async {
      final exec = _Exec({
        tmuxFindClientExecLine: _ok(_probeOk),
        "tmux display -p -t '%4' '#{session_name}'": _ok('main\n'),
        "tmux select-window -t '%4'": _ok(),
        "tmux select-pane -t '%4'": _ok(),
      });
      expect(await run(exec, TmuxLinkTarget('main', pane: '%4')),
          TmuxLinkOutcome.selected);
      expect(exec.lines.takeLast(2), [
        "tmux select-window -t '%4'",
        "tmux select-pane -t '%4'",
      ]);
    });

    test('window id belongs to ANOTHER session → notFound, nothing changed',
        () async {
      final exec = _Exec({
        tmuxFindClientExecLine: _ok(_probeOk),
        "tmux display -p -t '@3' '#{session_name}'": _ok('other\n'),
      });
      expect(await run(exec, TmuxLinkTarget('work', window: '@3')),
          TmuxLinkOutcome.notFound);
      expect(exec.lines, [
        tmuxFindClientExecLine,
        "tmux display -p -t '@3' '#{session_name}'",
      ]);
    });

    test('pane belongs to another session → notFound, nothing changed',
        () async {
      final exec = _Exec({
        tmuxFindClientExecLine: _ok(_probeOk),
        "tmux display -p -t '%12' '#{session_name}'": _ok('other\n'),
      });
      expect(await run(exec, TmuxLinkTarget('work', pane: '%12')),
          TmuxLinkOutcome.notFound);
      expect(exec.lines.any((l) => l.contains('select-')), isFalse);
      expect(exec.lines.any((l) => l.contains('switch-client')), isFalse);
    });

    test('pane is in a different window than @N → notFound', () async {
      final exec = _Exec({
        tmuxFindClientExecLine: _ok(_probeOk),
        "tmux display -p -t '@3' '#{session_name}'": _ok('main\n'),
        "tmux display -p -t '%12' '#{session_name} #{window_id}'":
            _ok('main @4\n'),
      });
      expect(
          await run(exec,
              TmuxLinkTarget('main', window: '@3', pane: '%12')),
          TmuxLinkOutcome.notFound);
      expect(exec.lines.any((l) => l.contains('select-')), isFalse);
    });

    test('stale id (tmux exits non-zero) → notFound', () async {
      final exec = _Exec({tmuxFindClientExecLine: _ok(_probeOk)});
      expect(await run(exec, TmuxLinkTarget('main', window: '@99')),
          TmuxLinkOutcome.notFound);
    });

    test('a failing switch-client → notFound', () async {
      final exec = _Exec({
        tmuxFindClientExecLine: _ok(_probeOk),
        "tmux display -p -t '@3' '#{session_name}'": _ok('work\n'),
      });
      expect(await run(exec, TmuxLinkTarget('work', window: '@3')),
          TmuxLinkOutcome.notFound);
      expect(exec.lines.last, startsWith('tmux switch-client'));
    });
  });

  group('runTmuxLinkSelect — AMBIGUOUS leaves everything untouched', () {
    final probes = <String, String>{
      'zero clients of ours': 'V tmux 3.4\nT /dev/pts/3\nC /dev/pts/9 x\n',
      'two clients': 'V tmux 3.4\nT /dev/pts/3\nC /dev/pts/3 a\nC /dev/pts/3 b\n',
      'no tmux': 'X notmux\n',
      'old tmux': 'V tmux 3.1c\nT /dev/pts/3\nC /dev/pts/3 a\n',
      'non-linux': 'X noproc\n',
      'empty reply': '',
    };
    probes.forEach((name, out) {
      test(name, () async {
        final log = <String>[];
        final exec = _Exec({tmuxFindClientExecLine: _ok(out)});
        final r = await runTmuxLinkSelect(
            target: TmuxLinkTarget('main', window: '@3'),
            live: true,
            exec: exec.call,
            log: log.add);
        expect(r, TmuxLinkOutcome.ambiguous);
        expect(exec.lines, [tmuxFindClientExecLine],
            reason: 'nothing past the probe may run');
        expect(log.single, startsWith('tmux link probe: ambiguous reason='));
      });
    });

    test('probe exits non-zero → ambiguous', () async {
      final exec = _Exec({tmuxFindClientExecLine: (exit: 127, out: '')});
      final r = await runTmuxLinkSelect(
          target: TmuxLinkTarget('main', window: '@3'),
          live: true,
          exec: exec.call,
          log: (_) {});
      expect(r, TmuxLinkOutcome.ambiguous);
    });

    test('no reply within the deadline → ambiguous (timeout)', () async {
      final log = <String>[];
      final exec = _Exec({})..probeTimesOut = true;
      final r = await runTmuxLinkSelect(
          target: TmuxLinkTarget('main', window: '@3'),
          live: true,
          exec: exec.call,
          log: log.add);
      expect(r, TmuxLinkOutcome.ambiguous);
      expect(log.single, contains('reason=timeout'));
    });
  });

  group('runTmuxLinkSelect — attached (fresh connect / known attach)', () {
    test('no probe, no switch: verified selects only', () async {
      final exec = _Exec({
        "tmux display -p -t '@3' '#{session_name}'": _ok('main\n'),
        "tmux display -p -t '%12' '#{session_name} #{window_id}'":
            _ok('main @3\n'),
        "tmux select-window -t '@3'": _ok(),
        "tmux select-pane -t '%12'": _ok(),
      });
      final r = await runTmuxLinkSelect(
          target: TmuxLinkTarget('main', window: '@3', pane: '%12'),
          live: false,
          exec: exec.call,
          log: (_) {});
      expect(r, TmuxLinkOutcome.selected);
      expect(exec.lines, hasLength(4));
      expect(exec.lines.first, startsWith('tmux display'));
    });
  });

  group('telemetry', () {
    test('one line per stage; never the tty, an id or a name', () async {
      final log = <String>[];
      final exec = _Exec({
        tmuxFindClientExecLine: _ok(_probeOk),
        "tmux display -p -t '@3' '#{session_name}'": _ok('work\n'),
        "tmux display -p -t '%12' '#{session_name} #{window_id}'":
            _ok('work @3\n'),
        "tmux switch-client -c '/dev/pts/3' -t '=work'": _ok(),
        "tmux select-window -t '@3'": _ok(),
        "tmux select-pane -t '%12'": _ok(),
      });
      await runTmuxLinkSelect(
          target: TmuxLinkTarget('work', window: '@3', pane: '%12'),
          live: true,
          exec: exec.call,
          log: log.add);
      expect(log, [
        'tmux link probe: matched',
        'tmux link verify: ok',
      ]);
      final all = log.join('\n');
      for (final secret in ['/dev/pts', 'pts/3', '@3', '%12', 'work']) {
        expect(all, isNot(contains(secret)));
      }
    });

    test('a mismatch logs the verify outcome', () async {
      final log = <String>[];
      final exec = _Exec({
        tmuxFindClientExecLine: _ok(_probeOk),
        "tmux display -p -t '@3' '#{session_name}'": _ok('other\n'),
      });
      await runTmuxLinkSelect(
          target: TmuxLinkTarget('work', window: '@3'),
          live: true,
          exec: exec.call,
          log: log.add);
      expect(log, ['tmux link probe: matched', 'tmux link verify: mismatch']);
    });
  });
}

extension on List<String> {
  List<String> takeLast(int n) => sublist(length - n);
}
