// Keybar → compose-bar routing contract (#1131).
//
// Owner report: with the IME preview open, tapping `/` sent the character to
// the remote shell instead of the compose buffer, splitting input across two
// destinations mid-compose. Rule: while the compose bar is visible, CHARACTER
// keys insert into its buffer; navigation and control keys keep going to the
// terminal.
//
// Tested through the PURE [resolveKeybarRoute] — the keybar widget's tap path
// hangs the headless harness on Material ripple (same reason ctrlTransform is
// a free function; see keybar_ctrl_modifier_test.dart).

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ui/keybar.dart';

KeybarKey _key(String id) =>
    kDefaultKeybarKeys.firstWhere((k) => k.id == id);

KeybarRoute _route(
  String id, {
  bool composeOpen = true,
  bool composeHasText = false,
  bool ctrlArmed = false,
}) =>
    resolveKeybarRoute(
      key: _key(id),
      composeOpen: composeOpen,
      composeHasText: composeHasText,
      ctrlArmed: ctrlArmed,
    );

void main() {
  group('compose bar OPEN — character keys land in the buffer', () {
    test('the reported case: / inserts, never reaches the terminal', () {
      expect(_route('keySlash'), KeybarRoute.composeInsert);
    });

    test('- and | insert too', () {
      expect(_route('keyDash'), KeybarRoute.composeInsert);
      expect(_route('keyPipe'), KeybarRoute.composeInsert);
    });

    test('exactly three keys are classified as characters today', () {
      expect(
        kDefaultKeybarKeys.where((k) => k.isCharacter).map((k) => k.id).toSet(),
        {'keySlash', 'keyDash', 'keyPipe'},
        reason: 'adding a printable key must be a deliberate isCharacter flag',
      );
    });
  });

  group('compose bar OPEN — navigation and control keys stay terminal-bound',
      () {
    for (final id in [
      'keyLeft',
      'keyRight',
      'keyUp',
      'keyDown',
      'keyHome',
      'keyEnd',
      'keyPgUp',
      'keyPgDn',
    ]) {
      test('$id goes to the terminal', () {
        expect(_route(id), KeybarRoute.terminal);
      });
    }

    for (final id in ['keyEsc', 'keyCtrlC', 'keyCtrlZ', 'keyCtrlB', 'keyCtrlD']) {
      test('$id goes to the terminal', () {
        expect(_route(id), KeybarRoute.terminal);
      });
    }

    test('Tab stays terminal-bound (shell completion, not staged text)', () {
      expect(_route('keyTab'), KeybarRoute.terminal);
    });
  });

  group('Enter (owner: acts on the preview)', () {
    test('with staged text it SUBMITS the compose buffer', () {
      expect(_route('keyEnter', composeHasText: true),
          KeybarRoute.composeSubmit);
    });

    test('with an EMPTY buffer it degrades to a bare CR to the terminal', () {
      expect(_route('keyEnter', composeHasText: false), KeybarRoute.terminal,
          reason: 'a plain Enter keystroke must never change meaning');
    });
  });

  group('armed Ctrl outranks compose routing', () {
    test('Ctrl+/ sends the control byte to the terminal, not into the buffer',
        () {
      expect(_route('keySlash', ctrlArmed: true), KeybarRoute.terminal);
    });

    test('armed Ctrl + Enter with staged text still goes to the terminal', () {
      expect(_route('keyEnter', composeHasText: true, ctrlArmed: true),
          KeybarRoute.terminal);
    });
  });

  group('compose bar CLOSED — historical behaviour is untouched', () {
    for (final id in ['keySlash', 'keyDash', 'keyPipe', 'keyEnter', 'keyLeft']) {
      test('$id goes to the terminal', () {
        expect(_route(id, composeOpen: false, composeHasText: true),
            KeybarRoute.terminal);
      });
    }
  });
}
