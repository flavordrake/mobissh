// Shared session-state affordances (#821 Slice 3, extracted from #817 Slice 2).
//
// Slice 2 added a state-driven status dot + a "can this session be manually
// reconnected?" predicate to the in-session MENU (session_menu.dart). Slice 3
// brings the SAME surface to the CONNECT view's Active Sessions group
// (profile_list.dart), so a dropped session is reconnectable from the home
// screen. To avoid duplicating the state→affordance mapping (the explicit
// instruction in #821), the dot widget + the reconnect predicate live here and
// are reused by both surfaces.

import 'package:flutter/material.dart';

import '../ssh/ssh_session.dart';
import '../state/sessions.dart';

/// True when [state] is a drop the user can manually reconnect from (#817).
/// A live/connecting session is excluded — it's already healthy or trying.
/// Reads STATE, never a boolean.
bool sessionCanReconnect(SshSessionState state) {
  return state == SshSessionState.softDisconnected ||
      state == SshSessionState.reconnecting ||
      state == SshSessionState.failed ||
      state == SshSessionState.disconnected;
}

/// One-line verdict for a "Reconnect all" batch (#959), shared by BOTH
/// surfaces (the in-session menu row and the Connect-view Active Sessions row)
/// so the wording can't drift between them. The per-row dot/subtitle says WHICH
/// session failed; this says the batch is done and how it went — without it a
/// batch where one machine refused to come back was indistinguishable from a
/// clean one.
String reconnectAllSummary(ReconnectAllResult result) {
  final ok = result.reconnected.length;
  final bad = result.failed.length;
  if (bad == 0) {
    return ok == 1 ? 'Reconnected 1 session' : 'Reconnected $ok sessions';
  }
  if (ok == 0) {
    return bad == 1
        ? 'Reconnect failed for 1 session'
        : 'Reconnect failed for $bad sessions';
  }
  return 'Reconnected $ok, $bad failed';
}

/// State-driven status dot for a session (#817). The COLOR encodes the
/// lifecycle state; `connecting`/`reconnecting` pulse to signal "in flight".
/// Monochrome / theme-derived colors only — no emoji
/// (feedback_monochrome_icons_no_emoji):
///   connected → solid profile color (else theme accent)
///   connecting/authenticating/awaitingHostKey → pulsing accent
///   softDisconnected/reconnecting → amber
///   failed → red (theme error)
///   disconnected (user) / idle → grey (outlineVariant)
class SessionStateDot extends StatefulWidget {
  const SessionStateDot({
    super.key,
    required this.swatchKey,
    required this.state,
    required this.profileColor,
  });

  /// Key applied to the actual dot Container — retained from #739 so swatch
  /// tests + device screenshots still address it.
  final Key swatchKey;
  final SshSessionState state;
  final Color? profileColor;

  @override
  State<SessionStateDot> createState() => _SessionStateDotState();
}

class _SessionStateDotState extends State<SessionStateDot>
    with SingleTickerProviderStateMixin {
  // Constructed eagerly in initState (NOT `late final`): a lazy field would be
  // built inside dispose() if it was never animated, and constructing an
  // AnimationController during unmount does a TickerMode ancestor lookup on a
  // deactivated widget (crash). Eager construction makes dispose() always safe.
  late final AnimationController _pulse;

  bool get _pulsing =>
      widget.state == SshSessionState.connecting ||
      widget.state == SshSessionState.authenticating ||
      widget.state == SshSessionState.awaitingHostKey ||
      widget.state == SshSessionState.softDisconnected ||
      widget.state == SshSessionState.reconnecting;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
      value: 1.0,
    );
    if (_pulsing) _pulse.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(SessionStateDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_pulsing && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!_pulsing && _pulse.isAnimating) {
      _pulse
        ..stop()
        ..value = 1.0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  Color _color(ThemeData theme) {
    switch (widget.state) {
      // connected (and idle, pre-connect) keep the PROFILE color so the SAME
      // color still identifies the SAME profile across the app (#739, PWA
      // `session-dot`). A colorless session shows the neutral fallback — never a
      // fake real-looking color (#739).
      case SshSessionState.idle:
      case SshSessionState.connected:
        return widget.profileColor ?? theme.colorScheme.outlineVariant;
      case SshSessionState.connecting:
      case SshSessionState.authenticating:
      case SshSessionState.awaitingHostKey:
        return theme.colorScheme.primary;
      case SshSessionState.softDisconnected:
      case SshSessionState.reconnecting:
        return Colors.orange.shade700;
      case SshSessionState.failed:
        return theme.colorScheme.error;
      case SshSessionState.disconnected:
        return theme.colorScheme.outlineVariant;
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = _color(Theme.of(context));
    final dot = Container(
      key: widget.swatchKey,
      width: 10,
      height: 10,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
    if (!_pulsing) return dot;
    return FadeTransition(
      opacity: Tween<double>(begin: 0.35, end: 1.0).animate(_pulse),
      child: dot,
    );
  }
}
