@Tags(['ffi'])
library;

// REPLAY-based acceptance for #824: suppress URL/PATH detection on the ALTERNATE
// screen (vim / less / htop / full-screen TUIs).
//
// The real bug report (0.1.10+40, "erroneously detecting paths in vim") captured
// the device's PTY byte stream while editing `~/.ssh/config` in vim. The #778 path
// decorator underlined `~/.ssh/config`, `/Users/mf/.ssh/config`, etc. — but in a
// full-screen editor those paths aren't navigable and the highlight is pure noise.
//
// THE FIX: HEURISTIC structured-text detection (the regex url/path patterns) is
// for SHELL OUTPUT. Full-screen apps use the alternate screen buffer (DEC
// `?1049h`/`?1047h`). flterm tracks this via `controller.activeScreen`; the
// controller now scans only OSC-8 (app-declared hyperlink) patterns on the
// alt-screen and suppresses the regex url/path patterns — so vim's incidental
// `~/.ssh/config` no longer underlines, while a TUI's explicit OSC-8 link (the
// owner's #810 tap-to-copy case) stays detectable/copyable.
//
// FIXTURE NOTE (important): the #790/#793 recorder's byteTrace is a BOUNDED ring
// buffer — it kept only the last 44 chunks (1694 bytes) of a long-running vim
// session, so the original `?1049h` alt-screen-enter had already scrolled OUT of
// the captured window (verified: no 1049/1047 sequence in the captured bytes).
// Replaying those bytes ALONE into a fresh terminal would leave it on the PRIMARY
// screen and the paths would (wrongly) detect. To reproduce the EXACT device
// condition — vim already on the alt-screen when these redraw bytes arrived — the
// test primes the controller into the alternate screen (`?1049h`) before replaying
// the captured vim redraw. That is the honest device state, not a synthetic one.
//
// RED (pre-fix): paths detected on the alt-screen → anchors non-empty.
// GREEN (post-fix): activeScreen == alternate AND anchors is EMPTY.
//
// A complementary case proves NO over-suppression: leaving the alt-screen
// (`?1049l`) back to a shell grid with a real path resumes detection.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flterm/flterm.dart';
import 'package:flutter_test/flutter_test.dart';

import 'replay_trace_harness.dart';

const _vimFixture =
    'test/fixtures/replay/vim_altscreen_66x34.byte-trace.json';

/// DEC private mode 1049: enter the alternate screen buffer (what vim/less emit).
final _enterAltScreen = Uint8List.fromList(utf8.encode('\x1b[?1049h'));

/// DEC private mode 1049 reset: leave the alternate screen, back to primary.
final _leaveAltScreen = Uint8List.fromList(utf8.encode('\x1b[?1049l'));

