// Link-browser ROUTING (#1197 — slice 2 of #1195 "per-profile browser for
// extracted links"). Spec: `docs/link-browser-routing.md`, R6-R13.
//
// Slice 1 (#1196) gave us the platform seam: [BrowserTargets] can enumerate
// the installed browsers and open a URL in a NAMED one. This file answers the
// only remaining question — WHICH browser a given link should open in — and
// wires that answer to the two persisted settings:
//
//   * the per-profile override `SavedProfile.linkBrowserPackage` (R7), and
//   * the global default `DetectionSettings.linkBrowserPackage` (R6).
//
// R8 resolution order is profile → global → system, and R9 says a link
// extracted from a session resolves against THAT session's profile. The
// session context is threaded to the open path as a [LinkBrowserContext] (the
// router plus the session whose profile to resolve against); when the caller
// has no session in hand the router falls back to the ACTIVE session, because
// the long-press overlay and the gutter sheet belong to the visible terminal.
//
// Nothing here launches a URL on its own: every open goes through
// [BrowserTargets.open], which is slice 1's single launch seam (R3/R4), so a
// test never touches a real browser and there is never a second way to open a
// link.

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/detection_providers.dart';
import '../state/profiles_providers.dart';
import '../state/sessions.dart';
import 'browser_targets.dart';

/// Resolves the package a link from [sessionId] should open in.
/// Null when no session context is available — the ACTIVE session is used.
typedef LinkBrowserPackageFor = String? Function(String? sessionId);

/// R8 + R9, as a pure function: which package a link opens in.
///
/// [sessionId] is the session the link was extracted from; null means "no
/// session context", which resolves against [activeSessionId] (the visible
/// terminal). [profileKeyOf] maps a session id to its profile identity key,
/// [overrideOf] maps a profile identity key to its stored override, and
/// [globalDefault] is the app-wide setting. A null return means "the system
/// default" — exactly what [BrowserTargets.open] treats as today's behaviour.
///
/// An EMPTY stored string is treated as unset at every level: a corrupt value
/// must degrade to the next rung, never pin the open to a package that cannot
/// exist.
String? resolveLinkBrowserPackage({
  required String? sessionId,
  required String? activeSessionId,
  required String? Function(String sessionId) profileKeyOf,
  required String? Function(String profileKey) overrideOf,
  required String? globalDefault,
}) {
  final id = sessionId ?? activeSessionId;
  if (id != null) {
    final profileKey = profileKeyOf(id);
    if (profileKey != null) {
      final override = overrideOf(profileKey);
      if (override != null && override.isNotEmpty) return override;
    }
  }
  final global = globalDefault;
  return (global != null && global.isNotEmpty) ? global : null;
}

/// Opens links in the browser chosen for the originating session.
///
/// Thin by design: the RESOLUTION is [packageFor] (injected, so tests and the
/// provider below share one code path) and the LAUNCH is [targets] (slice 1's
/// seam). This class only joins them.
@immutable
class LinkBrowserRouter {
  const LinkBrowserRouter({required this.targets, required this.packageFor});

  /// Slice 1's enumerate + open seam. A [FakeBrowserTargets] in every test.
  final BrowserTargets targets;

  /// R8/R9 resolution for one session (null = the active one).
  final LinkBrowserPackageFor packageFor;

  /// Open [url] in the browser chosen for [sessionId] (null = the active
  /// session). Never throws — see [BrowserTargets.open].
  Future<BrowserOpenResult> open(String url, {String? sessionId}) =>
      targets.open(url, package: packageFor(sessionId));

  /// The OS display label for [package], or the package itself when it is not
  /// among the enumerated browsers. Called only on the R11 fallback path, so
  /// the enumeration cost is paid only when there is something to report — and
  /// an UNINSTALLED package still yields a name to show the user (R12: the
  /// stored setting is never cleared just because it didn't resolve).
  Future<String> labelFor(String package) async {
    for (final target in await targets.listBrowsers()) {
      if (target.package == package) return target.label;
    }
    return package;
  }
}

/// One open's routing context: the router plus the session whose profile the
/// link belongs to (R9). Held by the terminal view / gutter registry / file
/// viewer, which each know their own session, and handed to the open path.
///
/// A null [sessionId] means "the visible terminal" — the router resolves the
/// ACTIVE session.
@immutable
class LinkBrowserContext {
  const LinkBrowserContext(this.router, {this.sessionId});

  final LinkBrowserRouter router;

  /// The session the link was extracted from; null = the active session.
  final String? sessionId;

  Future<BrowserOpenResult> open(String url) =>
      router.open(url, sessionId: sessionId);
}

/// R11 message: when a chosen browser was missing, name it. Returns null when
/// the URL opened where it was asked to — a normal open stays silent.
///
/// Resolves the OS label when the package IS enumerated (the platform can fall
/// back for reasons other than "not installed") and otherwise names the
/// package, which is all the identity we have for a browser that is gone.
Future<String?> linkBrowserFallbackMessage(
  BrowserOpenResult result,
  LinkBrowserContext? browser,
) async {
  if (!result.usedFallback) return null;
  final package = result.requestedPackage;
  if (package == null || package.isEmpty) return null;
  final label = await browser?.router.labelFor(package) ?? package;
  return 'Opened in the default browser — $label is not available';
}

/// The installed browsers, for the two pickers (R6/R7). An EMPTY list means
/// the control is hidden entirely rather than offered empty (R4/A8).
final browserTargetsListProvider = FutureProvider<List<BrowserTarget>>(
  (ref) => ref.watch(browserTargetsProvider).listBrowsers(),
);

/// The live router: resolves a link's browser against the session collection,
/// the saved profiles and the global setting, all read at OPEN time so an edit
/// applies to the very next tap.
final linkBrowserRouterProvider = Provider<LinkBrowserRouter>((ref) {
  return LinkBrowserRouter(
    targets: ref.watch(browserTargetsProvider),
    packageFor: (sessionId) {
      final sessions = ref.read(sessionsProvider);
      final profiles =
          ref.read(savedProfilesProvider).valueOrNull ?? const [];
      return resolveLinkBrowserPackage(
        sessionId: sessionId,
        // frontEntry, not `active`: the visible terminal is the one the
        // overlay/gutter belong to even mid-disconnect (#936's rule).
        activeSessionId: sessions.frontEntry?.id,
        profileKeyOf: (id) {
          for (final entry in sessions.entries) {
            if (entry.id == id) return entry.profileKey;
          }
          return null;
        },
        overrideOf: (profileKey) {
          for (final profile in profiles) {
            if (profile.identityKey == profileKey) {
              return profile.linkBrowserPackage;
            }
          }
          return null;
        },
        globalDefault: ref.read(detectionSettingsProvider).linkBrowserPackage,
      );
    },
  );
});
