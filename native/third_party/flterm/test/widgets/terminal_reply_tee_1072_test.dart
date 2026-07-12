@Tags(['ffi'])
library;

import 'dart:convert';

import 'package:flterm/src/widgets/terminal_controller_impl.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1072 (telemetry): the terminal auto-reply TEE.
///
/// The controller wraps libghostty's `onWritePty` — the channel the terminal
/// writes its OWN generated replies back on (DA1/DA2 device attributes, DSR/CPR
/// cursor reports, XTVERSION, OSC answers) — as a PURE TEE: it fires
/// [onTerminalReply] with the reply bytes THEN forwards them via [onOutput]
/// exactly as before. These tests prove both halves: the tee observes the reply
/// AND the reply still reaches onOutput unchanged (backend behavior preserved).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('onTerminalReply tee (#1072)', () {
    late TerminalControllerImpl controller;

    setUp(() => controller = TerminalControllerImpl());
    tearDown(() => controller.dispose());

    void writeUtf8(String text) =>
        controller.write(Uint8List.fromList(utf8.encode(text)));

    test('DA1 request tees the reply to onTerminalReply AND onOutput', () {
      final replies = <Uint8List>[];
      final output = <Uint8List>[];
      controller.onTerminalReply = replies.add;
      controller.onOutput = output.add;

      // CSI c = Primary Device Attributes request. libghostty answers via
      // onWritePty with the default DA1 reply (CSI ? 62 c).
      writeUtf8('\x1b[c');

      // The tee fired with the DA reply bytes.
      expect(replies, isNotEmpty, reason: 'onTerminalReply never fired');
      final replyText = replies.map(utf8.decode).join();
      expect(replyText, contains('\x1b[?62c'),
          reason: 'expected the default DA1 reply CSI ? 62 c');

      // And the SAME bytes still forwarded to onOutput (pure tee — backend
      // behavior unchanged).
      expect(output, isNotEmpty, reason: 'reply was not forwarded to onOutput');
      expect(output.map(utf8.decode).join(), contains('\x1b[?62c'));
    });

    test('plain text output does NOT fire onTerminalReply', () {
      final replies = <Uint8List>[];
      controller.onTerminalReply = replies.add;

      // Ordinary printable output is not a terminal auto-reply — it produces no
      // onWritePty write, so the tee stays silent.
      writeUtf8('hello world');

      expect(replies, isEmpty);
    });

    test('reply still forwards when no onTerminalReply listener is attached',
        () {
      final output = <Uint8List>[];
      controller.onOutput = output.add;
      // onTerminalReply intentionally left null.

      writeUtf8('\x1b[c');

      expect(output.map(utf8.decode).join(), contains('\x1b[?62c'),
          reason: 'the null tee must not swallow the forwarded reply');
    });
  });
}
