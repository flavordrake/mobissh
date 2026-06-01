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

import 'sessions.dart';

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

// ── Compose bar / IME editor (#599) ───────────────────────────────────────

/// SharedPreferences key for the compose-bar (IME editor) visibility.
const String composeBarVisiblePrefKey = 'mobissh.ui.composeBarVisible';

/// Default OFF — the compose bar is an opt-in surface (the terminal still
/// accepts hardware-keyboard / keybar input without it). Turned on from the
/// session menu. When on, it's the swipe/voice/IME composing surface (xterm's
/// own input disables composing, so swipe-typing + voice need this editable).
const bool composeBarVisibleDefault = false;

/// User toggle for the compose bar (IME editor). Mirrors [KeybarVisibleNotifier].
class ComposeBarVisibleNotifier extends StateNotifier<bool> {
  ComposeBarVisibleNotifier({Future<SharedPreferences>? prefs})
    : _prefs = prefs ?? SharedPreferences.getInstance(),
      super(composeBarVisibleDefault) {
    _hydrate();
  }

  final Future<SharedPreferences> _prefs;

  Future<void> _hydrate() async {
    try {
      final prefs = await _prefs;
      final stored = prefs.getBool(composeBarVisiblePrefKey);
      if (stored != null && stored != state) state = stored;
    } catch (_) {
      // best-effort; keep default if prefs unavailable (tests).
    }
  }

  Future<void> set(bool value) async {
    state = value;
    try {
      final prefs = await _prefs;
      await prefs.setBool(composeBarVisiblePrefKey, value);
    } catch (_) {
      // best-effort persistence
    }
  }

  void toggle() => set(!state);
}

