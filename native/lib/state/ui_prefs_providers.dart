// UI preference providers (#518, #552).
//
// `keybarVisibleProvider` controls whether the bottom keybar is rendered on
// the terminal screen. Default: true (matches the PWA where the key bar is
// visible whenever the keyboard is up). The toggle lives inside the session
// menu; the setting persists across launches via SharedPreferences.
//
// #552 adds terminal-appearance preferences:
//   - `fontSizeProvider` — terminal font size in logical px, persisted +
//     clamped to [kFontSizeMin]..[kFontSizeMax]. Applied to the xterm
//     `TerminalView` via `TerminalStyle(fontSize:)`.
//   - `terminalThemeProvider` — index into [terminalPalettes], persisted. The
//     palettes are Flutter `TerminalTheme`s ported from the PWA `THEMES` map
//     (`src/modules/terminal.ts`). The session menu cycles this index; the
//     terminal screen applies the selected palette to `TerminalView`.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';

/// SharedPreferences key. Matches the keep-alive naming style.
const String keybarVisiblePrefKey = 'mobissh.ui.keybarVisible';

/// Default to visible — parity with the PWA default.
const bool keybarVisibleDefault = true;

/// User toggle for the bottom keybar. Synchronous value (defaulted to
/// [keybarVisibleDefault] while we load preferences) so the UI doesn't need
/// a loading state.
class KeybarVisibleNotifier extends StateNotifier<bool> {
  KeybarVisibleNotifier({Future<SharedPreferences>? prefs})
    : _prefs = prefs ?? SharedPreferences.getInstance(),
      super(keybarVisibleDefault) {
    _hydrate();
  }

  final Future<SharedPreferences> _prefs;

  Future<void> _hydrate() async {
    try {
      final prefs = await _prefs;
      final stored = prefs.getBool(keybarVisiblePrefKey);
      if (stored != null && stored != state) state = stored;
    } catch (_) {
      // SharedPreferences may be unavailable in tests without bindings; keep
      // the default in that case.
    }
  }

  Future<void> set(bool value) async {
    state = value;
    try {
      final prefs = await _prefs;
      await prefs.setBool(keybarVisiblePrefKey, value);
    } catch (_) {
      // best-effort persistence
    }
  }

  void toggle() => set(!state);
}

final keybarVisibleProvider =
    StateNotifierProvider<KeybarVisibleNotifier, bool>((ref) {
      return KeybarVisibleNotifier();
    });

// ── Terminal font size (#552) ─────────────────────────────────────────────

/// SharedPreferences key for the terminal font size.
const String fontSizePrefKey = 'mobissh.ui.fontSize';

/// Default terminal font size in logical px. xterm.dart's own default is
/// 13.0; the PWA defaults to 14. We pick 13 to match the terminal widget's
/// native default so the first paint is stable.
const double fontSizeDefault = 13.0;

/// Clamp bounds for the terminal font size — mirrors the PWA `FONT_SIZE`
/// constant (`{ MIN: 8, MAX: 32 }` in `src/modules/constants.ts`).
const double kFontSizeMin = 8.0;
const double kFontSizeMax = 32.0;

/// Persisted terminal font size. Synchronous value (defaulted while prefs
/// hydrate) so the terminal can render immediately. `set` clamps to
/// [kFontSizeMin]..[kFontSizeMax] before persisting.
class FontSizeNotifier extends StateNotifier<double> {
  FontSizeNotifier({Future<SharedPreferences>? prefs})
    : _prefs = prefs ?? SharedPreferences.getInstance(),
      super(fontSizeDefault) {
    _hydrate();
  }

  final Future<SharedPreferences> _prefs;

  Future<void> _hydrate() async {
    try {
      final prefs = await _prefs;
      final stored = prefs.getDouble(fontSizePrefKey);
      if (stored != null) {
        final clamped = _clamp(stored);
        if (clamped != state) state = clamped;
      }
    } catch (_) {
      // SharedPreferences may be unavailable under tests without bindings;
      // keep the default in that case.
    }
  }

  static double _clamp(double v) => v.clamp(kFontSizeMin, kFontSizeMax);

  /// Set the font size, clamping out-of-range input. Persists best-effort.
  Future<void> set(double value) async {
    final clamped = _clamp(value);
    state = clamped;
    try {
      final prefs = await _prefs;
      await prefs.setDouble(fontSizePrefKey, clamped);
    } catch (_) {
      // best-effort persistence
    }
  }
}

final fontSizeProvider = StateNotifierProvider<FontSizeNotifier, double>((ref) {
  return FontSizeNotifier();
});

// ── Terminal theme palettes (#552) ────────────────────────────────────────

/// A named terminal palette: a label for the UI + the xterm `TerminalTheme`.
@immutable
class NamedTerminalTheme {
  const NamedTerminalTheme(this.label, this.theme);

  final String label;
  final TerminalTheme theme;
}

