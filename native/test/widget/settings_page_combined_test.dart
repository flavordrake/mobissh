// Widget tests for the Settings page (#897 reorg, #966 Play-Store cleanup,
// #1257 five-section IA + experimental flag).
//
// Asserts:
//   - The main page shows exactly the five sections and their rows, with no
//     expander tap.
//   - Moved items (per-type detection switches, the exceptions list) and
//     removed items (the #971 subtitle, the terminal-engine selector) are gone.
//   - The battery row renders only while the app is NOT yet exempt.
//   - Diagnostics sit in a COLLAPSED "Advanced" expander. The experimental
//     items (tmux control mode, Force upload, Connection audit) are absent
//     until "Show experimental settings" is on.
//   - A hidden experimental setting that is ON keeps its value and effect, and
//     Advanced says so ("1 experimental setting is on").
//   - Reset confirms, restores defaults (incl. the flag), and its copy no
//     longer mentions the retired terminal engine.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/services/battery_optimization.dart';
import 'package:mobissh/state/detection_exceptions_providers.dart';
import 'package:mobissh/state/detection_providers.dart';
import 'package:mobissh/state/detection_style_providers.dart';
import 'package:mobissh/state/feature_flags_providers.dart';
import 'package:mobissh/state/keepalive_providers.dart';
import 'package:mobissh/state/tmux_control_mode_setting.dart';
import 'package:mobissh/state/ui_prefs_providers.dart';
import 'package:mobissh/ui/detection_lab_screen.dart';
import 'package:mobissh/ui/settings_screen.dart';

class _FakeBatteryPlatform implements BatteryOptimizationPlatform {
  _FakeBatteryPlatform({required this.exempt});
  bool exempt;

  @override
  Future<bool> get isIgnoringBatteryOptimizations async => exempt;

  @override
  Future<bool> requestIgnoreBatteryOptimization() async {
    exempt = true;
    return true;
  }
}

Future<void> _pumpFrames(WidgetTester tester, {int count = 10}) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

ProviderContainer _container({bool exempt = true}) {
  final c = ProviderContainer(
    overrides: [
      batteryOptimizationProvider.overrideWithValue(
        BatteryOptimizationController(
          platform: _FakeBatteryPlatform(exempt: exempt),
          prefs: SharedPreferences.getInstance(),
        ),
      ),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

Future<void> _pumpPage(WidgetTester tester, ProviderContainer container) async {
  // Tall viewport so the whole page (incl. the expanded Advanced block and the
  // bottom reset button) lays out on-screen and is hit-testable.
  tester.view.physicalSize = const Size(1000, 5000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: SettingsScreen())),
    ),
  );
  await _pumpFrames(tester);
}

Future<void> _expandAdvanced(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('settings-advanced-tile')));
  await _pumpFrames(tester);
}