final composeBarVisibleProvider =
    StateNotifierProvider<ComposeBarVisibleNotifier, bool>((ref) {
      return ComposeBarVisibleNotifier();
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

/// Step (logical px) for the session-menu font-size −/＋ stepper (#601).
const double kFontSizeStep = 1.0;

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
  const NamedTerminalTheme(this.key, this.label, this.theme);

  /// The PWA `ThemeName` (e.g. 'dark', 'dracula', 'tokyoNight') — the stable
  /// identity that makes a profile's saved/imported `theme` mappable to a native
  /// palette via [paletteIndexForThemeName]. Mirrors the object KEY in the PWA
  /// `THEMES` map (src/modules/constants.ts).
  final String key;

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

/// Ported terminal palettes (#552, #613). Mapped from the PWA `THEMES` map in
/// `src/modules/constants.ts` (the AUTHORITATIVE source), ordered to match
/// `THEME_ORDER`. Each entry carries the PWA `ThemeName` as its [key] so a
/// profile's saved/imported `theme` is mappable to a palette via
/// [paletteIndexForThemeName]. Only the fields the PWA themes actually specify
/// (background/foreground/cursor/selectionBackground + optional white/
/// brightWhite on light themes) are overridden; the rest reuse the xterm.dart
/// default ANSI set (see [_ansi]). The PWA `app:` chrome block is intentionally
/// ignored (it styles the PWA shell, not the terminal). Adding a palette is a
/// one-line append; the theme-cycle wraps over the whole list.
final List<NamedTerminalTheme> terminalPalettes = [
  NamedTerminalTheme(
    'dark',
    'Dark',
    _ansi(
      background: _hex('#000000'),
      foreground: _hex('#e0e0e0'),
      cursor: _hex('#00ff88'),
      selection: _hexa('#00ff8844'),
    ),
  ),
  NamedTerminalTheme(
    'light',
    'Light',
    _ansi(
      background: _hex('#ffffff'),
      foreground: _hex('#1a1a1a'),
      cursor: _hex('#0055cc'),
      selection: _hexa('#0055cc44'),
      white: _hex('#e8e8ec'),
      brightWhite: _hex('#d8d8df'),
    ),
  ),
  NamedTerminalTheme(
    'solarizedDark',
    'Solarized Dark',
    _ansi(
      background: _hex('#002b36'),
      foreground: _hex('#839496'),
      cursor: _hex('#268bd2'),
      selection: _hexa('#268bd244'),
    ),
  ),
  NamedTerminalTheme(
    'solarizedLight',
    'Solarized Light',
    _ansi(
      background: _hex('#fdf6e3'),
      foreground: _hex('#657b83'),
      cursor: _hex('#268bd2'),
      selection: _hexa('#268bd244'),
      white: _hex('#eee8d5'),
      brightWhite: _hex('#d3c8a8'),
    ),
  ),
  NamedTerminalTheme(
    'highContrast',
    'High Contrast',
    _ansi(
      background: _hex('#000000'),
      foreground: _hex('#ffffff'),
      cursor: _hex('#ffff00'),
      selection: _hexa('#ffff0044'),
    ),
  ),
  NamedTerminalTheme(
    'highContrastLight',
    'High Contrast Light',
    _ansi(
      background: _hex('#ffffff'),
      foreground: _hex('#000000'),
      cursor: _hex('#0000ff'),
      selection: _hexa('#0000ff44'),
      white: _hex('#e0e0e0'),
      brightWhite: _hex('#c0c0c0'),
    ),
  ),
  NamedTerminalTheme(
    'dracula',
    'Dracula',
    _ansi(
      background: _hex('#282a36'),
      foreground: _hex('#f8f8f2'),
      cursor: _hex('#f8f8f2'),
      selection: _hex('#44475a'),
    ),
  ),
  NamedTerminalTheme(
    'draculaLight',
    'Dracula Light',
    _ansi(
      background: _hex('#f8f8f2'),
      foreground: _hex('#282a36'),
      cursor: _hex('#bd93f9'),
      selection: _hexa('#bd93f944'),
      white: _hex('#e8e8e0'),
      brightWhite: _hex('#d8d8d0'),
    ),
  ),
  NamedTerminalTheme(
    'nord',
    'Nord',
    _ansi(
      background: _hex('#2e3440'),
      foreground: _hex('#d8dee9'),
      cursor: _hex('#d8dee9'),
      selection: _hex('#434c5e'),
    ),
  ),
  NamedTerminalTheme(
    'nordLight',
    'Nord Light',
    _ansi(
      background: _hex('#eceff4'),
      foreground: _hex('#2e3440'),
      cursor: _hex('#5e81ac'),
      selection: _hexa('#5e81ac33'),
      white: _hex('#dde2e8'),
      brightWhite: _hex('#c8d0d8'),
    ),
  ),
  NamedTerminalTheme(
    'gruvboxDark',
    'Gruvbox Dark',
    _ansi(
      background: _hex('#282828'),
      foreground: _hex('#ebdbb2'),
      cursor: _hex('#ebdbb2'),
      selection: _hex('#504945'),
    ),
  ),
  NamedTerminalTheme(
    'gruvboxLight',
    'Gruvbox Light',
    _ansi(
      background: _hex('#fbf1c7'),
      foreground: _hex('#3c3836'),
      cursor: _hex('#9d0006'),
      selection: _hexa('#9d000633'),
      white: _hex('#ebdbb2'),
      brightWhite: _hex('#d5c4a1'),
    ),
  ),
  NamedTerminalTheme(
    'monokai',
    'Monokai',
    _ansi(
      background: _hex('#272822'),
      foreground: _hex('#f8f8f2'),
      cursor: _hex('#f8f8f2'),
      selection: _hex('#49483e'),
    ),
  ),
  NamedTerminalTheme(
    'monokaiLight',
    'Monokai Light',
    _ansi(
      background: _hex('#fafafa'),
      foreground: _hex('#272822'),
      cursor: _hex('#75af00'),
      selection: _hexa('#75af0033'),
      white: _hex('#e8e8e0'),
      brightWhite: _hex('#d0d0c8'),
    ),
  ),
  NamedTerminalTheme(
    'tokyoNight',
    'Tokyo Night',
    _ansi(
      background: _hex('#1a1b26'),
      foreground: _hex('#a9b1d6'),
      cursor: _hex('#c0caf5'),
      selection: _hex('#33467c'),
    ),
  ),
  NamedTerminalTheme(
    'tokyoNightDay',
    'Tokyo Night Day',
    _ansi(
      background: _hex('#e1e2e7'),
      foreground: _hex('#3760bf'),
      cursor: _hex('#2e7de9'),
      selection: _hexa('#2e7de933'),
      white: _hex('#cfd0d6'),
      brightWhite: _hex('#b8b9c0'),
    ),
  ),
  NamedTerminalTheme(
    'ocean',
    'Ocean',
    _ansi(
      background: _hex('#050d18'),
      foreground: _hex('#b2d8f0'),
      cursor: _hex('#00bcd4'),
      selection: _hexa('#00bcd444'),
    ),
  ),
  NamedTerminalTheme(
    'oceanLight',
    'Ocean Light',
    _ansi(
      background: _hex('#e8f4fa'),
      foreground: _hex('#0d3b54'),
      cursor: _hex('#00838f'),
      selection: _hexa('#00838f33'),
      white: _hex('#d0e4ee'),
      brightWhite: _hex('#b6cfdc'),
    ),
  ),
  NamedTerminalTheme(
    'ember',
    'Ember',
    _ansi(
      background: _hex('#1a0a0a'),
      foreground: _hex('#f0c8b0'),
      cursor: _hex('#ff5722'),
      selection: _hexa('#ff572244'),
    ),
  ),
  NamedTerminalTheme(
    'emberLight',
    'Ember Light',
    _ansi(
      background: _hex('#fdf2eb'),
      foreground: _hex('#5a2410'),
      cursor: _hex('#d84315'),
      selection: _hexa('#d8431533'),
      white: _hex('#f5e2d3'),
      brightWhite: _hex('#e8cab2'),
    ),
  ),
  NamedTerminalTheme(
    'forest',
    'Forest',
    _ansi(
      background: _hex('#0a1a0a'),
      foreground: _hex('#b8d8b0'),
      cursor: _hex('#4caf50'),
      selection: _hexa('#4caf5044'),
    ),
  ),
  NamedTerminalTheme(
    'forestLight',
    'Forest Light',
    _ansi(
      background: _hex('#f0f5ec'),
      foreground: _hex('#1b3a1b'),
      cursor: _hex('#2e7d32'),
      selection: _hexa('#2e7d3233'),
      white: _hex('#dfe9da'),
      brightWhite: _hex('#c5d3bd'),
    ),
  ),
  NamedTerminalTheme(
    'sunset',
    'Sunset',
    _ansi(
      background: _hex('#1a0f1e'),
      foreground: _hex('#e8c8e0'),
      cursor: _hex('#ff9800'),
      selection: _hexa('#ff980044'),
    ),
  ),
  NamedTerminalTheme(
    'sunsetLight',
    'Sunset Light',
    _ansi(
      background: _hex('#fdf3ea'),
      foreground: _hex('#4a2510'),
      cursor: _hex('#e65100'),
      selection: _hexa('#e6510033'),
      white: _hex('#f4e2d4'),
      brightWhite: _hex('#e8c9b3'),
    ),
  ),
  NamedTerminalTheme(
    'synthwave',
    'Synthwave',
    _ansi(
      background: _hex('#0f0a1a'),
      foreground: _hex('#e0d0f0'),
      cursor: _hex('#ff00ff'),
      selection: _hexa('#ff00ff33'),
    ),
  ),
  NamedTerminalTheme(
    'synthwaveLight',
    'Synthwave Light',
    _ansi(
      background: _hex('#f5ebff'),
      foreground: _hex('#3a1058'),
      cursor: _hex('#c800c8'),
      selection: _hexa('#c800c833'),
      white: _hex('#e3d4f2'),
      brightWhite: _hex('#cdb6e3'),
    ),
  ),
  NamedTerminalTheme(
    'commodore',
    'Commodore',
    _ansi(
      background: _hex('#3a3ac8'),
      foreground: _hex('#ffffff'),
      cursor: _hex('#ffff55'),
      selection: _hexa('#ffffff44'),
    ),
  ),
  NamedTerminalTheme(
    'commodoreLight',
    'Commodore Light',
    _ansi(
      background: _hex('#d8d8e8'),
      foreground: _hex('#2828a0'),
      cursor: _hex('#a83a3a'),
      selection: _hexa('#a83a3a33'),
      white: _hex('#c8c8d8'),
      brightWhite: _hex('#b0b0c8'),
    ),
  ),
  NamedTerminalTheme(
    'terminal',
    'Terminal',
    _ansi(
      background: _hex('#21388a'),
      foreground: _hex('#ffffff'),
      cursor: _hex('#ffffff'),
      selection: _hexa('#ffffff44'),
    ),
  ),
  NamedTerminalTheme(
    'terminalLight',
    'Terminal Light',
    _ansi(
      background: _hex('#e8edf8'),
      foreground: _hex('#192c70'),
      cursor: _hex('#9c6800'),
      selection: _hexa('#9c680033'),
      white: _hex('#d2dbeb'),
      brightWhite: _hex('#b8c5dc'),
    ),
  ),
  NamedTerminalTheme(
    'borland',
    'Borland',
    _ansi(
      background: _hex('#0000aa'),
      foreground: _hex('#ffff55'),
      cursor: _hex('#ffffff'),
      selection: _hex('#00aaaa'),
    ),
  ),
  NamedTerminalTheme(
    'borlandLight',
    'Borland Light',
    _ansi(
      background: _hex('#fff8d8'),
      foreground: _hex('#000088'),
      cursor: _hex('#005577'),
      selection: _hexa('#00aaaa55'),
      white: _hex('#f0e8c0'),
      brightWhite: _hex('#d8cfa0'),
    ),
  ),
  NamedTerminalTheme(
    'arcticDark',
    'Arctic Dark',
    _ansi(
      background: _hex('#0a1828'),
      foreground: _hex('#a8c8e8'),
      cursor: _hex('#3399ff'),
      selection: _hexa('#3399ff33'),
    ),
  ),
  NamedTerminalTheme(
    'arctic',
    'Arctic',
    _ansi(
      background: _hex('#e8f0f8'),
      foreground: _hex('#1a3050'),
      cursor: _hex('#0066cc'),
      selection: _hexa('#0066cc33'),
    ),
  ),
  NamedTerminalTheme(
    'cobalt',
    'Cobalt',
    _ansi(
      background: _hex('#002240'),
      foreground: _hex('#ffffff'),
      cursor: _hex('#ffcc00'),
      selection: _hexa('#ffcc0033'),
    ),
  ),
  NamedTerminalTheme(
    'cobaltLight',
    'Cobalt Light',
    _ansi(
      background: _hex('#e6f1fb'),
      foreground: _hex('#002240'),
      cursor: _hex('#a87600'),
      selection: _hexa('#a8760033'),
      white: _hex('#cfdfee'),
      brightWhite: _hex('#b5cadd'),
    ),
  ),
  NamedTerminalTheme(
    'matrix',
    'Matrix',
    _ansi(
      background: _hex('#000800'),
      foreground: _hex('#00ff41'),
      cursor: _hex('#00ff41'),
      selection: _hexa('#00ff4133'),
    ),
  ),
  NamedTerminalTheme(
    'matrixLight',
    'Matrix Light',
    _ansi(
      background: _hex('#f0fff0'),
      foreground: _hex('#003300'),
      cursor: _hex('#008822'),
      selection: _hexa('#00882233'),
      white: _hex('#daefdc'),
      brightWhite: _hex('#bcd9c1'),
    ),
  ),
];

/// PWA→native theme map (#613): resolve a profile's `theme` (a PWA `ThemeName`)
/// to an index into [terminalPalettes]. Unknown or null names fall back to the
/// default palette ([terminalThemeDefault], index 0 → 'dark') so a stale/typo
/// theme never crashes the session.
int paletteIndexForThemeName(String? name) {
  if (name == null) return terminalThemeDefault;
  final i = terminalPalettes.indexWhere((p) => p.key == name);
  return i >= 0 ? i : terminalThemeDefault;
}

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

/// Convenience: the currently-selected GLOBAL [NamedTerminalTheme]. Guards
/// against a stale out-of-range index by falling back to the default palette.
///
/// NOTE (#601/#571): this resolves the *global* default theme. The terminal
/// screen and session menu now read the PER-SESSION palette via
/// [activeSessionThemeProvider]; this provider is retained as the source of the
/// default a brand-new session inherits.
final activeTerminalThemeProvider = Provider<NamedTerminalTheme>((ref) {
  final index = ref.watch(terminalThemeProvider);
  if (index < 0 || index >= terminalPalettes.length) {
    return terminalPalettes[terminalThemeDefault];
  }
  return terminalPalettes[index];
});

// ── Per-session terminal appearance (#601, #571) ──────────────────────────
//
// The owner wants to differentiate sessions: prod = small + one theme, dev =
// large + another. So terminal theme + font size are PER-SESSION (keyed by
// session id), NOT global. Changing one session's theme/font leaves every
// other session UNCHANGED (isolation — memory: feedback_feature_scoping_and_
// isolation_tests). A NEW session inherits the persisted global default (the
// last-used theme/font, hydrated by [TerminalThemeNotifier]/[FontSizeNotifier]
// from SharedPreferences) — it does NOT copy a live sibling's values.
//
// Per-session values live in-memory only: session ids carry a `createdAtMs`
// suffix, so they are ephemeral by construction (a session never survives a
// relaunch). The DEFAULT for new sessions is what persists, via the existing
// global notifiers — that's the knob worth remembering across launches.

/// Immutable per-session terminal appearance: which palette index + the font
/// size in logical px. Both are clamped/validated by the notifier before they
/// land here.
@immutable
class SessionAppearance {
  const SessionAppearance({required this.themeIndex, required this.fontSize});

  final int themeIndex;
  final double fontSize;

  SessionAppearance copyWith({int? themeIndex, double? fontSize}) {
    return SessionAppearance(
      themeIndex: themeIndex ?? this.themeIndex,
      fontSize: fontSize ?? this.fontSize,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SessionAppearance &&
      other.themeIndex == themeIndex &&
      other.fontSize == fontSize;

  @override
  int get hashCode => Object.hash(themeIndex, fontSize);
}

/// Owns the per-session appearance map (sessionId → [SessionAppearance]).
///
/// A session not yet in the map is treated as carrying the current global
/// default ([_default]); the first mutation materializes its entry. Mutations
/// touch ONLY the named session's entry, so sibling sessions never change —
/// and they deliberately do NOT clobber the global default, so a per-session
/// tweak never changes what the next NEW session inherits.
class SessionAppearanceNotifier
    extends Notifier<Map<String, SessionAppearance>> {
  @override
  Map<String, SessionAppearance> build() => const {};

  /// The default a session without an explicit entry carries. Seeded from the
  /// persisted global theme/font notifiers so a new session inherits the
  /// last-used values rather than a hardcoded constant.
  SessionAppearance get _default => SessionAppearance(
    themeIndex: ref.read(terminalThemeProvider),
    fontSize: ref.read(fontSizeProvider),
  );

  /// Read a session's appearance, falling back to the current default for a
  /// session that hasn't been customized yet.
  SessionAppearance appearanceOf(String sessionId) =>
      state[sessionId] ?? _default;

  static int _validTheme(int i) =>
      (i >= 0 && i < terminalPalettes.length) ? i : terminalThemeDefault;

  static double _clampFont(double v) => v.clamp(kFontSizeMin, kFontSizeMax);

  void _put(String sessionId, SessionAppearance next) {
    state = {...state, sessionId: next};
  }

  /// Set [sessionId]'s palette index (clamped to a valid index). Affects only
  /// this session — sibling sessions and the global default are untouched.
  void setTheme(String sessionId, int index) {
    final i = _validTheme(index);
    _put(sessionId, appearanceOf(sessionId).copyWith(themeIndex: i));
  }

  /// Advance [sessionId]'s palette to the next one, wrapping at the end.
  void cycleTheme(String sessionId) {
    final cur = appearanceOf(sessionId).themeIndex;
    setTheme(sessionId, (cur + 1) % terminalPalettes.length);
  }

  /// Set [sessionId]'s font size (clamped). Affects only this session — sibling
  /// sessions and the global default are untouched.
  void setFontSize(String sessionId, double size) {
    final s = _clampFont(size);
    _put(sessionId, appearanceOf(sessionId).copyWith(fontSize: s));
  }

  /// Step [sessionId]'s font size by [delta] logical px (clamped).
  void adjustFontSize(String sessionId, double delta) {
    setFontSize(sessionId, appearanceOf(sessionId).fontSize + delta);
  }
}

final sessionAppearanceProvider =
    NotifierProvider<SessionAppearanceNotifier, Map<String, SessionAppearance>>(
      SessionAppearanceNotifier.new,
    );

/// Per-session palette index. Falls back to the current default for an
/// un-customized session. Rebuilds when that session's entry changes.
final sessionThemeProvider = Provider.family<int, String>((ref, sessionId) {
  ref.watch(sessionAppearanceProvider);
  return ref
      .read(sessionAppearanceProvider.notifier)
      .appearanceOf(sessionId)
      .themeIndex;
});

/// Per-session font size. Falls back to the current default for an
/// un-customized session.
final sessionFontSizeProvider = Provider.family<double, String>((
  ref,
  sessionId,
) {
  ref.watch(sessionAppearanceProvider);
  return ref
      .read(sessionAppearanceProvider.notifier)
      .appearanceOf(sessionId)
      .fontSize;
});

/// The [NamedTerminalTheme] for a given session, guarding a stale index.
final sessionTerminalThemeProvider =
    Provider.family<NamedTerminalTheme, String>((ref, sessionId) {
      final index = ref.watch(sessionThemeProvider(sessionId));
      if (index < 0 || index >= terminalPalettes.length) {
        return terminalPalettes[terminalThemeDefault];
      }
      return terminalPalettes[index];
    });

/// The ACTIVE session's [NamedTerminalTheme] — what the session menu's Theme
/// row label reflects. Falls back to the global default when no session is
/// active.
final activeSessionThemeProvider = Provider<NamedTerminalTheme>((ref) {
  final activeId = ref.watch(activeSessionIdProvider);
  if (activeId == null) return ref.watch(activeTerminalThemeProvider);
  return ref.watch(sessionTerminalThemeProvider(activeId));
});

/// The ACTIVE session's font size — what the session menu's font stepper shows.
/// Falls back to the global default when no session is active.
final activeSessionFontSizeProvider = Provider<double>((ref) {
  final activeId = ref.watch(activeSessionIdProvider);
  if (activeId == null) return ref.watch(fontSizeProvider);
  return ref.watch(sessionFontSizeProvider(activeId));
});
