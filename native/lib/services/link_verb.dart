// #1149 (PR E of #1117) — the v1.1 link verbs (docs/deep-link-intents.md §7).
//
// A verb is a TYPED command, never a String from the link: it is built only
// from a [ConnectRequest] whose token the parser already validated (R6), and
// its command line is a constant template + that token (R22). Nothing here
// can carry a free command; `InitialCommandRunner.sendNow` accepts only this
// type, so the raw link value has no path into the PTY.
//
// `claude=<id>` (R24) is reserved in the grammar and NOT implemented here.

import 'connect_intent.dart';

sealed class LinkVerbCommand {
  const LinkVerbCommand();

  /// The exact line sent to the shell (without the trailing newline).
  String get commandLine;

  /// The verb carried by a validated request, or null for a plain connect.
  static LinkVerbCommand? fromRequest(ConnectRequest request) {
    final tmux = request.tmux;
    return tmux == null ? null : TmuxAttach(tmux);
  }
}

/// `tmux=<name>` → `tmux new-session -A -s <name>` (attach or create).
final class TmuxAttach extends LinkVerbCommand {
  /// Re-asserts the R6 shape (no leading hyphen, so the name can never be
  /// option-parsed by tmux) as a belt-and-braces guard against a request
  /// built anywhere but the parser.
  TmuxAttach(this.name) {
    if (!tmuxNameShape.hasMatch(name)) {
      throw ArgumentError.value(name, 'name', 'not a valid tmux session name');
    }
  }

  final String name;

  @override
  String get commandLine => 'tmux new-session -A -s $name';
}
