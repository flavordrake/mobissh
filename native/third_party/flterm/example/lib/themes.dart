import 'dart:ui';

import 'package:flterm/flterm.dart';

abstract final class TerminalThemes {
  static final adventure = TerminalTheme(
    palette: ColorPalette(
      background: const Color(0xFF040404),
      foreground: const Color(0xFFFEFFFF),
      ansiColors: const [
        Color(0xFF040404),
        Color(0xFFD84A33),
        Color(0xFF5DA602),
        Color(0xFFEEBB6E),
        Color(0xFF417AB3),
        Color(0xFFE5C499),
        Color(0xFFBDCFE5),
        Color(0xFFDBDED8),
        Color(0xFF685656),
        Color(0xFFD76B42),
        Color(0xFF99B52C),
        Color(0xFFFFB670),
        Color(0xFF97D7EF),
        Color(0xFFAA7900),
        Color(0xFFBDCFE5),
        Color(0xFFE4D5C7),
      ],
    ),
  );

  static final ghostty = TerminalTheme(
    palette: ColorPalette(
      background: const Color(0xFF282C34),
      foreground: const Color(0xFFFFFFFF),
      ansiColors: const [
        Color(0xFF1D1F21),
        Color(0xFFCC6666),
        Color(0xFFB5BD68),
        Color(0xFFF0C674),
        Color(0xFF81A2BE),
        Color(0xFFB294BB),
        Color(0xFF8ABEB7),
        Color(0xFFC5C8C6),
        Color(0xFF666666),
        Color(0xFFD54E53),
        Color(0xFFB9CA4A),
        Color(0xFFE7C547),
        Color(0xFF7AA6DA),
        Color(0xFFC397D8),
        Color(0xFF70C0B1),
        Color(0xFFEAEAEA),
      ],
    ),
  );

  static final dracula = TerminalTheme(
    palette: ColorPalette(
      background: const Color(0xFF282A36),
      foreground: const Color(0xFFF8F8F2),
      ansiColors: const [
        Color(0xFF21222C),
        Color(0xFFFF5555),
        Color(0xFF50FA7B),
        Color(0xFFF1FA8C),
        Color(0xFFBD93F9),
        Color(0xFFFF79C6),
        Color(0xFF8BE9FD),
        Color(0xFFF8F8F2),
        Color(0xFF6272A4),
        Color(0xFFFF6E6E),
        Color(0xFF69FF94),
        Color(0xFFFFFFA5),
        Color(0xFFD6ACFF),
        Color(0xFFFF92DF),
        Color(0xFFA4FFFF),
        Color(0xFFFFFFFF),
      ],
    ),
  );

  static final oneDark = TerminalTheme(
    palette: ColorPalette(
      background: const Color(0xFF282C34),
      foreground: const Color(0xFFABB2BF),
      ansiColors: const [
        Color(0xFF282C34),
        Color(0xFFE06C75),
        Color(0xFF98C379),
        Color(0xFFE5C07B),
        Color(0xFF61AFEF),
        Color(0xFFC678DD),
        Color(0xFF56B6C2),
        Color(0xFFABB2BF),
        Color(0xFF545862),
        Color(0xFFE06C75),
        Color(0xFF98C379),
        Color(0xFFE5C07B),
        Color(0xFF61AFEF),
        Color(0xFFC678DD),
        Color(0xFF56B6C2),
        Color(0xFFFFFFFF),
      ],
    ),
  );

  static final catppuccinMocha = TerminalTheme(
    palette: ColorPalette(
      background: const Color(0xFF1E1E2E),
      foreground: const Color(0xFFCDD6F4),
      ansiColors: const [
        Color(0xFF45475A),
        Color(0xFFF38BA8),
        Color(0xFFA6E3A1),
        Color(0xFFF9E2AF),
        Color(0xFF89B4FA),
        Color(0xFFF5C2E7),
        Color(0xFF94E2D5),
        Color(0xFFBAC2DE),
        Color(0xFF585B70),
        Color(0xFFF38BA8),
        Color(0xFFA6E3A1),
        Color(0xFFF9E2AF),
        Color(0xFF89B4FA),
        Color(0xFFF5C2E7),
        Color(0xFF94E2D5),
        Color(0xFFA6ADC8),
      ],
    ),
  );

  static final nord = TerminalTheme(
    palette: ColorPalette(
      background: const Color(0xFF2E3440),
      foreground: const Color(0xFFD8DEE9),
      ansiColors: const [
        Color(0xFF3B4252),
        Color(0xFFBF616A),
        Color(0xFFA3BE8C),
        Color(0xFFEBCB8B),
        Color(0xFF81A1C1),
        Color(0xFFB48EAD),
        Color(0xFF88C0D0),
        Color(0xFFE5E9F0),
        Color(0xFF4C566A),
        Color(0xFFBF616A),
        Color(0xFFA3BE8C),
        Color(0xFFEBCB8B),
        Color(0xFF81A1C1),
        Color(0xFFB48EAD),
        Color(0xFF8FBCBB),
        Color(0xFFECEFF4),
      ],
    ),
  );

