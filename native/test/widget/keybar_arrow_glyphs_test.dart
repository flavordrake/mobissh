// Tests for bigger, solid, differentiated keybar arrow/nav glyphs (#823).
//
// Owner device feedback: the arrow/navigation keys were hard to read — thin
// chevrons (Icons.keyboard_arrow_*) that look alike. #823 makes them:
//   - SOLID/FILLED (Icons.arrow_back/upward/downward/forward, not chevrons),
//   - LARGER (a dedicated nav icon size, bigger than the standard icon), and
//   - clearly DIFFERENTIATED (Home/End/PgUp/PgDn get distinct filled glyphs).
//
// Constraints pinned here (do not regress):
//   - The bar HEIGHT must NOT grow: the larger nav icon must still fit within
//     the (unchanged) button min-height, and the height/font constants are
//     untouched (#615/#752/#703).
//   - Byte sequences + #732 auto-repeat eligibility are UNCHANGED (routing is
//     identical — only the glyph rendering changes).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/ui/keybar.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _pumpFrames(WidgetTester tester, {int count = 8}) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

KeybarKey _key(String id) =>
    kDefaultKeybarKeys.firstWhere((k) => k.id == id);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('#823 arrow keys are SOLID/FILLED, not thin chevrons', () {
    test('the four arrows use the filled arrow_* glyphs (not keyboard_arrow_*)', () {
      expect(_key('keyLeft').icon, equals(Icons.arrow_back));
      expect(_key('keyUp').icon, equals(Icons.arrow_upward));
      expect(_key('keyDown').icon, equals(Icons.arrow_downward));
      expect(_key('keyRight').icon, equals(Icons.arrow_forward));
      // The old thin chevrons must be gone.
      for (final id in ['keyLeft', 'keyUp', 'keyDown', 'keyRight']) {
        expect(
          _key(id).icon,
          isNot(
            anyOf(
              Icons.keyboard_arrow_left,
              Icons.keyboard_arrow_up,
              Icons.keyboard_arrow_down,
              Icons.keyboard_arrow_right,
            ),
          ),
          reason: '$id must use a solid/filled arrow, not a thin chevron',
        );
      }
    });

    test('the four arrows are mutually distinct glyphs', () {
      final icons = ['keyLeft', 'keyUp', 'keyDown', 'keyRight']
          .map((id) => _key(id).icon)
          .toSet();
      expect(icons.length, 4, reason: 'each direction must be a distinct glyph');
    });
  });

  group('#823 Home/End/PgUp/PgDn become solid, differentiated icons', () {
    test('each nav key now carries a (filled) icon, not a text label', () {
      for (final id in ['keyHome', 'keyEnd', 'keyPgUp', 'keyPgDn']) {
        expect(
          _key(id).icon,
          isNotNull,
          reason: '$id must render a solid, differentiated icon (#823)',
        );
      }
    });

    test('the nav icons are mutually distinct, and distinct from the arrows', () {
      final ids = [
        'keyLeft',
        'keyUp',
        'keyDown',
        'keyRight',
        'keyHome',
        'keyEnd',
        'keyPgUp',
        'keyPgDn',
      ];
      final icons = ids.map((id) => _key(id).icon).toSet();
      expect(
        icons.length,
        ids.length,
        reason: 'all arrow + nav glyphs must be visually distinct shapes',
      );
    });
  });

  group('#823 nav/arrow glyphs are LARGER (without growing the bar)', () {
    test('a dedicated nav icon size is bigger than the standard icon size', () {
      expect(
        kKeybarNavIconSize,
        greaterThan(kKeybarIconSize),
        reason: 'arrow/nav glyphs must read as MORE prominent than other icons',
      );
    });

    test('the larger nav icon still fits inside the (unchanged) bar height', () {
      // The bigger glyph must NOT grow the bar — it must fit within the
      // existing tap-target min height (#615/#752 deliberately trimmed it).
      expect(
        kKeybarNavIconSize,
        lessThanOrEqualTo(kKeybarButtonMinHeight),
        reason: 'a taller glyph than the bar would grow the bar — forbidden',
      );
    });

    test('the bar height + text/standard-icon constants are UNCHANGED', () {
      expect(kKeybarButtonMinHeight, equals(32));
      expect(kKeybarLabelFontSize, equals(14));
      expect(kKeybarIconSize, equals(18));
      expect(kKeybarReserve, equals(40));
    });

    test('arrow/nav keys carry the larger nav icon size; others stay standard', () {
      for (final id in [
        'keyLeft',
        'keyUp',
        'keyDown',
        'keyRight',
        'keyHome',
        'keyEnd',
        'keyPgUp',
        'keyPgDn',
      ]) {
        expect(
          _key(id).iconSize,
          equals(kKeybarNavIconSize),
          reason: '$id must render at the larger nav icon size',
        );
      }
      // Non-nav icon keys keep the standard size.
      for (final id in ['keyTab', 'keyEnter', 'keyPaste']) {
        expect(
          _key(id).iconSize,
          equals(kKeybarIconSize),
          reason: '$id is not a nav key — it must keep the standard icon size',
        );
      }
    });
  });

  group('#823 routing + auto-repeat UNCHANGED (glyph-only change)', () {
    test('arrow/nav byte sequences are unchanged', () {
      expect(_key('keyLeft').sequence, equals('\x1b[D'));
      expect(_key('keyUp').sequence, equals('\x1b[A'));
      expect(_key('keyDown').sequence, equals('\x1b[B'));
      expect(_key('keyRight').sequence, equals('\x1b[C'));
      expect(_key('keyHome').sequence, equals('\x1b[H'));
      expect(_key('keyEnd').sequence, equals('\x1b[F'));
      expect(_key('keyPgUp').sequence, equals('\x1b[5~'));
      expect(_key('keyPgDn').sequence, equals('\x1b[6~'));
    });

    test('#732 auto-repeat eligibility is unchanged', () {
      for (final id in [
        'keyLeft',
        'keyUp',
        'keyDown',
        'keyRight',
        'keyHome',
        'keyEnd',
        'keyPgUp',
        'keyPgDn',
      ]) {
        expect(isRepeatEligibleKeyId(id), isTrue);
      }
      for (final id in ['keyEsc', 'keyCtrl', 'keyTab', 'keyCtrlC']) {
        expect(isRepeatEligibleKeyId(id), isFalse);
      }
    });
  });

  group('#823 widget renders the larger nav glyphs at the right size', () {
    testWidgets('each arrow/nav Icon paints at kKeybarNavIconSize', (
      tester,
    ) async {
      final pair = InMemoryGatewayPair();
      addTearDown(() async {
        await pair.dispose();
      });
      final container = ProviderContainer(
        overrides: [taskSshGatewayProvider.overrideWithValue(pair.uiSide)],
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
      await _pumpFrames(tester);

      for (final id in [
        'keyLeft',
        'keyUp',
        'keyDown',
        'keyRight',
        'keyHome',
        'keyEnd',
        'keyPgUp',
        'keyPgDn',
      ]) {
        final icon = tester.widget<Icon>(
          find.descendant(
            of: find.byKey(Key('keybar-btn-$id')),
            matching: find.byType(Icon),
          ),
        );
        expect(
          icon.size,
          equals(kKeybarNavIconSize),
          reason: '$id must paint its glyph at the larger nav size',
        );
      }
    });
  });
}