const _experimentalKeys = [
  'tmux-control-mode-toggle',
  'force-upload-button',
  'connection-audit-button',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('main page: five sections, in order, with their rows', (
    tester,
  ) async {
    await _pumpPage(tester, _container(exempt: false));

    const sections = [
      'Connections',
      'Terminal',
      'Links & paths',
      'Background',
      'About & updates',
    ];
    var lastY = -1.0;
    for (final s in sections) {
      final f = find.text(s);
      expect(f, findsOneWidget, reason: 'section "$s"');
      final y = tester.getTopLeft(f).dy;
      expect(y, greaterThan(lastY), reason: '"$s" is in IA order');
      lastY = y;
    }
    // The pre-#1257 subheaders are gone.
    for (final old in const ['General', 'Keys', 'Detection',
        'Detection exceptions']) {
      expect(find.text(old), findsNothing, reason: 'old subheader "$old"');
    }

    for (final key in const [
      'ssh-keys-tile',
      'font-size-slider',
      'default-font-tile',
      'detection-master-toggle',
      'detection-lab-tile',
      'keepalive-toggle',
      'battery-opt-tile',
      'app-version-tile',
      'settings-advanced-tile',
      'settings-reset-button',
    ]) {
      expect(
        find.byKey(ValueKey(key)),
        findsOneWidget,
        reason: '$key must be a visible top-level control',
      );
    }
  });

  testWidgets('moved and removed items are not on the main page', (
    tester,
  ) async {
    final container = _container();
    // Seed an exception: it must NOT grow the main page any more.
    await _pumpPage(tester, container);
    await container.read(detectionExceptionsProvider.notifier).report(
          patternId: 'url',
          matchedText: 'https://not.a.link',
        );
    await _pumpFrames(tester);

    for (final key in const [
      'detection-url-toggle',
      'detection-path-toggle',
      'detection-relpath-toggle',
      'detection-command-toggle',
      'detection-exceptions-empty',
      'detection-exception-0',
      // #966: the engine selector stays retired.
      'terminal-backend-selector',
      'terminal-backend-tile',
    ]) {
      expect(find.byKey(ValueKey(key)), findsNothing, reason: key);
    }
    expect(find.textContaining('#971'), findsNothing);
    expect(find.textContaining('xterm'), findsNothing);
  });

  testWidgets('battery row is absent once the app is exempt', (tester) async {
    await _pumpPage(tester, _container(exempt: true));
    expect(find.byKey(const ValueKey('battery-opt-tile')), findsNothing);
  });

  testWidgets('battery row disappears after the exemption is granted', (
    tester,
  ) async {
    await _pumpPage(tester, _container(exempt: false));
    await tester.tap(find.byKey(const ValueKey('battery-opt-tile')));
    await _pumpFrames(tester);
    expect(find.byKey(const ValueKey('battery-opt-tile')), findsNothing);
  });

  testWidgets('Diagnostics is tucked behind a collapsed Advanced expander', (
    tester,
  ) async {
    await _pumpPage(tester, _container());

    expect(find.byKey(const ValueKey('diagnostics-section')), findsNothing);
    await _expandAdvanced(tester);

    for (final key in const [
      'diagnostics-section',
      'share-feedback-button',
      'show-experimental-toggle',
    ]) {
      expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
    }
  });

  testWidgets('experimental items are hidden until the flag is on', (
    tester,
  ) async {
    final container = _container();
    await _pumpPage(tester, container);
    await _expandAdvanced(tester);

    for (final key in _experimentalKeys) {
      expect(find.byKey(ValueKey(key)), findsNothing, reason: '$key hidden');
    }
    expect(find.byKey(const ValueKey('experimental-on-note')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('show-experimental-toggle')));
    await _pumpFrames(tester);

    expect(container.read(featureFlagsProvider).showExperimental, isTrue);
    for (final key in _experimentalKeys) {
      expect(find.byKey(ValueKey(key)), findsOneWidget, reason: '$key shown');
    }

    // The flag persists.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(featureFlagsPrefKey), contains('"showExperimental":true'));
  });

  testWidgets('the page constructs the tmux setting provider whatever the '
      'flag (connect reads its hydrated global)', (tester) async {
    for (final show in const [false, true]) {
      SharedPreferences.setMockInitialValues(<String, Object>{
        featureFlagsPrefKey: '{"v":1,"showExperimental":$show}',
      });
      final container = _container();
      await _pumpPage(tester, container);
      expect(container.exists(tmuxControlModeProvider), isTrue,
          reason: 'showExperimental=$show, Advanced collapsed');
    }
  });

  testWidgets('a hidden setting that is ON keeps working and is announced', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      tmuxControlModePrefKey: true,
    });
    final container = _container();
    await _pumpPage(tester, container);

    // Hiding never changes the value.
    expect(container.read(tmuxControlModeProvider), isTrue);
    expect(container.read(featureFlagsProvider).showExperimental, isFalse);

    // Announced even while Advanced is collapsed.
    expect(find.text('1 experimental setting is on'), findsWidgets);

    await _expandAdvanced(tester);
    expect(
      find.byKey(const ValueKey('tmux-control-mode-toggle')),
      findsNothing,
    );
    final note = find.byKey(const ValueKey('experimental-on-note'));
    expect(note, findsOneWidget);

    // Tapping the note reveals the experimental items.
    await tester.tap(note);
    await _pumpFrames(tester);
    expect(
      find.byKey(const ValueKey('tmux-control-mode-toggle')),
      findsOneWidget,
    );
    expect(container.read(tmuxControlModeProvider), isTrue);
    expect(find.byKey(const ValueKey('experimental-on-note')), findsNothing);
  });

  testWidgets('Reset settings confirms, restores defaults and the flag', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      fontSizePrefKey: 22.0,
      featureFlagsPrefKey: '{"v":1,"showExperimental":true}',
    });
    final container = _container();
    await _pumpPage(tester, container);
    expect(container.read(fontSizeProvider), 22.0);
    expect(container.read(featureFlagsProvider).showExperimental, isTrue);

    await tester.tap(find.byKey(const ValueKey('settings-reset-button')));
    await _pumpFrames(tester);
    final dialog = find.byKey(const ValueKey('settings-reset-dialog'));
    expect(dialog, findsOneWidget);
    expect(
      find.descendant(of: dialog, matching: find.textContaining('engine')),
      findsNothing,
      reason: 'the terminal-engine selector was retired (#966)',
    );

    await tester.tap(find.byKey(const ValueKey('settings-reset-confirm')));
    await _pumpFrames(tester);

    expect(container.read(fontSizeProvider), fontSizeDefault);
    expect(container.read(featureFlagsProvider).showExperimental, isFalse);
  });

  testWidgets('#1031 slice 2: a Detection lab row opens the lab route', (
    tester,
  ) async {
    await _pumpPage(tester, _container());

    await tester.tap(find.byKey(const ValueKey('detection-lab-tile')));
    await _pumpFrames(tester);
    expect(find.byType(DetectionLabScreen), findsOneWidget);
  });

  testWidgets('#1031 slice 2: Reset settings clears TUNED lab styles but '
      'authored exceptions survive', (tester) async {
    final container = _container();
    await _pumpPage(tester, container);

    await container
        .read(detectionStylesProvider.notifier)
        .setColorHex('url', '#e53935');
    await container.read(detectionExceptionsProvider.notifier).report(
          patternId: 'url',
          matchedText: 'https://not.a.link',
        );
    await _pumpFrames(tester);
    expect(container.read(detectionStylesProvider).isEmpty, isFalse);
    expect(container.read(detectionExceptionsProvider), hasLength(1));

    await tester.tap(find.byKey(const ValueKey('settings-reset-button')));
    await _pumpFrames(tester);
    await tester.tap(find.byKey(const ValueKey('settings-reset-confirm')));
    await _pumpFrames(tester);

    expect(container.read(detectionStylesProvider).isEmpty, isTrue);
    expect(container.read(detectionExceptionsProvider), hasLength(1));
  });

  testWidgets('#1154 R9: Reset settings restores the detection fields', (
    tester,
  ) async {
    final container = _container();
    await _pumpPage(tester, container);

    final notifier = container.read(detectionSettingsProvider.notifier);
    await notifier.setIntensity(DetectionIntensity.low);
    await notifier.setGutterSide(GutterSide.left);
    await notifier.setGutterMode(GutterMode.column);
    await notifier.setUrl(false);
    await _pumpFrames(tester);

    await tester.tap(find.byKey(const ValueKey('settings-reset-button')));
    await _pumpFrames(tester);
    await tester.tap(find.byKey(const ValueKey('settings-reset-confirm')));
    await _pumpFrames(tester);

    expect(
      container.read(detectionSettingsProvider),
      const DetectionSettings(),
      reason: 'full default after reset',
    );
  });

  testWidgets('Reset settings can be cancelled (no change)', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      fontSizePrefKey: 22.0,
    });
    final container = _container();
    await _pumpPage(tester, container);

    await tester.tap(find.byKey(const ValueKey('settings-reset-button')));
    await _pumpFrames(tester);
    await tester.tap(find.text('Cancel'));
    await _pumpFrames(tester);

    expect(container.read(fontSizeProvider), 22.0);
  });
}
