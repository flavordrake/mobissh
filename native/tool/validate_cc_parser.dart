// Validation spike for the tmux control-mode parser (#907, Part A of epic #906).
//
// Standalone Dart entrypoint (NOT a test): feed a captured `-CC` stream through
// `TmuxControlParser` and assert the parser's view of geometry + active window
// EQUALS tmux's INDEPENDENT truth (`tmux list-windows -F`, captured alongside
// the stream by scripts/capture-tmux-cc.sh into truth-windows.txt).
//
// This is the spike that proves Part A's premise: the client no longer has to
// GUESS tmux's geometry/active-window by scraping pixels — the control-mode
// stream tells it, and that telling matches reality.
//
// Run via scripts/validate-cc-parser.sh (which captures fresh data first).
//   dart run tool/validate_cc_parser.dart [streamFile] [truthFile]
//
// Exit 0 = parser view == tmux truth; non-zero = mismatch (the spike failed).

import 'dart:io';

import 'package:mobissh/terminal/tmux_control_parser.dart';

void main(List<String> args) {
  final streamFile = args.isNotEmpty ? args[0] : 'test/fixtures/tmux_cc/capture.cc';
  final truthFile = args.length > 1 ? args[1] : 'test/fixtures/tmux_cc/truth-windows.txt';

  final raw = File(streamFile).readAsStringSync();
  final parser = TmuxControlParser();
  final events = parser.feed(raw);

  stdout.writeln('== tmux -CC parser validation spike (#907) ==');
  stdout.writeln('stream : $streamFile (${raw.length} bytes)');
  stdout.writeln('truth  : $truthFile');
  stdout.writeln('events : ${events.length} parsed');

  // Event-type histogram — the protocol coverage proof.
  final hist = <String, int>{};
  for (final e in events) {
    hist.update(e.runtimeType.toString(), (v) => v + 1, ifAbsent: () => 1);
  }
  stdout.writeln('event types:');
  final keys = hist.keys.toList()..sort();
  for (final k in keys) {
    stdout.writeln('  $k: ${hist[k]}');
  }

  // tmux truth: each line "<index> <name> <active> <WxH> <layout>".
  final truthLines = File(truthFile)
      .readAsLinesSync()
      .where((l) => l.trim().isNotEmpty)
      .toList();
  if (truthLines.isEmpty) {
    _fail('truth file empty — capture did not record tmux list-windows');
  }

  final activeTruth = truthLines.firstWhere(
    (l) => l.split(' ').length > 2 && l.split(' ')[2] == '1',
    orElse: () => '',
  );
  if (activeTruth.isEmpty) {
    _fail('no active window in tmux truth');
  }
  final truthParts = activeTruth.split(' ');
  final truthLayout = TmuxControlParser.parseLayout(truthParts.last);
  if (truthLayout == null) {
    _fail('could not parse tmux truth layout: ${truthParts.last}');
  }

  // Parser truth.
  final aw = parser.activeWindowId;
  stdout.writeln('parser active window: @$aw');
  stdout.writeln('tmux truth active window index: ${truthParts[0]} name=${truthParts[1]}');

  if (aw == null) {
    _fail('parser never saw %session-window-changed (no active window)');
  }
  final parsedLayout = parser.layouts[aw];
  if (parsedLayout == null) {
    _fail('parser has no layout for active window @$aw');
  }

  stdout.writeln('parser active-window geometry : '
      '${parsedLayout.width}x${parsedLayout.height}, ${parsedLayout.panes.length} panes');
  stdout.writeln('tmux  active-window geometry  : '
      '${truthLayout.width}x${truthLayout.height}, ${truthLayout.panes.length} panes');

  final ok = parsedLayout.width == truthLayout.width &&
      parsedLayout.height == truthLayout.height &&
      parsedLayout.panes.length == truthLayout.panes.length;

  if (!ok) {
    _fail('PARSER VIEW != TMUX TRUTH (geometry/pane-count mismatch)');
  }

  stdout.writeln('');
  stdout.writeln('RESULT: PASS — parser geometry/active-window == tmux truth');
  exit(0);
}

Never _fail(String msg) {
  stderr.writeln('RESULT: FAIL — $msg');
  exit(1);
}
