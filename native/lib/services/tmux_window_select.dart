// tmux select-window byte-sequence builder (#840, Slice 2 — guarded enhancement).
//
// After a tapped attention notification routes focus to the originating session,
// if the payload carried a `(win N)` source-window hint AND the session is a
// tmux client, we issue a `select-window` so the user lands on the exact pane
// that asked for attention.
//
// We use tmux's COMMAND-PROMPT form rather than the single-digit `prefix N`
// binding so it works for ANY window index (incl. >= 10) and doesn't depend on
// the default numeric window-select key bindings being present:
//
//     <prefix> : select-window -t N <Enter>
//
// where <prefix> defaults to Ctrl-B (0x02). This is best-effort + device-gated:
// a non-default prefix, a detached client, or multi-client size churn can make
// it a no-op — by design we send it and don't assert it landed.

/// Default tmux prefix key: Ctrl-B.
const int _tmuxPrefix = 0x02;

/// Build the byte sequence that selects tmux window [n] via the command prompt.
/// Throws [ArgumentError] for a negative window index (callers parse `(win N)`
/// with `\d+`, so this is purely defensive).
List<int> tmuxSelectWindowSequence(int n) {
  if (n < 0) {
    throw ArgumentError.value(n, 'n', 'window index must be >= 0');
  }
  // prefix (Ctrl-B), ':' to open the command prompt, the select-window command,
  // then Enter (\r) to run it.
  return <int>[
    _tmuxPrefix,
    ...':select-window -t $n\r'.codeUnits,
  ];
}
