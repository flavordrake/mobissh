@Tags(['ffi'])
library;

// REPLAY-based acceptance for ABSOLUTE FILE PATH detection (#778, paths Slice 1).
//
// Clone of replay_url_detection_test.dart: feed a REAL captured tmux grid
// (scripts/capture-terminal-corpus.sh) into a real flterm TerminalController with
// TextPattern.path() registered, and assert path detection over the OWNER'S
// ACTUAL grid — never synthetic printf (the +22..+28 lesson, memory
// reference_grid_url_extraction §0).
//
// Headless: the real libghostty VT parser loads under `flutter test` on the host
// VM (ffi-tagged), so `controller.write(bytes)` → `controller.anchors` runs in the
// fast gate on EVERY commit — no emulator. The bytes ARE the real grid.
//
// Coverage:
//   * absolute paths are detected as `path` anchors (positive);
//   * a path wrapped at the content width spans >1 buffer row (the wrap case);
//   * an ENGLISH-PROSE grid yields NO path anchors (the over-match NEGATIVE).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flterm/flterm.dart';
import 'package:flutter_test/flutter_test.dart';

/// A captured terminal grid: pane size + ordered raw byte chunks (the format
/// scripts/capture-terminal-corpus.sh emits).
class ReplayCast {
  ReplayCast(this.cols, this.rows, this.chunks);
  final int cols;
  final int rows;
  final List<Uint8List> chunks;
}

/// Map bare LF to CRLF so a captured visual row returns to column 0 when written
/// to the terminal (capture-pane emits LF-only row separators). Idempotent.
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

/// Load a #790/#793 in-app bug-report `*.byte-trace.json` (grid + ordered
/// `byteTrace` chunks) into a [ReplayCast]. The recorder's schema differs from
/// the capture-corpus `*.cast.json` (`grid.cols`/`grid.rows` + `byteTrace[].b64`
/// vs `cols`/`rows` + `chunks[].b64`); this normalizes it so [replayCast] feeds
/// the SAME real libghostty parser. Events are sorted by `tMs` for deterministic
/// replay order.
ReplayCast loadByteTraceCast(String path) {
  final json = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
  final grid = json['grid'] as Map<String, dynamic>;
  final events = (json['byteTrace'] as List).cast<Map<String, dynamic>>().toList()
    ..sort((a, b) => (a['tMs'] as int).compareTo(b['tMs'] as int));
  final chunks = [for (final e in events) base64Decode(e['b64'] as String)];
  return ReplayCast(grid['cols'] as int, grid['rows'] as int, chunks);
}

