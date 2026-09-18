// Route icon + routing details for a JUMPED session (#1189, R16 of
// docs/jump-host.md).
//
// A session whose transport was dialled through jump hops carries a small
// monochrome `alt_route` glyph on its TITLE — on the terminal session bar and
// on its session-menu row. A direct session gets NO icon and no other chrome:
// #1155 deliberately slimmed the session menu (it dropped the `user@host:port`
// subtitle), so a "via ‹hop›" TEXT line would contradict a fresh directive.
// The glyph matches the profile list's `profile-jump-badge` (#1183).
//
// Tapping the glyph opens the full route as a PATH: each hop in DIAL ORDER
// (outermost first) with its role ("Hop 1 of 3"), then the target.
//
// The source of truth is the LIVE session's [SessionEntry.jumpHops] — the hops
// its transport was actually built from — never the profile's current
// `jumpIdentityKey`. A session opened before the profile was re-pointed is
// still routed the old way, and showing the profile's value would be a lie
// about a live connection.

import 'dart:async';

import 'package:flutter/material.dart';

import '../state/sessions.dart';

/// `user@host:port` for one stop on the route.
String routeStopLabel(String username, String host, int port) =>
    '$username@$host:$port';

/// Open the routing details for [entry] on [navigatorContext] — the app
/// Navigator's context. When summoned from the session menu that overlay must
/// be closed FIRST (its barrier sits above pushed routes, the #664 idiom).
Future<void> showSessionRouteDetails(
  BuildContext navigatorContext, {
  required SessionEntry entry,
}) {
  return showModalBottomSheet<void>(
    context: navigatorContext,
    showDragHandle: true,
    builder: (_) => SessionRouteDetails(entry: entry),
  );
}

/// The tappable route glyph. Renders NOTHING when the session has no hops, so
/// a direct connection gains zero chrome; callers still guard on
/// `entry.jumpHops.isNotEmpty` so the test key is absent entirely.
class SessionRouteIcon extends StatelessWidget {
  const SessionRouteIcon({super.key, required this.entry, this.onBeforeOpen});

  final SessionEntry entry;

  /// Ran immediately before the details sheet is pushed — the session menu
  /// passes its `onClose` here.
  final VoidCallback? onBeforeOpen;

  @override
  Widget build(BuildContext context) {
    final hops = entry.jumpHops;
    if (hops.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return IconButton(
      tooltip: hops.length == 1
          ? 'Routed through 1 hop'
          : 'Routed through ${hops.length} hops',
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 28),
      padding: EdgeInsets.zero,
      icon: Icon(
        Icons.alt_route,
        size: 16,
        color: theme.textTheme.bodySmall?.color,
      ),
      onPressed: () {
        // Capture the navigator context BEFORE onBeforeOpen: closing the
        // session-menu overlay unmounts this widget's own context.
        final navContext = Navigator.of(context).context;
        onBeforeOpen?.call();
        unawaited(showSessionRouteDetails(navContext, entry: entry));
      },
    );
  }
}

/// The route, read as a path: every hop in dial order, then the target.
class SessionRouteDetails extends StatelessWidget {
  const SessionRouteDetails({super.key, required this.entry});

  final SessionEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hops = entry.jumpHops;
    final stops = <Widget>[];
    for (var i = 0; i < hops.length; i++) {
      final hop = hops[i];
      stops.add(
        _RouteStop(
          key: Key('session-route-hop-$i'),
          address: routeStopLabel(hop.username, hop.host, hop.port),
          role: 'Hop ${i + 1} of ${hops.length}',
          icon: Icons.alt_route,
        ),
      );
      stops.add(const _RouteConnector());
    }
    stops.add(
      _RouteStop(
        key: const Key('session-route-target'),
        address: routeStopLabel(entry.username, entry.host, entry.port),
        role: 'Target',
        icon: Icons.dns_outlined,
        emphasized: true,
      ),
    );

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          key: const Key('session-route-details'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Connection route', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Dialled in this order — the target session runs inside the '
              'last hop\'s channel.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            ...stops,
          ],
        ),
      ),
    );
  }
}

/// One stop on the route: glyph, `user@host:port`, and the role that makes the
/// list legible as a path rather than a bag of hosts.
class _RouteStop extends StatelessWidget {
  const _RouteStop({
    super.key,
    required this.address,
    required this.role,
    required this.icon,
    this.emphasized = false,
  });

  final String address;
  final String role;
  final IconData icon;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(icon, size: 18, color: theme.textTheme.bodySmall?.color),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                address,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: emphasized ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
              Text(role, style: theme.textTheme.bodySmall),
            ],
          ),
        ),
      ],
    );
  }
}

/// The vertical tick between two stops — the "path" part of the path.
class _RouteConnector extends StatelessWidget {
  const _RouteConnector();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 18,
            child: Center(
              child: Container(
                width: 2,
                height: 14,
                color: theme.colorScheme.outlineVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