Uint8List _ascii(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('REPLAY #824 — no URL/path detection on the alternate screen (vim)', () {
    test(
      'replaying the real vim alt-screen trace yields NO anchors '
      '(activeScreen == alternate, anchors EMPTY)',
      () async {
        final trace = loadByteTrace(_vimFixture);
        // The real captured grid: vim editing ~/.ssh/config at 66x34.
        expect(trace.cols, 66);
        expect(trace.rows, 34);
        expect(trace.byteTrace, hasLength(44));

        final controller = TerminalController(
          config: TerminalConfig(cols: trace.cols, rows: trace.rows),
        );
        addTearDown(controller.dispose);
        // Register BOTH patterns the live view registers — the bug is the path
        // pattern, but URL must be suppressed on the alt-screen too.
        controller.registerTextPattern(TextPattern.path());
        controller.registerTextPattern(TextPattern.url());

        // Reproduce the device condition: vim was ALREADY on the alt-screen when
        // these redraw bytes arrived (the `?1049h` scrolled out of the recorder's
        // bounded ring). Prime the alt-screen, THEN replay the captured vim grid.
        controller.write(_enterAltScreen);
        await replayTrace(controller, trace);

        expect(
          controller.activeScreen,
          TerminalScreen.alternate,
          reason: 'the primed + replayed trace must sit on the alternate screen '
              '(vim) — the precondition for suppression',
        );
        expect(
          controller.anchors,
          isEmpty,
          reason: 'on the alternate screen (vim) NO URL/path anchors must be '
              'detected — the paths in ~/.ssh/config are not navigable and the '
              'underline is noise (#824)',
        );
        expect(
          controller.highlights,
          isEmpty,
          reason: 'no detection highlights are painted on the alt-screen',
        );
      },
    );

    test(
      'leaving the alt-screen back to a shell grid RESUMES detection '
      '(no over-suppression)',
      () async {
        final controller = TerminalController(
          config: const TerminalConfig(cols: 66, rows: 34),
        );
        addTearDown(controller.dispose);
        controller.registerTextPattern(TextPattern.path());

        // Enter vim (alt-screen) and draw a path — must NOT detect.
        controller.write(_enterAltScreen);
        controller.write(_ascii('  edit /etc/ssh/sshd_config in vim\r\n'));
        await Future<void>.delayed(const Duration(milliseconds: 250));
        expect(
          controller.activeScreen,
          TerminalScreen.alternate,
          reason: 'precondition: on the alt-screen',
        );
        expect(
          controller.anchors,
          isEmpty,
          reason: 'no detection while on the alt-screen',
        );

        // Leave vim back to the shell and echo a path — detection must RESUME.
        controller.write(_leaveAltScreen);
        controller.write(_ascii('cat /etc/ssh/sshd_config\r\n'));
        await Future<void>.delayed(const Duration(milliseconds: 250));

        expect(
          controller.activeScreen,
          TerminalScreen.primary,
          reason: 'back on the primary/shell screen',
        );
        final pathPayloads = controller.anchors
            .where((a) => a.patternId == 'path')
            .map((a) => '${a.payload}')
            .toList();
        expect(
          pathPayloads,
          contains('/etc/ssh/sshd_config'),
          reason: 'detection resumes on returning to the shell (alt-screen exit '
              'must NOT permanently disable detection — #824)',
        );
      },
    );

    test(
      'an APP-DECLARED OSC-8 hyperlink on the alt-screen is STILL detected '
      '(the #810 tap-to-copy case is NOT over-suppressed)',
      () async {
        // The #824 gate suppresses only the HEURISTIC regex patterns (url/path)
        // on the alt-screen. An OSC-8 hyperlink is an EXPLICIT, app-emitted
        // clickable link — an alt-screen TUI that marks a URL clickable (the
        // owner's #810 tap-to-copy report) deliberately declared it, so it must
        // remain detectable/copyable even on the alt-screen.
        final controller = TerminalController(
          config: const TerminalConfig(cols: 66, rows: 34),
        );
        addTearDown(controller.dispose);
        // The app registers osc8 + url + path (same order as the live view).
        controller.registerTextPattern(TextPattern.osc8());
        controller.registerTextPattern(TextPattern.url());
        controller.registerTextPattern(TextPattern.path());

        const link = 'https://example.com/p/alt-screen-link';
        // Enter the alt-screen, then emit an OSC-8 hyperlink (`ESC]8;;<uri>ESC\`
        // ... `ESC]8;;ESC\`) plus a heuristic path that must NOT detect.
        controller.write(_enterAltScreen);
        controller.write(_ascii('\x1b]8;;$link\x1b\\clickme\x1b]8;;\x1b\\'));
        controller.write(_ascii('  and /etc/ssh/sshd_config here\r\n'));
        await Future<void>.delayed(const Duration(milliseconds: 250));

        expect(
          controller.activeScreen,
          TerminalScreen.alternate,
          reason: 'precondition: on the alt-screen',
        );
        final osc8Payloads = controller.anchors
            .where((a) => a.patternId == 'osc8')
            .map((a) => '${a.payload}')
            .toList();
        expect(
          osc8Payloads,
          contains(link),
          reason: 'an app-declared OSC-8 hyperlink survives alt-screen '
              'suppression — it is explicit app intent, not heuristic noise',
        );
        final pathPayloads = controller.anchors
            .where((a) => a.patternId == 'path')
            .toList();
        expect(
          pathPayloads,
          isEmpty,
          reason: 'the HEURISTIC path is still suppressed on the alt-screen — '
              'only the explicit OSC-8 link survives',
        );
      },
    );

    test(
      'a PRIMARY-screen shell grid still detects paths normally '
      '(the Claude-CLI / repainting-TUI case is unaffected)',
      () async {
        // A repainting TUI (Claude CLI #803) repaints the PRIMARY screen — no
        // `?1049h` — so detection must run. Model that here: a shell path on the
        // primary screen, no alt-screen ever entered.
        final controller = TerminalController(
          config: const TerminalConfig(cols: 66, rows: 34),
        );
        addTearDown(controller.dispose);
        controller.registerTextPattern(TextPattern.path());

        controller.write(_ascii('see /home/dev/workspace/mobissh/README.md\r\n'));
        await Future<void>.delayed(const Duration(milliseconds: 250));

        expect(
          controller.activeScreen,
          TerminalScreen.primary,
          reason: 'no alt-screen entered — a primary-screen repaint',
        );
        final pathPayloads = controller.anchors
            .where((a) => a.patternId == 'path')
            .map((a) => '${a.payload}')
            .toList();
        expect(
          pathPayloads,
          contains('/home/dev/workspace/mobissh/README.md'),
          reason: 'primary-screen shell/TUI detection is NOT suppressed (#824 '
              'gates only the alternate screen)',
        );
      },
    );
  });
}