  static final solarizedDark = TerminalTheme(
    palette: ColorPalette(
      background: const Color(0xFF002B36),
      foreground: const Color(0xFF839496),
      ansiColors: const [
        Color(0xFF073642),
        Color(0xFFDC322F),
        Color(0xFF859900),
        Color(0xFFB58900),
        Color(0xFF268BD2),
        Color(0xFFD33682),
        Color(0xFF2AA198),
        Color(0xFFEEE8D5),
        Color(0xFF002B36),
        Color(0xFFCB4B16),
        Color(0xFF586E75),
        Color(0xFF657B83),
        Color(0xFF839496),
        Color(0xFF6C71C4),
        Color(0xFF93A1A1),
        Color(0xFFFDF6E3),
      ],
    ),
  );

  static final solarizedLight = TerminalTheme(
    palette: ColorPalette(
      background: const Color(0xFFFDF6E3),
      foreground: const Color(0xFF657B83),
      ansiColors: const [
        Color(0xFF073642),
        Color(0xFFDC322F),
        Color(0xFF859900),
        Color(0xFFB58900),
        Color(0xFF268BD2),
        Color(0xFFD33682),
        Color(0xFF2AA198),
        Color(0xFFEEE8D5),
        Color(0xFF002B36),
        Color(0xFFCB4B16),
        Color(0xFF586E75),
        Color(0xFF657B83),
        Color(0xFF839496),
        Color(0xFF6C71C4),
        Color(0xFF93A1A1),
        Color(0xFFFDF6E3),
      ],
    ),
  );

  static final tokyoNight = TerminalTheme(
    palette: ColorPalette(
      background: const Color(0xFF1A1B26),
      foreground: const Color(0xFFC0CAF5),
      ansiColors: const [
        Color(0xFF15161E),
        Color(0xFFF7768E),
        Color(0xFF9ECE6A),
        Color(0xFFE0AF68),
        Color(0xFF7AA2F7),
        Color(0xFFBB9AF7),
        Color(0xFF7DCFFF),
        Color(0xFFA9B1D6),
        Color(0xFF414868),
        Color(0xFFF7768E),
        Color(0xFF9ECE6A),
        Color(0xFFE0AF68),
        Color(0xFF7AA2F7),
        Color(0xFFBB9AF7),
        Color(0xFF7DCFFF),
        Color(0xFFC0CAF5),
      ],
    ),
  );

  static final gruvboxDark = TerminalTheme(
    palette: ColorPalette(
      background: const Color(0xFF282828),
      foreground: const Color(0xFFEBDBB2),
      ansiColors: const [
        Color(0xFF282828),
        Color(0xFFCC241D),
        Color(0xFF98971A),
        Color(0xFFD79921),
        Color(0xFF458588),
        Color(0xFFB16286),
        Color(0xFF689D6A),
        Color(0xFFA89984),
        Color(0xFF928374),
        Color(0xFFFB4934),
        Color(0xFFB8BB26),
        Color(0xFFFABD2F),
        Color(0xFF83A598),
        Color(0xFFD3869B),
        Color(0xFF8EC07C),
        Color(0xFFEBDBB2),
      ],
    ),
  );

  static final rosePine = TerminalTheme(
    palette: ColorPalette(
      background: const Color(0xFF191724),
      foreground: const Color(0xFFE0DEF4),
      ansiColors: const [
        Color(0xFF26233A),
        Color(0xFFEB6F92),
        Color(0xFF31748F),
        Color(0xFFF6C177),
        Color(0xFF9CCFD8),
        Color(0xFFC4A7E7),
        Color(0xFFEBBCBA),
        Color(0xFFE0DEF4),
        Color(0xFF6E6A86),
        Color(0xFFEB6F92),
        Color(0xFF31748F),
        Color(0xFFF6C177),
        Color(0xFF9CCFD8),
        Color(0xFFC4A7E7),
        Color(0xFFEBBCBA),
        Color(0xFFE0DEF4),
      ],
    ),
  );

  static final List<({String name, TerminalTheme theme})> all = [
    (name: 'Adventure', theme: adventure),
    (name: 'Ghostty', theme: ghostty),
    (name: 'Dracula', theme: dracula),
    (name: 'One Dark', theme: oneDark),
    (name: 'Catppuccin Mocha', theme: catppuccinMocha),
    (name: 'Nord', theme: nord),
    (name: 'Solarized Dark', theme: solarizedDark),
    (name: 'Solarized Light', theme: solarizedLight),
    (name: 'Tokyo Night', theme: tokyoNight),
    (name: 'Gruvbox Dark', theme: gruvboxDark),
    (name: 'Rose Pine', theme: rosePine),
  ];

  const TerminalThemes._();
}
