import 'dart:convert';
import 'dart:typed_data';

import 'package:flterm/flterm.dart';
import 'package:flutter/material.dart';

class DemoPage extends StatefulWidget {
  final TerminalTheme? theme;

  const DemoPage({super.key, this.theme});

  @override
  State<DemoPage> createState() => _DemoPageState();
}

class _DemoPageState extends State<DemoPage> {
  late final _controller = TerminalController();

  @override
  Widget build(BuildContext context) {
    return ExcludeFocus(
      child: TerminalView(
        controller: _controller,
        theme: widget.theme ?? TerminalTheme.dark(),
        showKeyboard: false,
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _writeDemoContent();
  }

  void _write(String value) => _controller.write(.fromList(utf8.encode(value)));

  void _write256Cube() {
    for (var g = 0; g < 6; g++) {
      _write('  ');
      for (var r = 0; r < 6; r++) {
        for (var b = 0; b < 6; b++) {
          final c = 16 + 36 * r + 6 * g + b;
          _write('\x1b[48;5;${c}m  \x1b[0m');
        }
        _write(' ');
      }
      _write('\r\n');
    }
  }

  void _writeAnsi16() {
    _write('  ANSI:       ');
    for (var i = 0; i < 8; i++) {
      _write('\x1b[${40 + i}m  \x1b[0m');
    }
    _write(' ');
    for (var i = 0; i < 8; i++) {
      _write('\x1b[${100 + i}m  \x1b[0m');
    }
    _write('  ');
    for (var i = 0; i < 8; i++) {
      _write('\x1b[1;${30 + i}m▓▓\x1b[0m');
    }
    _write('\r\n');
  }

  void _writeBoxDrawing() {
    _write('  Box:    ┌────────┐  Blocks: █▓▒░  ▌▐▄▀  ');
    _write('Braille: ⠁⠃⠇⡇⣇⣷⣿\r\n');
    _write('          │ ghostty│  Geom:   ■□●○◆◇▲▶▷  ');
    _write('Arrows:  ←↑→↓↔↕↖↗\r\n');
    _write('          └────────┘\r\n');
  }

  void _writeBytes(List<int> bytes) =>
      _controller.write(Uint8List.fromList(bytes));

  void _writeDecorations() {
    _write('  Decor:      ');
    _write('\x1b[9mStrike\x1b[0m ');
    _write('\x1b[53mOverline\x1b[0m ');
    _write('\x1b[4;9mUnder+Strike\x1b[0m ');
    _write('\x1b[4m\x1b[58;2;255;80;80mRed underline\x1b[0m\r\n');
  }

  void _writeDemoContent() {
    _write('\x1b[2J\x1b[H');
    _writeHeader('flterm rendering demo');
    _writeTextStyles();
    _writeUnderlines();
    _writeDecorations();
    _writeAnsi16();
    _write('\r\n');
    _writeSection('256-color cube');
    _write256Cube();
    _writeGrayscale();
    _write('\r\n');
    _writeSection('Truecolor (24-bit)');
    _writeTrueColorGradient();
    _write('\r\n');
    _writeSection('Unicode');
    _writeUnicode();
    _writeBoxDrawing();
    _writePowerline();
    _write('\r\n');
    _writeSection('Hyperlinks');
    _writeHyperlinks();
  }

  void _writeGrayscale() {
    _write('  ');
    for (var i = 232; i < 256; i++) {
      _write('\x1b[48;5;${i}m  \x1b[0m');
    }
    _write('\r\n');
  }

  void _writeHeader(String title) {
    _write('\x1b[1;38;5;81m  $title\x1b[0m\r\n');
    _write('  ${'─' * (title.length + 2)}\r\n\r\n');
  }

  void _writeHyperlinks() {
    _write('  ');
    _writeOsc8('https://ghostty.org', 'Ghostty');
    _write('   ');
    _writeOsc8('https://flutter.dev', 'Flutter');
    _write('   ');
    _writeOsc8('https://dart.dev', 'Dart');
    _write('\r\n');
  }

  void _writeOsc8(String url, String label) {
    _write('\x1b]8;;$url\x1b\\');
    _write('\x1b[4;38;5;75m$label\x1b[0m');
    _write('\x1b]8;;\x1b\\');
  }

  void _writePowerline() {
    _write('  Power:  ');
    _write('\x1b[44;37m  main \x1b[0m');
    _writeBytes([0xEE, 0x82, 0xB0]);
    _write('\x1b[30;42m src/demo.dart \x1b[0m');
    _writeBytes([0xEE, 0x82, 0xB0]);
    _write('\x1b[37;40m\r\n');
  }

  void _writeSection(String title) {
    _write('\x1b[2;37m  $title\x1b[0m\r\n');
  }

  void _writeTextStyles() {
    _write('  Styles:     ');
    _write('\x1b[1mBold\x1b[0m ');
    _write('\x1b[3mItalic\x1b[0m ');
    _write('\x1b[2mFaint\x1b[0m ');
    _write('\x1b[7mInverse\x1b[0m ');
    _write('\x1b[1;3mBold+Italic\x1b[0m\r\n');
  }

  void _writeTrueColorGradient() {
    const width = 72;
    _write('  ');
    for (var i = 0; i < width; i++) {
      final t = i / (width - 1);
      final r = (255 * (1 - t)).round();
      final g = (255 * (1 - (t - 0.5).abs() * 2)).round().clamp(0, 255);
      final b = (255 * t).round();
      _write('\x1b[48;2;$r;$g;${b}m \x1b[0m');
    }
    _write('\r\n');
  }

  void _writeUnderlines() {
    _write('  Underline:  ');
    _write('\x1b[4mSingle\x1b[0m ');
    _write('\x1b[4:2mDouble\x1b[0m ');
    _write('\x1b[4:3mCurly\x1b[0m ');
    _write('\x1b[4:4mDotted\x1b[0m ');
    _write('\x1b[4:5mDashed\x1b[0m\r\n');
  }

  void _writeUnicode() {
    _write('  CJK:    日本語  中文  한국어    Emoji: 🦀 🚀 ✨ 🎨 ⚡\r\n');
  }
}
