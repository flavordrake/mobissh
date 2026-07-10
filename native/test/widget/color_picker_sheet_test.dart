// Widget tests for the shared color picker (#1030).
//
// The picker is a SHARED widget: the profile editor uses it for the device
// swatch and the detection lab (#1031) will reuse it for pattern colors, so
// the tests pin the reuse contract:
//   - hex round-trip: initial color → hex field text → edited hex → color
//   - '#' is optional in hex entry
//   - invalid hex shows an inline error and disables Apply
//   - preset chip tap selects (updates hex + preview)
//   - HSV interaction (SV square tap, hue slider tap) changes the value
//   - Apply reports the picked color; Clear (when offered) reports null-color
//     (the #1031 "Use theme color" path, distinct from cancel)

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobissh/ui/color_picker_sheet.dart';

Color _previewColor(WidgetTester tester) {
  final container = tester.widget<Container>(
    find.byKey(const Key('color-picker-preview')),
  );
  return (container.decoration! as BoxDecoration).color!;
}

String _hexFieldText(WidgetTester tester) {
  final field = tester.widget<TextField>(
    find.byKey(const Key('color-picker-hex')),
  );
  return field.controller?.text ?? '';
}

Future<void> _pumpPanel(
  WidgetTester tester, {
  Color? initial,
  String? clearLabel,
  ValueChanged<Color>? onApply,
  VoidCallback? onClear,
}) async {
  tester.view.physicalSize = const Size(500, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ColorPickerPanel(
            initial: initial,
            clearLabel: clearLabel,
            onApply: onApply ?? (_) {},
            onClear: onClear,
            onCancel: () {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('hexFromColor', () {
    test('formats an opaque color as lowercase #rrggbb', () {
      expect(hexFromColor(const Color(0xFF336699)), '#336699');
      expect(hexFromColor(const Color(0xFFFF8800)), '#ff8800');
      expect(hexFromColor(const Color(0xFF000000)), '#000000');
    });
  });

  group('ColorPickerPanel', () {
    testWidgets('seeds the hex field and preview from the initial color', (
      tester,
    ) async {
      await _pumpPanel(tester, initial: const Color(0xFF336699));
      expect(_hexFieldText(tester), '#336699');
      expect(_previewColor(tester), const Color(0xFF336699));
    });

    testWidgets('hex entry round-trips: typed hex drives preview and Apply', (
      tester,
    ) async {
      Color? applied;
      await _pumpPanel(
        tester,
        initial: const Color(0xFF336699),
        onApply: (c) => applied = c,
      );

      await tester.enterText(
        find.byKey(const Key('color-picker-hex')),
        '#ff8800',
      );
      await tester.pumpAndSettle();
      expect(_previewColor(tester), const Color(0xFFFF8800));

      await tester.tap(find.byKey(const Key('color-picker-apply')));
      await tester.pumpAndSettle();
      expect(applied, const Color(0xFFFF8800));
    });

    testWidgets('leading # is optional in hex entry', (tester) async {
      await _pumpPanel(tester, initial: const Color(0xFF336699));
      await tester.enterText(
        find.byKey(const Key('color-picker-hex')),
        '43a047',
      );
      await tester.pumpAndSettle();
      expect(_previewColor(tester), const Color(0xFF43A047));
    });

    testWidgets('invalid hex shows an inline error and disables Apply', (
      tester,
    ) async {
      await _pumpPanel(tester, initial: const Color(0xFF336699));
      await tester.enterText(
        find.byKey(const Key('color-picker-hex')),
        'not-a-color',
      );
      await tester.pumpAndSettle();

      expect(find.text('Invalid hex color'), findsOneWidget);
      final apply = tester.widget<FilledButton>(
        find.byKey(const Key('color-picker-apply')),
      );
      expect(apply.onPressed, isNull, reason: 'Apply must gate on valid hex');
      // Preview keeps the last valid color — never blank, never crashes.
      expect(_previewColor(tester), const Color(0xFF336699));
    });

    testWidgets('preset chip tap selects that color', (tester) async {
      await _pumpPanel(tester, initial: const Color(0xFF336699));

      final preset = colorPickerPresets.first;
      final hex = hexFromColor(preset);
      await tester.tap(find.byKey(Key('color-picker-preset-$hex')));
      await tester.pumpAndSettle();

      expect(_previewColor(tester), preset);
      expect(_hexFieldText(tester), hex);
    });

    testWidgets('every shared preset renders a chip', (tester) async {
      await _pumpPanel(tester);
      for (final preset in colorPickerPresets) {
        expect(
          find.byKey(Key('color-picker-preset-${hexFromColor(preset)}')),
          findsOneWidget,
        );
      }
    });

    testWidgets('tapping the SV square changes the color', (tester) async {
      await _pumpPanel(tester, initial: const Color(0xFF336699));
      final before = _previewColor(tester);

      final sv = find.byKey(const Key('color-picker-sv'));
      final rect = tester.getRect(sv);
      // Near top-right = high saturation + high value for the current hue.
      await tester.tapAt(rect.topRight + const Offset(-4, 4));
      await tester.pumpAndSettle();

      final after = _previewColor(tester);
      expect(after, isNot(before));
      // Hex field tracks the interactive selection.
      expect(_hexFieldText(tester), hexFromColor(after));
    });

    testWidgets('tapping the hue slider changes the hue', (tester) async {
      // Pure red, full S/V: any mid-slider hue tap must move off red.
      await _pumpPanel(tester, initial: const Color(0xFFFF0000));
      final before = _previewColor(tester);

      final hue = find.byKey(const Key('color-picker-hue'));
      await tester.tapAt(tester.getCenter(hue));
      await tester.pumpAndSettle();

      expect(_previewColor(tester), isNot(before));
    });

    testWidgets('Clear action reports the null-color path when offered', (
      tester,
    ) async {
      var cleared = false;
      await _pumpPanel(
        tester,
        initial: const Color(0xFF336699),
        clearLabel: 'No color (theme accent)',
        onClear: () => cleared = true,
      );

      await tester.tap(find.byKey(const Key('color-picker-clear')));
      await tester.pumpAndSettle();
      expect(cleared, isTrue);
    });

    testWidgets('Clear action is absent when no clearLabel is given', (
      tester,
    ) async {
      await _pumpPanel(tester, initial: const Color(0xFF336699));
      expect(find.byKey(const Key('color-picker-clear')), findsNothing);
    });

    testWidgets('touch targets are thumb-sized (>=44dp)', (tester) async {
      await _pumpPanel(tester, initial: const Color(0xFF336699));

      final presetSize = tester.getSize(
        find.byKey(
          Key('color-picker-preset-${hexFromColor(colorPickerPresets.first)}'),
        ),
      );
      expect(presetSize.width, greaterThanOrEqualTo(44));
      expect(presetSize.height, greaterThanOrEqualTo(44));

      final hueSize = tester.getSize(find.byKey(const Key('color-picker-hue')));
      expect(hueSize.height, greaterThanOrEqualTo(44));
    });
  });

  group('showColorPickerSheet', () {
    testWidgets('Apply pops with the picked color; Cancel pops null', (
      tester,
    ) async {
      ColorPickerResult? result;
      var opened = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: FilledButton(
                  key: const Key('open-picker'),
                  onPressed: () async {
                    opened += 1;
                    result = await showColorPickerSheet(
                      context,
                      initial: const Color(0xFF336699),
                      clearLabel: 'No color',
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );

      // Apply path.
      await tester.tap(find.byKey(const Key('open-picker')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('color-picker-hex')),
        '#d81b60',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('color-picker-apply')));
      await tester.pumpAndSettle();
      expect(result, isNotNull);
      expect(result!.color, const Color(0xFFD81B60));

      // Clear path: a result with a null color (≠ cancel).
      await tester.tap(find.byKey(const Key('open-picker')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('color-picker-clear')));
      await tester.pumpAndSettle();
      expect(result, isNotNull);
      expect(result!.color, isNull);

      // Cancel path: null result.
      await tester.tap(find.byKey(const Key('open-picker')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('color-picker-cancel')));
      await tester.pumpAndSettle();
      expect(result, isNull);
      expect(opened, 3);
    });
  });
}
