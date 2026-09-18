// Slim session menu (#567) + non-modal-overlay regression guard (#585).
//
// #567 (owner's stated #2 priority, re-raised 2026-05-31): the session menu's
// secondary section had regrown into a stack of full-width ListTiles (keybar,
// theme, font, files, disconnect) plus a verbose user@host:port subtitle on
// every session row. This tightens it back to the PWA's slim direction:
//   - session rows show the LABEL only (no user@host:port subtitle clutter),
//   - the per-session controls collapse into ONE compact icon-button row
//     (`session-menu-controls`) instead of five stacked tiles,
//   - every ESSENTIAL control is KEPT and addressable by its existing key:
//     theme picker, font -, font +, font-family picker, keybar toggle,
//     disconnect (#724 swapped theme/font cycles for pickers + dropped the
//     font-size number; the control keys are unchanged).
//
// #585: the menu must remain a NON-MODAL overlay that never steals focus from
// the terminal's editable (otherwise the soft keyboard drops + the screen
// reflows). The structural fix already shipped (commit 4832544); this guards it
// against the slim rework.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/state/detection_providers.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/state/ui_prefs_providers.dart';
import 'package:mobissh/ui/detection_lab_screen.dart';
import 'package:mobissh/ui/session_menu.dart';
import 'package:shared_preferences/shared_preferences.dart';

ProviderContainer _makeContainer() {
  final pair = InMemoryGatewayPair();
  final container = ProviderContainer(
    overrides: [taskSshGatewayProvider.overrideWithValue(pair.uiSide)],
  );
  addTearDown(() async {
    await pair.dispose();
  });
  addTearDown(container.dispose);
  return container;
}

SessionEntry _add(ProviderContainer c, String host) {
  return c
      .read(sessionsProvider.notifier)
      .addOrActivate(
        SshConnectParams(
          host: host,
          port: 22,
          username: 'u',
          auth: const SshAuth.password('p'),
        ),
      );
}

