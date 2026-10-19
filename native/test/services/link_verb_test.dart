// #1149 (PR E of #1117) — the `tmux=<name>` verb (R22).
//
// The command line is composed from a CONSTANT template and the token the
// parser already validated (R6). The raw link value is never interpolated:
// anything outside the grammar is rejected at parse time and can never reach
// a [LinkVerbCommand]; the typed command is the ONLY thing the runner accepts.

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/connect_intent.dart';
import 'package:mobissh/services/link_verb.dart';
import 'package:mobissh/services/tmux_link_select.dart';

const _base = 'mobissh://connect?host=box.example';

void main() {
  group('R22 rejected at parse — never reaches a command', () {
    for (final raw in ['-foo', 'a%20b', '%24%28x%29', 'a;b']) {
      test('tmux=$raw is rejected as a bad tmux parameter', () {
        final r = parseConnectIntent('$_base&tmux=$raw');
        expect(r, isA<ConnectIntentRejected>());
        expect((r as ConnectIntentRejected).key, 'tmux');
      });
    }

    test('an encoded newline is rejected (R2 malformed, before any rule)', () {
      expect(parseConnectIntent('$_base&tmux=a%0Ab'),
          isA<ConnectIntentRejected>());
    });

    test('TmuxAttach refuses a token outside the grammar', () {
      expect(() => TmuxAttach('-foo'), throwsArgumentError);
      expect(() => TmuxAttach('a b'), throwsArgumentError);
      expect(() => TmuxAttach(r'$(x)'), throwsArgumentError);
    });
  });

  group('R22 byte-exact command line', () {
    for (final name in ['main', 'dev-1', '_x', 'a' * 31]) {
      test('tmux=$name → tmux new-session -A -s $name', () {
        final r = parseConnectIntent('$_base&tmux=$name');
        final verb = LinkVerbCommand.fromRequest(
          (r as ConnectIntentParsed).request,
        );
        expect(verb, isA<TmuxAttach>());
        expect(verb!.commandLine, 'tmux new-session -A -s $name');
      });
    }

    test('no tmux parameter → no verb', () {
      final r = parseConnectIntent(_base) as ConnectIntentParsed;
      expect(LinkVerbCommand.fromRequest(r.request), isNull);
    });
  });

  // #1211: `window=<name>` rides the tmux verb, same allowlist as R6.
  group('#1211 window= grammar', () {
    for (final name in ['beta', 'mobiharness', 'w-1', '_x', 'a' * 32]) {
      test('tmux=main&window=$name parses and reaches the verb', () {
        final r = parseConnectIntent('$_base&tmux=main&window=$name');
        expect(r, isA<ConnectIntentParsed>());
        final req = (r as ConnectIntentParsed).request;
        expect(req.window, name);
        final verb = LinkVerbCommand.fromRequest(req) as TmuxAttach;
        expect(verb.window, name);
        // The attach line is unchanged by window= (R22 stays byte-exact).
        expect(verb.commandLine, 'tmux new-session -A -s main');
      });
    }

    for (final raw in [
      'main%3Abeta', // `:` would re-target the session
      'a%20b', // space
      'a;b',
      '%24%28x%29', // $(x)
      'a%27b', // single quote
      '-beta', // leading hyphen
      '', // empty
      'a' * 33,
      'a.b',
    ]) {
      test('window=$raw is rejected as a bad window parameter', () {
        final r = parseConnectIntent('$_base&tmux=main&window=$raw');
        expect(r, isA<ConnectIntentRejected>());
        expect((r as ConnectIntentRejected).key, 'window');
      });
    }

    test('window= without tmux= is rejected (nothing to select in)', () {
      final r = parseConnectIntent('$_base&window=beta');
      expect(r, isA<ConnectIntentRejected>());
      expect((r as ConnectIntentRejected).key, 'window');
    });

    test('window= on create is rejected', () {
      final r = parseConnectIntent(
          'mobissh://create?host=box.example&window=beta');
      expect(r, isA<ConnectIntentRejected>());
      expect((r as ConnectIntentRejected).key, 'window');
    });

    test('unknown params are still ignored next to window= (R7)', () {
      final r = parseConnectIntent(
          '$_base&tmux=main&window=beta&foo=bar') as ConnectIntentParsed;
      expect(r.request.tmux, 'main');
      expect(r.request.window, 'beta');
    });

    test('no window= → verb carries no window (behaviour unchanged)', () {
      final r =
          parseConnectIntent('$_base&tmux=main') as ConnectIntentParsed;
      final verb = LinkVerbCommand.fromRequest(r.request) as TmuxAttach;
      expect(verb.window, isNull);
    });

    test('TmuxAttach refuses a window outside the grammar', () {
      expect(() => TmuxAttach('main', window: 'a:b'), throwsArgumentError);
      expect(() => TmuxAttach('main', window: "a'b"), throwsArgumentError);
      expect(() => TmuxAttach('main', window: ''), throwsArgumentError);
    });

    test('the exec line is exact-match, single-quoted, from validated tokens',
        () {
      expect(tmuxSelectWindowExecLine('main', 'beta'),
          "tmux select-window -t '=main:=beta'");
      expect(() => tmuxSelectWindowExecLine('main', "x';rm -rf ~;'"),
          throwsArgumentError);
      expect(() => tmuxSelectWindowExecLine('a:b', 'beta'),
          throwsArgumentError);
    });
  });

  // #1242 S1: `window` also takes a tmux window id (@N) and `pane` a pane id
  // (%N). `%` is percent-encoded in a link (`%25`): a raw `%12` decodes to a
  // control character and rejects as malformed (R2).
  group('#1242 window=@N and pane=%N grammar', () {
    const tm = '$_base&tmux=main';

    for (final w in ['@0', '@3', '@123456789']) {
      test('window=$w parses', () {
        final req = (parseConnectIntent('$tm&window=$w')
            as ConnectIntentParsed).request;
        expect(req.window, w);
      });
    }
    for (final p in ['%250', '%2512', '%25123456789']) {
      test('pane=$p parses and reaches the verb', () {
        final req = (parseConnectIntent('$tm&pane=$p')
            as ConnectIntentParsed).request;
        expect(req.pane, Uri.decodeComponent(p));
        final verb = LinkVerbCommand.fromRequest(req) as TmuxAttach;
        expect(verb.pane, req.pane);
        expect(verb.commandLine, 'tmux new-session -A -s main');
      });
    }
    test('the target link: window=@3 and pane=%12 together', () {
      final req = (parseConnectIntent('$tm&window=@3&pane=%2512')
          as ConnectIntentParsed).request;
      expect((req.window, req.pane), ('@3', '%12'));
    });

    for (final w in ['@', '@x', '@1%3A2', '@1.2', '@1234567890', '@-1', '@%2D1']) {
      test('window=$w is rejected', () {
        final r = parseConnectIntent('$tm&window=$w');
        expect(r, isA<ConnectIntentRejected>());
        expect((r as ConnectIntentRejected).key, 'window');
      });
    }
    for (final p in [
      '%25', // `%`
      '@3', // a window id is not a pane id
      '%25x',
      '%25-1',
      '%251.2',
      '%251%3A2',
      '%25%25',
      '1',
      '%251234567890',
    ]) {
      test('pane=$p is rejected', () {
        final r = parseConnectIntent('$tm&pane=$p');
        expect(r, isA<ConnectIntentRejected>());
        expect((r as ConnectIntentRejected).key, 'pane');
      });
    }
    test('pane without tmux is rejected', () {
      final r = parseConnectIntent('$_base&pane=%2512');
      expect((r as ConnectIntentRejected).key, 'pane');
    });
    test('pane on create is rejected', () {
      final r = parseConnectIntent('mobissh://create?host=box.example&pane=%2512');
      expect((r as ConnectIntentRejected).key, 'pane');
    });
    test('TmuxAttach refuses an id outside the grammar', () {
      expect(() => TmuxAttach('main', window: '@x'), throwsArgumentError);
      expect(() => TmuxAttach('main', pane: '@3'), throwsArgumentError);
      expect(() => TmuxAttach('main', pane: "%1'"), throwsArgumentError);
      expect(TmuxAttach('main', window: '@3', pane: '%12').pane, '%12');
    });
  });

  group('#1211 selectLinkWindow notice', () {
    test('a match selects and shows nothing', () async {
      final calls = <String>[];
      final notices = <String>[];
      final ok = await selectLinkWindow(
        TmuxAttach('main', window: 'beta'),
        run: (s, w) async {
          calls.add('$s:$w');
          return true;
        },
        notify: notices.add,
      );
      expect(ok, isTrue);
      expect(calls, ['main:beta']);
      expect(notices, isEmpty);
    });

    test('no match → one neutral notice naming the window', () async {
      final notices = <String>[];
      final ok = await selectLinkWindow(
        TmuxAttach('main', window: 'nope'),
        run: (s, w) async => false,
        notify: notices.add,
      );
      expect(ok, isFalse);
      expect(notices, ['No window "nope" in tmux session main']);
    });

    test('a verb without window runs nothing', () async {
      var ran = false;
      final ok = await selectLinkWindow(
        TmuxAttach('main'),
        run: (s, w) async => ran = true,
        notify: (_) => fail('no notice expected'),
      );
      expect(ok, isFalse);
      expect(ran, isFalse);
    });
  });

  group('#1242 selectLinkTarget notice', () {
    Future<(TmuxLinkOutcome, List<String>)> go(
        TmuxAttach verb, TmuxLinkOutcome outcome) async {
      final notices = <String>[];
      final r = await selectLinkTarget(verb,
          run: (_) async => outcome, notify: notices.add);
      return (r, notices);
    }

    test('selected and ambiguous show nothing', () async {
      final verb = TmuxAttach('main', window: '@3', pane: '%12');
      expect((await go(verb, TmuxLinkOutcome.selected)).$2, isEmpty);
      final amb = await go(verb, TmuxLinkOutcome.ambiguous);
      expect(amb.$1, TmuxLinkOutcome.ambiguous);
      expect(amb.$2, isEmpty);
    });

    test('notFound → one neutral notice, extended for panes', () async {
      expect((await go(TmuxAttach('main', window: '@3'),
              TmuxLinkOutcome.notFound)).$2,
          ['No window "@3" in tmux session main']);
      expect((await go(TmuxAttach('main', pane: '%12'),
              TmuxLinkOutcome.notFound)).$2,
          ['No pane "%12" in tmux session main']);
      expect((await go(TmuxAttach('main', window: '@3', pane: '%12'),
              TmuxLinkOutcome.notFound)).$2,
          ['No pane "%12" in window "@3" of tmux session main']);
    });
  });
}
