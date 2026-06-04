// Tests for keybar height reduction (#752).
//
// The keybar was too TALL — it ate terminal real estate. #752 collapses the
// VERTICAL dead space around the glyphs (outer scroll-view padding, per-key
// vertical padding, and the key min-height floor) WITHOUT shrinking the
// font / label / icon sizes (#696/#703). The keys stay just as readable; only
// the spacing shrinks.
//
// These tests pin the contract: the label fontSize / icon size are UNCHANGED
// from #703 (14 / 18), while the height-driving constants are SMALLER than the
// old (pre-#752) values. The widget still renders every key, and the
// auto-repeat (#732) + Ctrl (#694/#728) wiring is intact.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/state/ctrl_modifier_provider.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/ui/keybar.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Old (pre-#752) height contract, captured here so the test documents exactly
// what shrank. Font/icon sizes are NOT in this list — they must NOT change.
const double _kOldButtonMinHeight = 44; // was the 44px floor
const double _kOldReserve = 56; // was button + 3px scroll pad, rounded up

Future<void> _pumpFrames(WidgetTester tester, {int count = 8}) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('#752 keybar height reduction — font/icon UNCHANGED', () {
    test('label fontSize is unchanged from #703 (still 14)', () {
      // #752 must NOT shrink the text — only the spacing around it. The label
      // and ESC font sizes stay at the #703 uniform 14.
      expect(kKeybarLabelFontSize, equals(14));
      expect(kKeybarEscFontSize, equals(14));
      expect(
        kKeybarLabelFontSize,
        equals(kKeybarEscFontSize),
        reason: 'all text keys still share the one uniform (#703) size',
      );
    });

    test('icon size is unchanged from #703 (still 18)', () {
      // Glyphs (arrows, Enter, Paste) must stay just as legible — only the
      // vertical dead space shrinks, never the icon.
      expect(kKeybarIconSize, equals(18));
      // The icon stays larger than the (unchanged) text.
      expect(kKeybarIconSize, greaterThan(kKeybarLabelFontSize));
    });
  });

  group('#752 keybar height reduction — spacing/height SHRANK', () {
    test('button min-height collapsed below the old 44px floor', () {
      // The 44px floor forced ~26px of dead vertical space around an ~18px
      // label. #752 collapses it so the key hugs its (unchanged) label.
      expect(
        kKeybarButtonMinHeight,
        lessThan(_kOldButtonMinHeight),
        reason: '#752: the key must hug its label, not the old 44px floor',
      );
      // …but still a usable, tappable touch height (label ~18px + margin).
      expect(
        kKeybarButtonMinHeight,
        greaterThanOrEqualTo(kKeybarLabelFontSize),
        reason: 'the key must still clear its own (unchanged) label height',
      );
      expect(
        kKeybarButtonMinHeight,
        greaterThanOrEqualTo(28),
        reason: 'still a reasonable touch height — keys stay tappable',
      );
    });

    test('compose-bar reserve shrank with the bar', () {
      // The reserve tracks the bar height; it must shrink too, but still cover
      // the (new) button height plus the scroll-view vertical padding.
      expect(
        kKeybarReserve,
        lessThan(_kOldReserve),
        reason: '#752: the bar is shorter, so its reserve shrinks too',
      );
      expect(
        kKeybarReserve,
        greaterThanOrEqualTo(kKeybarButtonMinHeight),
        reason: 'the reserve must still clear the (new) button height',
      );
    });

    test('horizontal touch width is preserved (tappable)', () {
      // #752 is a VERTICAL reduction only — the horizontal min widths must NOT
      // shrink (keys stay comfortably tappable).
      expect(kKeybarButtonMinWidth, greaterThanOrEqualTo(44));
      expect(kKeybarSingleCharMinWidth, greaterThanOrEqualTo(28));
    });
  });

  group('#752 widget still renders all keys + wiring intact', () {
    testWidgets('every default key renders after the height collapse', (
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
          child: MaterialApp(
            home: Scaffold(body: Keybar(activeEntry: entry)),
          ),
        ),
      );
      await _pumpFrames(tester);

      expect(find.byKey(const Key('keybar')), findsOneWidget);
      // Every default key still mounts its button.
      for (final k in kDefaultKeybarKeys) {
        expect(
          find.byKey(Key('keybar-btn-${k.id}')),
          findsOneWidget,
          reason: '${k.id} must still render after the height reduction',
        );
      }
    });

    test('auto-repeat (#732) eligibility wiring is intact', () {
      // The nav keys still auto-repeat; modifiers/symbols still do not.
      for (final id in ['keyLeft', 'keyUp', 'keyDown', 'keyRight', 'keyHome']) {
        expect(isRepeatEligibleKeyId(id), isTrue);
      }
      for (final id in ['keyEsc', 'keyCtrl', 'keyTab', 'keyCtrlC']) {
        expect(isRepeatEligibleKeyId(id), isFalse);
      }
    });

    test('Ctrl modifier (#694/#728) transform wiring is intact', () {
      // The sticky Ctrl key is still a modifier, and the pure transform still
      // maps a letter to its control byte.
      final ctrl = kDefaultKeybarKeys.firstWhere((k) => k.id == 'keyCtrl');
      expect(ctrl.isModifier, isTrue);
      expect(ctrlTransform('c'), equals('\x03'));
      // The shared provider notifier still arms/consumes one-shot.
      final m = CtrlModifier();
      expect(m.armed, isFalse);
      m.arm();
      expect(m.armed, isTrue);
      expect(m.apply('a'), equals('\x01'));
      expect(m.armed, isFalse, reason: 'one-shot: auto-clears after apply');
      // Touch the shared provider type so the import is meaningful.
      expect(ctrlModifierProvider, isNotNull);
    });
  });
}
