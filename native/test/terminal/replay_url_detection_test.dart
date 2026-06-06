@Tags(['ffi'])
library;

// REPLAY-based acceptance: feed a REAL captured tmux grid (scripts/capture-
// terminal-corpus.sh) into a real flterm TerminalController and assert URL
// detection — the structural answer to the +22..+28 saga, where every miss
// shipped green because I validated SYNTHETIC input (printf straight to flterm,
// tmux-autowrap-fills-the-row) instead of the owner's ACTUAL grid (a plain-text
// blue URL the app wraps at its content width, narrower than the terminal, with
// blank padding on the wrapped row).
//
// Headless: the real libghostty VT parser loads under `flutter test` on the host
// VM (ffi-tagged), so `controller.write(bytes)` → `controller.anchors` runs in
// the fast gate on EVERY commit — no emulator, no SSH/tmux, no socket. The bytes
// ARE the real grid, captured once from real tmux into a fixture.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flterm/flterm.dart';
import 'package:flutter_test/flutter_test.dart';

/// A captured terminal grid: pane size + ordered raw byte chunks (the format
/// scripts/capture-terminal-corpus.sh emits — a single capture-pane snapshot is
/// one chunk; the future in-app recorder emits many with interleaved resizes).
class ReplayCast {
  ReplayCast(this.cols, this.rows, this.chunks);
  final int cols;
  final int rows;
  final List<Uint8List> chunks;
}

/// Map bare LF to CRLF so a captured visual row returns to column 0 when written
/// to the terminal (capture-pane emits LF-only row separators). Idempotent: an
/// existing CR before an LF is not doubled.
Uint8List _lfToCrlf(Uint8List bytes) {
  final out = <int>[];
  var prev = 0;
  for (final b in bytes) {
    if (b == 0x0a && prev != 0x0d) out.add(0x0d);
    out.add(b);
    prev = b;
  }
  return Uint8List.fromList(out);
}

ReplayCast loadCast(String path) {
  final json = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
  final chunks = [
    for (final c in json['chunks'] as List)
      base64Decode((c as Map<String, dynamic>)['b64'] as String),
  ];
  return ReplayCast(json['cols'] as int, json['rows'] as int, chunks);
}

/// Build a controller sized to the fixture, register the URL pattern, replay the
/// captured chunks in order, and wait past the detection debounce.
Future<TerminalController> replayCast(ReplayCast cast) async {
  final controller = TerminalController(
    config: TerminalConfig(cols: cast.cols, rows: cast.rows),
  );
  controller.registerTextPattern(TextPattern.url());
  for (final chunk in cast.chunks) {
    // capture-pane separates VISUAL rows with bare LF (no CR); a terminal needs
    // CRLF to return to column 0, else each row is written at the previous row's
    // end column and the grid garbles. Map LF→CRLF (idempotent if already CRLF).
    controller.write(_lfToCrlf(chunk));
  }
  // Detection re-scan is debounced (~120ms); mirror the detection test's 250ms.
  await Future<void>.delayed(const Duration(milliseconds: 250));
  return controller;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('REPLAY real captured tmux grid — URL detection (#767)', () {
    test(
      'a plain-text URL wrapped at the app content width (captured from REAL '
      'tmux, 55-col) is ONE anchor with the FULL URL spanning both rows — the '
      '+22..+28 regression',
      () async {
        // Captured by scripts/capture-terminal-corpus.sh from a real 55-col tmux
        // pane: a blue (SGR 34) plain-text URL wrapped at the content width with
        // trailing padding — the exact shape the Claude TUI produces and that
        // broke detection through +28.
        final cast = loadCast(
          'test/fixtures/replay/claude_wrapped_url_55col.cast.json',
        );
        final controller = await replayCast(cast);
        addTearDown(controller.dispose);

        const fullUrl = 'https://mobissh.tailbe5094.ts.net/'
            'mobissh-native-20260605T200823+0000.apk';

        final hits =
            controller.anchors.where((a) => a.payload == fullUrl).toList();
        expect(
          hits,
          hasLength(1),
          reason: 'the wrapped plain-text URL must be ONE anchor carrying the '
              'FULL URL (not just the first physical row) — replayed from the '
              'REAL captured grid, not a synthetic printf',
        );
        final spannedRows = {for (final r in hits.single.ranges) r.startRow};
        expect(
          spannedRows.length >= 2,
          isTrue,
          reason: 'the URL bubble must span BOTH wrapped rows (copy = full URL)',
        );
      },
    );
  });
}