/// Build a controller sized to the fixture, register the PATH pattern, replay the
/// captured chunks, and wait past the detection debounce.
Future<TerminalController> replayCast(ReplayCast cast) async {
  final controller = TerminalController(
    config: TerminalConfig(cols: cast.cols, rows: cast.rows),
  );
  controller.registerTextPattern(TextPattern.path());
  for (final chunk in cast.chunks) {
    controller.write(_lfToCrlf(chunk));
  }
  // Detection re-scan is debounced (~120ms); mirror the URL replay test's 250ms.
  await Future<void>.delayed(const Duration(milliseconds: 250));
  return controller;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('REPLAY real captured grid — absolute path detection (#778)', () {
    test(
      'absolute paths in a real shell grid are detected as `path` anchors',
      () async {
        final cast = loadCast(
          'test/fixtures/replay/paths_shell_55col.cast.json',
        );
        final controller = await replayCast(cast);
        addTearDown(controller.dispose);

        final pathPayloads = controller.anchors
            .where((a) => a.patternId == 'path')
            .map((a) => '${a.payload}')
            .toList();

        expect(
          pathPayloads,
          contains('/etc/ssh/sshd_config'),
          reason: 'a single-row absolute path must be a `path` anchor',
        );
        expect(
          pathPayloads,
          contains('/home/dev/workspace/devloop/rules/command-hygiene.md'),
          reason: 'a long single-row absolute path must be a `path` anchor',
        );
      },
    );

    test(
      'an absolute path wrapped at the content width is ONE anchor spanning '
      'BOTH rows carrying the FULL path',
      () async {
        final cast = loadCast(
          'test/fixtures/replay/paths_shell_55col.cast.json',
        );
        final controller = await replayCast(cast);
        addTearDown(controller.dispose);

        const fullPath =
            '/home/dev/workspace/mobissh/native/lib/ui/'
            'ghostty_terminal_view.dart';

        // The fixture contains this path twice — once on the `ls` command line
        // (single row) and once in the wrapped `ls` OUTPUT (two rows). Both are
        // legitimately detected, each carrying the FULL path; the wrapped one is
        // the case under test, so assert at least one spans >1 buffer row.
        final hits = controller.anchors
            .where((a) => a.patternId == 'path' && a.payload == fullPath)
            .toList();
        expect(
          hits,
          isNotEmpty,
          reason: 'the wrapped path must be detected carrying the FULL path '
              '(not just the first physical row)',
        );
        final wrapped = hits.where(
          (a) => {for (final r in a.ranges) r.startRow}.length >= 2,
        );
        expect(
          wrapped,
          isNotEmpty,
          reason: 'at least one anchor for the wrapped path must span BOTH '
              'wrapped rows (copy = full path)',
        );
      },
    );

    test(
      'an English-prose grid yields NO path anchors (the over-match negative)',
      () async {
        final cast = loadCast(
          'test/fixtures/replay/paths_prose_55col.cast.json',
        );
        final controller = await replayCast(cast);
        addTearDown(controller.dispose);

        final pathHits =
            controller.anchors.where((a) => a.patternId == 'path').toList();
        expect(
          pathHits,
          isEmpty,
          reason: 'prose with no leading /, ~/, ./ or ../ tokens must not '
              'produce path anchors — Slice 1 defers bare relative tokens',
        );
      },
    );
  });

  // #826: the REAL device trace — reading a shell SCRIPT in the Claude CLI on
  // the PRIMARY screen — over-matched many script tokens carrying shell vars /
  // globs (`/tmp/.ssh_loaded_${UID}_*`, `~/.ssh/*.pub`, `~/.zshrc.bak.*`,
  // `/var/run/com.apple.launchd.*/Listeners`). A tappable filesystem path NEVER
  // contains a metachar, so those candidates must be SUPPRESSED — while a clean
  // path on the SAME grid (`~/.zshrc`) still detects (no over-suppression).
  group('REPLAY #826 shell-script grid — metachar/glob paths suppressed', () {
    // The shell metacharacter / glob chars a real path never holds (the #826
    // class). No anchor payload may contain any of them.
    final metachar = RegExp(r'''[${}*?\[\]()`|<>&;='"\\]''');

    test(
      'NONE of the detected path anchors carry a shell metachar / glob char',
      () async {
        final cast = loadByteTraceCast(
          'test/fixtures/replay/script_paths_metachar_66x34.byte-trace.json',
        );
        final controller = await replayCast(cast);
        addTearDown(controller.dispose);

        final offenders = controller.anchors
            .where((a) => a.patternId == 'path')
            .map((a) => '${a.payload}')
            .where(metachar.hasMatch)
            .toList();

        expect(
          offenders,
          isEmpty,
          reason: 'a tappable path never contains a shell var/glob — these '
              'script fragments (e.g. /tmp/.ssh_loaded_, ~/.ssh/) must be '
              'suppressed, not anchored: $offenders',
        );
      },
    );

    test(
      'the specific reported false positives are absent from the anchors',
      () async {
        final cast = loadByteTraceCast(
          'test/fixtures/replay/script_paths_metachar_66x34.byte-trace.json',
        );
        final controller = await replayCast(cast);
        addTearDown(controller.dispose);

        final payloads = controller.anchors
            .where((a) => a.patternId == 'path')
            .map((a) => '${a.payload}')
            .toList();

        // The truncated FRAGMENTS the old regex anchored before/around the
        // metachar in the reported script.
        for (final frag in const [
          '/tmp/.ssh_loaded_',
          '~/.ssh/',
          '~/.zshrc.bak',
          '/var/run/com.apple.launchd',
        ]) {
          expect(
            payloads,
            isNot(contains(frag)),
            reason: '$frag is a glob/var fragment, not a tappable path',
          );
        }
      },
    );

    test(
      'a CLEAN path on the SAME grid still detects (no over-suppression)',
      () async {
        final cast = loadByteTraceCast(
          'test/fixtures/replay/script_paths_metachar_66x34.byte-trace.json',
        );
        final controller = await replayCast(cast);
        addTearDown(controller.dispose);

        final payloads = controller.anchors
            .where((a) => a.patternId == 'path')
            .map((a) => '${a.payload}')
            .toList();

        // `~/.zshrc` appears as a bare, metachar-free home path in the script
        // ("Backup zshrc before editing: cp ~/.zshrc …"); the precision fix must
        // NOT suppress it.
        expect(
          payloads,
          contains('~/.zshrc'),
          reason: 'the clean ~/.zshrc control must STILL detect — the fix '
              'rejects metachar tokens, not clean paths',
        );
      },
    );

    test(
      'every detected path anchor is ABSOLUTE-anchored (#778 Slice 1) — no '
      'bare-relative regex leak',
      () async {
        final cast = loadByteTraceCast(
          'test/fixtures/replay/script_paths_metachar_66x34.byte-trace.json',
        );
        final controller = await replayCast(cast);
        addTearDown(controller.dispose);

        final nonAbsolute = controller.anchors
            .where((a) => a.patternId == 'path')
            .map((a) => '${a.payload}')
            .where((p) =>
                !(p.startsWith('/') ||
                    p.startsWith('~') ||
                    p.startsWith('./') ||
                    p.startsWith('../')))
            .toList();

        // Slice 1 (#778) only matches absolute / ~ / ./ / ../ anchors. A bare
        // token matching would be a SEPARATE regex bug (issue #826 "Also note").
        expect(
          nonAbsolute,
          isEmpty,
          reason: 'a non-absolute path anchor would be a separate Slice-1 '
              'regex bug: $nonAbsolute',
        );
      },
    );
  });
}
