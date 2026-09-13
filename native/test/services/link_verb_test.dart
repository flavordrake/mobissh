// #1149 (PR E of #1117) — the `tmux=<name>` verb (R22).
//
// The command line is composed from a CONSTANT template and the token the
// parser already validated (R6). The raw link value is never interpolated:
// anything outside the grammar is rejected at parse time and can never reach
// a [LinkVerbCommand]; the typed command is the ONLY thing the runner accepts.

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/connect_intent.dart';
import 'package:mobissh/services/link_verb.dart';

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
}
