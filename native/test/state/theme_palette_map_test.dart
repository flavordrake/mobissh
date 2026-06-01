// #613 — full PWA theme set + PWA→native map.
//
// The PWA `THEMES` map (src/modules/constants.ts, ordered by THEME_ORDER) is the
// AUTHORITATIVE theme set. Native `terminalPalettes` must port EVERY entry, keyed
// by the PWA ThemeName, and `paletteIndexForThemeName` is the PWA→native lookup
// that wires a profile's saved/imported `theme` into a session.
//
// These tests guard:
//   - coverage: a palette exists for EVERY PWA theme key (so a future PWA theme
//     added without a native palette FAILS here — drift detection).
//   - mapping: each key resolves to a DISTINCT palette index; unknown/null → default.

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/state/ui_prefs_providers.dart';

/// The PWA `THEME_ORDER` from src/modules/constants.ts — hardcoded so that
/// adding a PWA theme without a matching native palette surfaces as a failing
/// test (the sync-check). Keep in THEME_ORDER order.
const List<String> kPwaThemeKeys = <String>[
  'dark',
  'light',
  'solarizedDark',
  'solarizedLight',
  'highContrast',
  'highContrastLight',
  'dracula',
  'draculaLight',
  'nord',
  'nordLight',
  'gruvboxDark',
  'gruvboxLight',
  'monokai',
  'monokaiLight',
  'tokyoNight',
  'tokyoNightDay',
  'ocean',
  'oceanLight',
  'ember',
  'emberLight',
  'forest',
  'forestLight',
  'sunset',
  'sunsetLight',
  'synthwave',
  'synthwaveLight',
  'commodore',
  'commodoreLight',
  'terminal',
  'terminalLight',
  'borland',
  'borlandLight',
  'arcticDark',
  'arctic',
  'cobalt',
  'cobaltLight',
  'matrix',
  'matrixLight',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('terminalPalettes coverage', () {
    test('a palette exists for EVERY PWA theme key', () {
      final keys = terminalPalettes.map((p) => p.key).toSet();
      for (final pwaKey in kPwaThemeKeys) {
        expect(
          keys.contains(pwaKey),
          isTrue,
          reason:
              'PWA theme "$pwaKey" has no native palette — port it to '
              'terminalPalettes (#613 drift guard)',
        );
      }
    });

    test('palettes are ordered to match THEME_ORDER', () {
      // The first len(kPwaThemeKeys) palettes must be in THEME_ORDER order so a
      // profile theme key resolves to the expected palette and cycle order
      // matches the PWA.
      for (var i = 0; i < kPwaThemeKeys.length; i++) {
        expect(terminalPalettes[i].key, kPwaThemeKeys[i]);
      }
    });

    test('default palette index 0 is the PWA `dark` theme', () {
      expect(terminalThemeDefault, 0);
      expect(terminalPalettes[terminalThemeDefault].key, 'dark');
      expect(terminalPalettes[terminalThemeDefault].label, 'Dark');
    });

    test('every palette key is unique', () {
      final keys = terminalPalettes.map((p) => p.key).toList();
      expect(
        keys.toSet().length,
        keys.length,
        reason: 'palette keys must be unique',
      );
    });
  });

  group('paletteIndexForThemeName (PWA→native map)', () {
    test('every PWA key resolves to a DISTINCT palette index', () {
      final indices = <int>{};
      for (final key in kPwaThemeKeys) {
        final idx = paletteIndexForThemeName(key);
        expect(
          terminalPalettes[idx].key,
          key,
          reason: 'key "$key" must map to the palette with that key',
        );
        expect(
          indices.add(idx),
          isTrue,
          reason: 'key "$key" mapped to an already-used index — not distinct',
        );
      }
      expect(indices.length, kPwaThemeKeys.length);
    });

    test('unknown name falls back to the default index', () {
      expect(paletteIndexForThemeName('no-such-theme'), terminalThemeDefault);
    });

    test('null falls back to the default index', () {
      expect(paletteIndexForThemeName(null), terminalThemeDefault);
    });

    test('a representative theme maps to the right palette', () {
      final draculaIdx = paletteIndexForThemeName('dracula');
      expect(terminalPalettes[draculaIdx].label, 'Dracula');
    });
  });
}
