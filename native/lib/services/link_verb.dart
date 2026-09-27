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
    return tmux == null ? null : TmuxAttach(tmux, window: request.window);
  }
}

/// `tmux=<name>` → `tmux new-session -A -s <name>` (attach or create).
///
/// #1211: an optional [window] is selected AFTER the attach — never typed into
/// the terminal; it runs as its own exec channel ([tmuxSelectWindowExecLine]).
/// [commandLine] is unchanged by it.
final class TmuxAttach extends LinkVerbCommand {
  /// Re-asserts the R6 shape (no leading hyphen, so the name can never be
  /// option-parsed by tmux) as a belt-and-braces guard against a request
  /// built anywhere but the parser.
  TmuxAttach(this.name, {this.window}) {
    if (!tmuxNameShape.hasMatch(name)) {
      throw ArgumentError.value(name, 'name', 'not a valid tmux session name');
    }
    final w = window;
    if (w != null && !tmuxNameShape.hasMatch(w)) {
      throw ArgumentError.value(w, 'window', 'not a valid tmux window name');
    }
  }

  final String name;
  final String? window;

  @override
  String get commandLine => 'tmux new-session -A -s $name';
}

/// #1211: the exec-channel line that selects [window] in tmux session
/// [session] by EXACT name (`=` on both: no prefix or fnmatch match, so
/// `window=bet` never lands on `beta`). Both tokens are re-validated against
/// the R6 shape here — the task side builds the line from the IPC fields, so
/// this is the last gate before a shell sees it — and single-quoted anyway,
/// though the shape admits no quote or shell metacharacter.
String tmuxSelectWindowExecLine(String session, String window) {
  if (!tmuxNameShape.hasMatch(session)) {
    throw ArgumentError.value(session, 'session', 'not a valid tmux name');
  }
  if (!tmuxNameShape.hasMatch(window)) {
    throw ArgumentError.value(window, 'window', 'not a valid tmux name');
  }
  return "tmux select-window -t '=$session:=$window'";
}

/// #1211: select [verb]'s window through [run] (production: the session's
/// exec channel, `SshSessionProxy.tmuxSelectWindow`) and, when tmux has no
/// such window, [notify] ONE neutral notice. Nothing is ever created. Returns
/// whether the window was selected; a verb without a window runs nothing.
Future<bool> selectLinkWindow(
  TmuxAttach verb, {
  required Future<bool> Function(String session, String window) run,
  required void Function(String message) notify,
}) async {
  final window = verb.window;
  if (window == null) return false;
  final selected = await run(verb.name, window);
  if (!selected) notify('No window "$window" in tmux session ${verb.name}');
  return selected;
}
