// Unit tests for [AttentionSignalScanner] — the in-band agent-attention signal
// detector (#840, Slice 1). See native/lib/services/attention_signal_scanner.dart.
//
// The scanner observes the raw PTY byte stream (after the DA2 strip) and detects
// four signal forms: bare BEL, OSC 9, OSC 777, and the `notify-bell.sh`
// `\r\033[K# <message>\a` line. It buffers partial sequences across chunk
// boundaries, strips OSC framing first (so a sequence-terminating BEL doesn't
// double-fire as a bare bell), and applies a 2s per-scanner dedup cooldown.

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/attention_signal_scanner.dart';

/// String -> raw byte list (codeUnits is fine — all test data is ASCII/UTF-8).
List<int> _b(String s) => s.codeUnits;

void main() {
  group('AttentionSignalScanner — single forms', () {
    test('bare BEL fires one bell signal', () {
      final s = AttentionSignalScanner();
      final sigs = s.feed(_b('output\x07more'));
      expect(sigs, hasLength(1));
      expect(sigs.single.kind, AttentionKind.bell);
      expect(sigs.single.text, isNull);
    });

    test('OSC 9 (BEL-terminated) captures the message', () {
      final s = AttentionSignalScanner();
      final sigs = s.feed(_b('\x1b]9;Claude is waiting\x07'));
      expect(sigs, hasLength(1));
      expect(sigs.single.kind, AttentionKind.osc9);
      expect(sigs.single.text, 'Claude is waiting');
    });

    test('OSC 9 (ST-terminated, ESC backslash) captures the message', () {
      final s = AttentionSignalScanner();
      final sigs = s.feed(_b('\x1b]9;Claude is waiting\x1b\\'));
      expect(sigs, hasLength(1));
      expect(sigs.single.kind, AttentionKind.osc9);
      expect(sigs.single.text, 'Claude is waiting');
    });

    test('OSC 777 notify captures title + body', () {
      final s = AttentionSignalScanner();
      final sigs = s.feed(_b('\x1b]777;notify;MobiSSH;Claude is waiting\x07'));
      expect(sigs, hasLength(1));
      expect(sigs.single.kind, AttentionKind.osc777);
      expect(sigs.single.text, 'MobiSSH: Claude is waiting');
    });

    test('notify-bell line captures the message (leading "# " stripped)', () {
      final s = AttentionSignalScanner();
      final sigs = s.feed(_b('\r\x1b[K# Claude is waiting\x07'));
      expect(sigs, hasLength(1));
      expect(sigs.single.kind, AttentionKind.hookLine);
      expect(sigs.single.text, 'Claude is waiting');
    });
  });

  group('AttentionSignalScanner — chunk straddle', () {
    test('OSC 9 split across two feeds is detected exactly once', () {
      final s = AttentionSignalScanner();
      final first = s.feed(_b('\x1b]9;Claude is'));
      expect(first, isEmpty, reason: 'incomplete OSC must buffer, not fire');
      final second = s.feed(_b(' waiting\x07'));
      expect(second, hasLength(1));
      expect(second.single.kind, AttentionKind.osc9);
      expect(second.single.text, 'Claude is waiting');
    });

    test('bare BEL split (ESC of ST lands at chunk end) detected once', () {
      // OSC 9 terminated by ST where the ESC is the last byte of chunk 1.
      final s = AttentionSignalScanner();
      final first = s.feed(_b('\x1b]9;hi\x1b'));
      expect(first, isEmpty, reason: 'pending ESC may be ST — must buffer');
      final second = s.feed(_b('\\'));
      expect(second, hasLength(1));
      expect(second.single.kind, AttentionKind.osc9);
      expect(second.single.text, 'hi');
    });

    test('notify-bell line split across feeds is detected once', () {
      final s = AttentionSignalScanner();
      final first = s.feed(_b('\r\x1b[K# Claude is'));
      expect(first, isEmpty);
      final second = s.feed(_b(' waiting\x07'));
      expect(second, hasLength(1));
      expect(second.single.kind, AttentionKind.hookLine);
      expect(second.single.text, 'Claude is waiting');
    });
  });

  group('AttentionSignalScanner — no double-fire', () {
    test('OSC terminated by BEL does NOT also emit a bare bell', () {
      final s = AttentionSignalScanner();
      final sigs = s.feed(_b('\x1b]9;done\x07'));
      expect(sigs, hasLength(1), reason: 'the terminating BEL is consumed by the OSC');
      expect(sigs.single.kind, AttentionKind.osc9);
    });

    test('notify-bell terminating BEL does NOT also emit a bare bell', () {
      final s = AttentionSignalScanner();
      final sigs = s.feed(_b('\r\x1b[K# hi\x07'));
      expect(sigs, hasLength(1));
      expect(sigs.single.kind, AttentionKind.hookLine);
    });
  });

  group('AttentionSignalScanner — dedup (fake_async clock)', () {
    test('two BELs within the cooldown collapse to one; after cooldown, two', () {
      fakeAsync((async) {
        final s = AttentionSignalScanner(
          nowMs: () => async.elapsed.inMilliseconds,
          cooldownMs: 2000,
        );

        // First BEL fires.
        expect(s.feed(_b('\x07')), hasLength(1));

        // Second BEL 500ms later is within the 2s cooldown -> collapsed.
        async.elapse(const Duration(milliseconds: 500));
        expect(s.feed(_b('\x07')), isEmpty);

        // After the cooldown fully elapses, the next BEL fires again.
        async.elapse(const Duration(milliseconds: 2000));
        expect(s.feed(_b('\x07')), hasLength(1));
      });
    });

    test('a burst within one feed collapses to a single signal', () {
      fakeAsync((async) {
        final s = AttentionSignalScanner(
          nowMs: () => async.elapsed.inMilliseconds,
          cooldownMs: 2000,
        );
        // Three BELs in one chunk, same instant -> one signal.
        final sigs = s.feed(_b('\x07\x07\x07'));
        expect(sigs, hasLength(1));
      });
    });
  });

  group('AttentionSignalScanner — non-signal traffic', () {
    test('plain shell output produces nothing', () {
      final s = AttentionSignalScanner();
      expect(s.feed(_b('user@host:~\$ ls -la\r\ntotal 4\r\n')), isEmpty);
    });

    test('SGR colors / cursor moves / primary-DA produce nothing', () {
      final s = AttentionSignalScanner();
      // SGR red, reset, cursor up, primary DA query — none is an attention form.
      expect(s.feed(_b('\x1b[31mred\x1b[0m\x1b[2A\x1b[?1;2c')), isEmpty);
    });

    test('an unrelated OSC (OSC 8 hyperlink) produces nothing', () {
      final s = AttentionSignalScanner();
      // OSC 8 ; ; https://example.com  ST  -- a hyperlink, not an attention form.
      expect(s.feed(_b('\x1b]8;;https://example.com\x1b\\')), isEmpty);
    });

    test('clear-to-EOL without "# " is not a hook line', () {
      final s = AttentionSignalScanner();
      // `\r\033[K` redraw with no `# message` — common prompt repaint.
      expect(s.feed(_b('\r\x1b[Kuser@host\$ ')), isEmpty);
    });
  });
}