/// The 16 ANSI colors are not enumerated in the PWA `THEMES` map (the PWA
/// relies on xterm.js defaults for them and only overrides bg/fg/cursor/
/// selection). We reuse the xterm.dart default ANSI set so the ported
/// palettes match the PWA's effective rendering, overriding only the fields
/// the PWA themes actually specify.
TerminalTheme _ansi({
  required Color background,
  required Color foreground,
  required Color cursor,
  required Color selection,
  Color? white,
  Color? brightWhite,
}) {
  return TerminalTheme(
    cursor: cursor,
    selection: selection,
    foreground: foreground,
    background: background,
    black: const Color(0XFF000000),
    red: const Color(0XFFCD3131),
    green: const Color(0XFF0DBC79),
    yellow: const Color(0XFFE5E510),
    blue: const Color(0XFF2472C8),
    magenta: const Color(0XFFBC3FBC),
    cyan: const Color(0XFF11A8CD),
    white: white ?? const Color(0XFFE5E5E5),
    brightBlack: const Color(0XFF666666),
    brightRed: const Color(0XFFF14C4C),
    brightGreen: const Color(0XFF23D18B),
    brightYellow: const Color(0XFFF5F543),
    brightBlue: const Color(0XFF3B8EEA),
    brightMagenta: const Color(0XFFD670D6),
    brightCyan: const Color(0XFF29B8DB),
    brightWhite: brightWhite ?? const Color(0XFFFFFFFF),
    searchHitBackground: const Color(0XFFFFFF2B),
    searchHitBackgroundCurrent: const Color(0XFF31FF26),
    searchHitForeground: const Color(0XFF000000),
  );
}

/// Hex `#rrggbb` (PWA format) → opaque [Color].
Color _hex(String rgb) {
  final v = int.parse(rgb.replaceFirst('#', ''), radix: 16);
  return Color(0xFF000000 | v);
}

/// Hex `#rrggbbaa` (PWA selection format, e.g. `#00ff8844`) → [Color].
Color _hexa(String rgba) {
  final s = rgba.replaceFirst('#', '');
  final rgb = int.parse(s.substring(0, 6), radix: 16);
  final a = int.parse(s.substring(6, 8), radix: 16);
  return Color((a << 24) | rgb);
}

/// Ported terminal palettes (#552). Mapped from the PWA `THEMES` map in
/// `src/modules/terminal.ts`. Keep this list ordered and extensible — adding
/// a palette is a one-line append, and the theme-cycle menu item wraps over
/// the whole list. Slice 2 (#552 notes) adds the remaining PWA palettes.
final List<NamedTerminalTheme> terminalPalettes = [
  // PWA `dark`
  NamedTerminalTheme(
    'Dark',
    _ansi(
      background: _hex('#000000'),
      foreground: _hex('#e0e0e0'),
      cursor: _hex('#00ff88'),
      selection: _hexa('#00ff8844'),
    ),
  ),
  // PWA `solarizedDark`
  NamedTerminalTheme(
    'Solarized Dark',
    _ansi(
      background: _hex('#002b36'),
      foreground: _hex('#839496'),
      cursor: _hex('#268bd2'),
      selection: _hexa('#268bd244'),
    ),
  ),
];

/// SharedPreferences key for the selected terminal palette index.
const String terminalThemePrefKey = 'mobissh.ui.terminalThemeIndex';

/// Default palette index (0 → 'Dark', matching the PWA default theme).
const int terminalThemeDefault = 0;

/// Persisted index into [terminalPalettes]. `cycle` advances to the next
/// palette, wrapping at the end. Out-of-range stored values fall back to the
/// default so a removed palette never crashes the terminal.
class TerminalThemeNotifier extends StateNotifier<int> {
  TerminalThemeNotifier({Future<SharedPreferences>? prefs})
    : _prefs = prefs ?? SharedPreferences.getInstance(),
      super(terminalThemeDefault) {
    _hydrate();
  }

  final Future<SharedPreferences> _prefs;

  Future<void> _hydrate() async {
    try {
      final prefs = await _prefs;
      final stored = prefs.getInt(terminalThemePrefKey);
      if (stored != null && _valid(stored) && stored != state) {
        state = stored;
      }
    } catch (_) {
      // keep default if prefs unavailable
    }
  }

  static bool _valid(int i) => i >= 0 && i < terminalPalettes.length;

  Future<void> _persist(int value) async {
    try {
      final prefs = await _prefs;
      await prefs.setInt(terminalThemePrefKey, value);
    } catch (_) {
      // best-effort persistence
    }
  }

  /// Select a palette by index (clamped to valid range).
  Future<void> set(int index) async {
    final next = _valid(index) ? index : terminalThemeDefault;
    state = next;
    await _persist(next);
  }

  /// Advance to the next palette, wrapping at the end.
  Future<void> cycle() => set((state + 1) % terminalPalettes.length);
}

final terminalThemeProvider = StateNotifierProvider<TerminalThemeNotifier, int>(
  (ref) {
    return TerminalThemeNotifier();
  },
);

/// Convenience: the currently-selected [NamedTerminalTheme]. Guards against a
/// stale out-of-range index by falling back to the default palette.
final activeTerminalThemeProvider = Provider<NamedTerminalTheme>((ref) {
  final index = ref.watch(terminalThemeProvider);
  if (index < 0 || index >= terminalPalettes.length) {
    return terminalPalettes[terminalThemeDefault];
  }
  return terminalPalettes[index];
});
