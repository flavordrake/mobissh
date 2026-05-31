// Unit tests for the #552 terminal-appearance preferences:
// font-size persistence + clamp, and theme index persistence + cycle wrap.

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/state/ui_prefs_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _settle() async {
  // Let the StateNotifier _hydrate Future resolve.
  await Future<void>.delayed(const Duration(milliseconds: 10));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('FontSizeNotifier', () {
    test('defaults to fontSizeDefault with no stored value', () async {
      final n = FontSizeNotifier(prefs: SharedPreferences.getInstance());
      await _settle();
      expect(n.state, fontSizeDefault);
    });

    test('hydrates a stored value', () async {
      SharedPreferences.setMockInitialValues({fontSizePrefKey: 20.0});
      final n = FontSizeNotifier(prefs: SharedPreferences.getInstance());
      await _settle();
      expect(n.state, 20.0);
    });

    test('set clamps below minimum', () async {
      final n = FontSizeNotifier(prefs: SharedPreferences.getInstance());
      await _settle();
      await n.set(1);
      expect(n.state, kFontSizeMin);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble(fontSizePrefKey), kFontSizeMin);
    });

    test('set clamps above maximum', () async {
      final n = FontSizeNotifier(prefs: SharedPreferences.getInstance());
      await _settle();
      await n.set(999);
      expect(n.state, kFontSizeMax);
    });

    test('set persists an in-range value', () async {
      final n = FontSizeNotifier(prefs: SharedPreferences.getInstance());
      await _settle();
      await n.set(18);
      expect(n.state, 18);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble(fontSizePrefKey), 18);
    });

    test('hydrate clamps an out-of-range stored value', () async {
      SharedPreferences.setMockInitialValues({fontSizePrefKey: 500.0});
      final n = FontSizeNotifier(prefs: SharedPreferences.getInstance());
      await _settle();
      expect(n.state, kFontSizeMax);
    });
  });

  group('TerminalThemeNotifier', () {
    test('at least two palettes are ported', () {
      expect(terminalPalettes.length, greaterThanOrEqualTo(2));
      expect(terminalPalettes.first.label, 'Dark');
    });

    test('defaults to terminalThemeDefault with no stored value', () async {
      final n = TerminalThemeNotifier(prefs: SharedPreferences.getInstance());
      await _settle();
      expect(n.state, terminalThemeDefault);
    });

    test('hydrates a stored index', () async {
      SharedPreferences.setMockInitialValues({terminalThemePrefKey: 1});
      final n = TerminalThemeNotifier(prefs: SharedPreferences.getInstance());
      await _settle();
      expect(n.state, 1);
    });

    test('cycle advances and persists', () async {
      final n = TerminalThemeNotifier(prefs: SharedPreferences.getInstance());
      await _settle();
      await n.cycle();
      expect(n.state, 1);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(terminalThemePrefKey), 1);
    });

    test('cycle wraps at the end of the palette list', () async {
      final n = TerminalThemeNotifier(prefs: SharedPreferences.getInstance());
      await _settle();
      for (var i = 0; i < terminalPalettes.length; i++) {
        await n.cycle();
      }
      // One full revolution returns to the starting index.
      expect(n.state, terminalThemeDefault);
    });

    test('set falls back to default for out-of-range index', () async {
      final n = TerminalThemeNotifier(prefs: SharedPreferences.getInstance());
      await _settle();
      await n.set(9999);
      expect(n.state, terminalThemeDefault);
    });

    test('hydrate ignores an out-of-range stored index', () async {
      SharedPreferences.setMockInitialValues({terminalThemePrefKey: 9999});
      final n = TerminalThemeNotifier(prefs: SharedPreferences.getInstance());
      await _settle();
      expect(n.state, terminalThemeDefault);
    });
  });
}