Widget _host({required ProviderContainer container}) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: ElevatedButton(
              key: const Key('open-menu'),
              onPressed: () => showSessionMenu(ctx),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
}

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

  group('SessionMenu slim layout (#567)', () {
    testWidgets('keeps every essential control, addressable by key', (
      tester,
    ) async {
      final container = _makeContainer();
      final session = _add(container, 'host-a');

      await tester.pumpWidget(_host(container: container));
      await tester.tap(find.byKey(const Key('open-menu')));
      await _pumpFrames(tester);

      // Switch (the session row) + new session.
      expect(find.byKey(const Key('session-menu-new')), findsOneWidget);
      // Per-session controls — KEPT (owner: don't drop these).
      expect(find.byKey(const Key('session-menu-theme-cycle')), findsOneWidget);
      expect(
        find.byKey(const Key('session-menu-fontsize-dec')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('session-menu-fontsize-inc')),
        findsOneWidget,
      );
      // Files moved to a PER-ROW icon (#649): each session row carries its own
      // `session-menu-files-${id}` next to its X, instead of one active-only
      // control in the secondary row.
      expect(
        find.byKey(Key('session-menu-files-${session.id}')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('session-menu-keybar-toggle')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('terminal-disconnect-button')),
        findsOneWidget,
      );
    });

    testWidgets('per-session controls collapse into one compact row', (
      tester,
    ) async {
      final container = _makeContainer();
      _add(container, 'host-a');

      await tester.pumpWidget(_host(container: container));
      await tester.tap(find.byKey(const Key('open-menu')));
      await _pumpFrames(tester);

      // The slim layout exposes a single controls row rather than five stacked
      // full-width tiles. This is the structural slim assertion.
      expect(find.byKey(const Key('session-menu-controls')), findsOneWidget);

      // Clutter removed: the old stacked secondary tiles must NOT appear as
      // full ListTiles (they are now compact icon-buttons inside the row).
      expect(find.widgetWithText(ListTile, 'Keybar'), findsNothing);
      expect(find.widgetWithText(ListTile, 'Font size'), findsNothing);
      expect(find.widgetWithText(ListTile, 'Theme'), findsNothing);
    });

    testWidgets('session rows drop the user@host:port subtitle clutter', (
      tester,
    ) async {
      final container = _makeContainer();
      // Give the session an explicit title so the LABEL ('Prod box') differs
      // from the user@host:port string — then the only place 'u@host-a:22'
      // could render is the (now-removed) subtitle line.
      container
          .read(sessionsProvider.notifier)
          .addOrActivate(
            const SshConnectParams(
              host: 'host-a',
              port: 22,
              username: 'u',
              auth: SshAuth.password('p'),
            ),
            title: 'Prod box',
          );

      await tester.pumpWidget(_host(container: container));
      await tester.tap(find.byKey(const Key('open-menu')));
      await _pumpFrames(tester);

      // Label still shows; the verbose subtitle line is gone.
      expect(find.text('Prod box'), findsOneWidget);
      expect(find.text('u@host-a:22'), findsNothing);
    });

    // #1154 (Slice 1 of #1153, owner directive 2026-09-16): the detection
    // button is no longer a one-tap toggle. Tapping it closes the session menu
    // (the #664 idiom — the menu barrier sits above pushed routes) and opens
    // the link-highlight OPTIONS sheet; the sheet's controls LIVE-apply through
    // DetectionSettingsNotifier. This replaces the former "tap flips enabled"
    // test (R1).
    group('#1154 link highlight options sheet', () {
      Future<void> openSheet(WidgetTester tester) async {
        await tester.tap(find.byKey(const Key('open-menu')));
        await _pumpFrames(tester);
        await tester.tap(find.byKey(const Key('session-menu-detection-toggle')));
        await _pumpFrames(tester);
      }

      testWidgets('R1: tapping the detection button opens link-highlight-menu, '
          'does NOT flip enabled, and the session menu is gone first', (
        tester,
      ) async {
        final container = _makeContainer();
        _add(container, 'host-a');

        await tester.pumpWidget(_host(container: container));
        await tester.tap(find.byKey(const Key('open-menu')));
        await _pumpFrames(tester);
        expect(
          find.byKey(const Key('session-menu-detection-toggle')),
          findsOneWidget,
        );
        expect(container.read(detectionSettingsProvider).enabled, isTrue);

        if (kDetectionDisabled971) {
          // R4: the kill switch keeps the button disabled + inert — no sheet.
          await tester.tap(
            find.byKey(const Key('session-menu-detection-toggle')),
            warnIfMissed: false,
          );
          await _pumpFrames(tester);
          expect(find.byKey(const Key('link-highlight-menu')), findsNothing);
          expect(container.read(detectionSettingsProvider).enabled, isTrue);
          return;
        }

        await tester.tap(find.byKey(const Key('session-menu-detection-toggle')));
        await _pumpFrames(tester);

        expect(find.byKey(const Key('link-highlight-menu')), findsOneWidget);
        // #664: the overlay menu must be closed BEFORE the sheet shows, or the
        // sheet is trapped under the menu's tap barrier.
        expect(find.byKey(const Key('session-menu')), findsNothing);
        expect(
          container.read(detectionSettingsProvider).enabled,
          isTrue,
          reason: 'R1: a tap opens the sheet; it no longer toggles enabled',
        );
        // The sheet carries the three Slice-1 controls.
        expect(find.byKey(const Key('link-highlight-enabled')), findsOneWidget);
        expect(
          find.byKey(const Key('link-highlight-intensity-low')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('link-highlight-intensity-medium')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('link-highlight-intensity-high')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('link-highlight-lab')), findsOneWidget);
      });

      testWidgets('R2: the master switch link-highlight-enabled flips enabled '
          '(live-apply, no Save)', (tester) async {
        if (kDetectionDisabled971) return; // R4: sheet unreachable
        final container = _makeContainer();
        _add(container, 'host-a');
        await tester.pumpWidget(_host(container: container));
        await openSheet(tester);

        expect(container.read(detectionSettingsProvider).enabled, isTrue);
        await tester.tap(find.byKey(const Key('link-highlight-enabled')));
        await _pumpFrames(tester);
        expect(container.read(detectionSettingsProvider).enabled, isFalse);

        // The sheet stays open (live-apply) and flips back on a second tap.
        expect(find.byKey(const Key('link-highlight-menu')), findsOneWidget);
        await tester.tap(find.byKey(const Key('link-highlight-enabled')));
        await _pumpFrames(tester);
        expect(container.read(detectionSettingsProvider).enabled, isTrue);
      });

      testWidgets('R2: each link-highlight-intensity-* segment writes '
          'intensity and touches nothing else', (tester) async {
        if (kDetectionDisabled971) return; // R4: sheet unreachable
        final container = _makeContainer();
        _add(container, 'host-a');
        await tester.pumpWidget(_host(container: container));
        await openSheet(tester);

        expect(
          container.read(detectionSettingsProvider).intensity,
          DetectionIntensity.medium,
        );
        await tester.tap(find.byKey(const Key('link-highlight-intensity-low')));
        await _pumpFrames(tester);
        expect(
          container.read(detectionSettingsProvider).intensity,
          DetectionIntensity.low,
        );
        await tester.tap(find.byKey(const Key('link-highlight-intensity-high')));
        await _pumpFrames(tester);
        expect(
          container.read(detectionSettingsProvider).intensity,
          DetectionIntensity.high,
        );
        await tester.tap(
          find.byKey(const Key('link-highlight-intensity-medium')),
        );
        await _pumpFrames(tester);
        expect(
          container.read(detectionSettingsProvider).intensity,
          DetectionIntensity.medium,
        );
        // Only intensity moved.
        final s = container.read(detectionSettingsProvider);
        expect(s.enabled, isTrue);
        expect(s.url, isTrue);
        expect(s.path, isTrue);
        expect(s.gutterSide, GutterSide.right);
        expect(s.gutterMode, GutterMode.overlay);
      });

      testWidgets('R5: the intensity control works while detection is OFF '
          '(configure now, takes effect when on)', (tester) async {
        if (kDetectionDisabled971) return; // R4: sheet unreachable
        final container = _makeContainer();
        _add(container, 'host-a');
        await container
            .read(detectionSettingsProvider.notifier)
            .setEnabled(false);
        await tester.pumpWidget(_host(container: container));
        await openSheet(tester);

        expect(container.read(detectionSettingsProvider).enabled, isFalse);
        await tester.tap(find.byKey(const Key('link-highlight-intensity-low')));
        await _pumpFrames(tester);
        expect(
          container.read(detectionSettingsProvider).intensity,
          DetectionIntensity.low,
        );
        expect(container.read(detectionSettingsProvider).enabled, isFalse);
      });

      testWidgets('R2: the link-highlight-lab tile opens the Detection lab',
          (tester) async {
        if (kDetectionDisabled971) return; // R4: sheet unreachable
        final container = _makeContainer();
        _add(container, 'host-a');
        await tester.pumpWidget(_host(container: container));
        await openSheet(tester);

        await tester.tap(find.byKey(const Key('link-highlight-lab')));
        await _pumpFrames(tester);
        expect(find.byType(DetectionLabScreen), findsOneWidget);
        expect(container.read(detectionSettingsProvider).enabled, isTrue);
      });

      // #1155 (Slice 2 of #1153): the sheet gains the gutter SIDE and gutter
      // MODE segmented controls (R2 remainder). Each writes ONLY its field
      // through the notifier (live-apply); the selected segment reflects the
      // provider state the moment the sheet opens.
      group('#1155 gutter side + mode controls (R2)', () {
        testWidgets('R2: the sheet carries the four side/mode segment keys '
            'with their labels', (tester) async {
          if (kDetectionDisabled971) return; // R4: sheet unreachable
          final container = _makeContainer();
          _add(container, 'host-a');
          await tester.pumpWidget(_host(container: container));
          await openSheet(tester);

          expect(find.byKey(const Key('link-highlight-menu')), findsOneWidget);
          expect(
            find.byKey(const Key('link-highlight-side-left')),
            findsOneWidget,
          );
          expect(
            find.byKey(const Key('link-highlight-side-right')),
            findsOneWidget,
          );
          expect(
            find.byKey(const Key('link-highlight-mode-overlay')),
            findsOneWidget,
          );
          expect(
            find.byKey(const Key('link-highlight-mode-column')),
            findsOneWidget,
          );
          expect(find.text('Left'), findsOneWidget);
          expect(find.text('Right'), findsOneWidget);
          expect(find.text('Overlay last column'), findsOneWidget);
          expect(find.text('Dedicated column'), findsOneWidget);
          // Slice 1's controls are still there.
          expect(find.byKey(const Key('link-highlight-enabled')), findsOneWidget);
          expect(find.byKey(const Key('link-highlight-lab')), findsOneWidget);
        });

        testWidgets('R2: link-highlight-side-left writes gutterSide == left; '
            'intensity and enabled are unchanged; -right restores', (
          tester,
        ) async {
          if (kDetectionDisabled971) return; // R4: sheet unreachable
          final container = _makeContainer();
          _add(container, 'host-a');
          await tester.pumpWidget(_host(container: container));
          await openSheet(tester);

          final before = container.read(detectionSettingsProvider);
          expect(before.gutterSide, GutterSide.right);

          await tester.tap(find.byKey(const Key('link-highlight-side-left')));
          await _pumpFrames(tester);
          var s = container.read(detectionSettingsProvider);
          expect(s.gutterSide, GutterSide.left);
          expect(s.intensity, before.intensity, reason: 'intensity untouched');
          expect(s.enabled, before.enabled, reason: 'enabled untouched');
          expect(s.gutterMode, before.gutterMode, reason: 'mode untouched');
          expect(s.url, before.url);
          expect(s.path, before.path);
          expect(s.command, before.command);
          // Live-apply: the sheet stays open.
          expect(find.byKey(const Key('link-highlight-menu')), findsOneWidget);

          await tester.tap(find.byKey(const Key('link-highlight-side-right')));
          await _pumpFrames(tester);
          s = container.read(detectionSettingsProvider);
          expect(s.gutterSide, GutterSide.right);
          expect(s.gutterMode, before.gutterMode);
        });

        testWidgets('R2: link-highlight-mode-column writes gutterMode == '
            'column; side/intensity/enabled unchanged; -overlay restores', (
          tester,
        ) async {
          if (kDetectionDisabled971) return; // R4: sheet unreachable
          final container = _makeContainer();
          _add(container, 'host-a');
          await tester.pumpWidget(_host(container: container));
          await openSheet(tester);

          final before = container.read(detectionSettingsProvider);
          expect(before.gutterMode, GutterMode.overlay);

          await tester.tap(find.byKey(const Key('link-highlight-mode-column')));
          await _pumpFrames(tester);
          var s = container.read(detectionSettingsProvider);
          expect(s.gutterMode, GutterMode.column);
          expect(s.gutterSide, before.gutterSide, reason: 'side untouched');
          expect(s.intensity, before.intensity, reason: 'intensity untouched');
          expect(s.enabled, before.enabled, reason: 'enabled untouched');
          expect(find.byKey(const Key('link-highlight-menu')), findsOneWidget);

          await tester.tap(find.byKey(const Key('link-highlight-mode-overlay')));
          await _pumpFrames(tester);
          s = container.read(detectionSettingsProvider);
          expect(s.gutterMode, GutterMode.overlay);
          expect(s.gutterSide, before.gutterSide);
        });

        testWidgets('R2: the selected segments reflect the provider state on '
            'open (left + column pre-set → those segments selected)', (
          tester,
        ) async {
          if (kDetectionDisabled971) return; // R4: sheet unreachable
          final container = _makeContainer();
          _add(container, 'host-a');
          final notifier = container.read(detectionSettingsProvider.notifier);
          await notifier.setGutterSide(GutterSide.left);
          await notifier.setGutterMode(GutterMode.column);
          await tester.pumpWidget(_host(container: container));
          await openSheet(tester);

          final sideControl = tester.widget<SegmentedButton<GutterSide>>(
            find.byType(SegmentedButton<GutterSide>),
          );
          expect(sideControl.selected, {GutterSide.left});
          final modeControl = tester.widget<SegmentedButton<GutterMode>>(
            find.byType(SegmentedButton<GutterMode>),
          );
          expect(modeControl.selected, {GutterMode.column});
          // And the defaults case: a fresh container opens on right/overlay.
          // Tear the first tree down first: re-pumping a same-shaped host
          // reuses the Navigator, so the open sheet's barrier would swallow
          // the second open-menu tap.
          await tester.pumpWidget(const SizedBox.shrink());
          await _pumpFrames(tester);
          // The notifier persists to SharedPreferences: a genuinely fresh
          // container needs fresh (empty) prefs too, or it reads left/column.
          SharedPreferences.setMockInitialValues({});
          final fresh = _makeContainer();
          _add(fresh, 'host-b');
          await tester.pumpWidget(_host(container: fresh));
          await openSheet(tester);
          expect(
            tester
                .widget<SegmentedButton<GutterSide>>(
                  find.byType(SegmentedButton<GutterSide>),
                )
                .selected,
            {GutterSide.right},
          );
          expect(
            tester
                .widget<SegmentedButton<GutterMode>>(
                  find.byType(SegmentedButton<GutterMode>),
                )
                .selected,
            {GutterMode.overlay},
          );
        });

        testWidgets('R5: side/mode controls work while detection is OFF', (
          tester,
        ) async {
          if (kDetectionDisabled971) return; // R4: sheet unreachable
          final container = _makeContainer();
          _add(container, 'host-a');
          await container
              .read(detectionSettingsProvider.notifier)
              .setEnabled(false);
          await tester.pumpWidget(_host(container: container));
          await openSheet(tester);

          await tester.tap(find.byKey(const Key('link-highlight-side-left')));
          await _pumpFrames(tester);
          await tester.tap(find.byKey(const Key('link-highlight-mode-column')));
          await _pumpFrames(tester);
          final s = container.read(detectionSettingsProvider);
          expect(s.gutterSide, GutterSide.left);
          expect(s.gutterMode, GutterMode.column);
          expect(s.enabled, isFalse, reason: 'configuring never flips enabled');
        });
      });
    });

    testWidgets('#1031 review change 7: long-pressing the detection glyph '
        'opens the Detection lab (menu closes first)', (tester) async {
      final container = _makeContainer();
      _add(container, 'host-a');

      await tester.pumpWidget(_host(container: container));
      await tester.tap(find.byKey(const Key('open-menu')));
      await _pumpFrames(tester);

      await tester.longPress(
        find.byKey(const Key('session-menu-detection-toggle')),
      );
      await _pumpFrames(tester);

      // The lab root is pushed on the app navigator and the overlay menu is
      // gone (a route pushed UNDER the menu's barrier would be un-tappable).
      expect(find.byType(DetectionLabScreen), findsOneWidget);
      expect(find.byKey(const Key('session-menu')), findsNothing);
      // The long-press must NOT have flipped the toggle.
      expect(container.read(detectionSettingsProvider).enabled, isTrue);
    });

    testWidgets('font +/- still mutates only the active session', (
      tester,
    ) async {
      final container = _makeContainer();
      final a = _add(container, 'host-a');
      final b = _add(container, 'host-b'); // b active

      await tester.pumpWidget(_host(container: container));
      await tester.tap(find.byKey(const Key('open-menu')));
      await _pumpFrames(tester);

      await tester.tap(find.byKey(const Key('session-menu-fontsize-inc')));
      await _pumpFrames(tester);

      expect(
        container.read(sessionFontSizeProvider(b.id)),
        greaterThan(fontSizeDefault),
      );
      expect(container.read(sessionFontSizeProvider(a.id)), fontSizeDefault);
    });
  });

  group('SessionMenu non-modal overlay (#585 guard)', () {
    testWidgets('opening the slim menu keeps the focused editable', (
      tester,
    ) async {
      final container = _makeContainer();
      _add(container, 'host-a');

      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (ctx) => Column(
                  children: [
                    TextField(
                      key: const Key('terminal-input-stand-in'),
                      focusNode: focusNode,
                    ),
                    ElevatedButton(
                      key: const Key('open-menu'),
                      onPressed: () => showSessionMenu(ctx),
                      child: const Text('open'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

      focusNode.requestFocus();
      await _pumpFrames(tester);
      expect(focusNode.hasFocus, isTrue);

      await tester.tap(find.byKey(const Key('open-menu')));
      await _pumpFrames(tester);

      expect(find.byKey(const Key('session-menu')), findsOneWidget);
      expect(
        focusNode.hasFocus,
        isTrue,
        reason: 'slim menu must not steal focus -> keyboard stays up (#585)',
      );
    });
  });
}
