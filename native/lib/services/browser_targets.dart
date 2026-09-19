// Browser-target seam (#1196 — slice 1 of #1195 "per-profile browser for
// extracted links"). Spec: `docs/link-browser-routing.md`, R1-R5.
//
// `url_launcher` cannot name a target app, and `android_intent_plus` can
// `setPackage` but cannot ENUMERATE the installed browsers — this feature needs
// both, so one `MethodChannel` does both jobs and no dependency is added (D3).
//
// PLATFORM SEAM ONLY. Nothing here is wired into `openDetectedUrl`, Settings or
// `SavedProfile` yet — that is slice 2 (#1197).
//
// The Kotlin half lives in `MainActivity.installBrowserChannel`. The method
// names, argument keys and payload keys below are the CONTRACT between the two
// halves and are pinned by `test/services/browser_targets_test.dart` (A2), so a
// rename on either side fails a Dart test instead of a device.
//
// Exposed as a [BrowserTargets] interface + a [browserTargetsProvider] +
// [FakeBrowserTargets], mirroring the `text_file_fetcher.dart` /
// `text_file_writer.dart` seam style, so no test ever touches a real channel or
// a real browser (R3).

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

/// Native channel name. Mirrors `mobissh/clipboard` (#845) and
/// `mobissh/downloads` (#559) — a thin custom channel installed in
/// `MainActivity.configureFlutterEngine`.
const String browserChannelName = 'mobissh/browser';

/// The native browser channel. `@visibleForTesting` only in the sense that
/// tests mock it; production code goes through [BrowserTargets].
const MethodChannel browserChannel = MethodChannel(browserChannelName);

/// Method: enumerate the activities that can handle `ACTION_VIEW https://`.
const String browserMethodListBrowsers = 'listBrowsers';

/// Method: open a URL, optionally in a NAMED package.
const String browserMethodOpen = 'open';

/// `open` argument key: the URL to view.
const String browserArgUrl = 'url';

/// `open` argument key: the package to target, or null for the system default.
const String browserArgPackage = 'package';

/// `listBrowsers` entry key: the package name — the stable identity (D2).
const String browserFieldPackage = 'package';

/// `listBrowsers` entry key: the OS-provided display label (R5 — `loadLabel`).
const String browserFieldLabel = 'label';

/// `listBrowsers` entry key: whether this is the resolved default handler.
const String browserFieldIsDefault = 'isDefault';

/// `open` result key: whether SOMETHING was started.
const String browserFieldOpened = 'opened';

/// `open` result key: whether it started somewhere other than requested (R2).
const String browserFieldUsedFallback = 'usedFallback';

/// `open` result key: the package the caller asked for (echoed back).
const String browserFieldRequestedPackage = 'requestedPackage';

/// One installed activity that can view an `https://` URL.
@immutable
class BrowserTarget {
  const BrowserTarget({
    required this.package,
    required this.label,
    this.isDefault = false,
  });

  /// The package name. Stored rather than the label, because labels change with
  /// app updates and locale while the package is the identity (D2).
  final String package;

  /// The OS-provided display label (R5). Falls back to [package] when the
  /// platform gave us nothing, so a picker row is never blank.
  final String label;

  /// True when this is the system's currently resolved default handler.
  final bool isDefault;

  /// Parses one `listBrowsers` entry. Returns null for anything malformed (a
  /// non-map, or an entry with no package) — an unusable row is dropped rather
  /// than allowed to poison the whole list.
  static BrowserTarget? fromPayload(Object? raw) {
    if (raw is! Map) return null;
    final package = raw[browserFieldPackage];
    if (package is! String || package.isEmpty) return null;
    final label = raw[browserFieldLabel];
    return BrowserTarget(
      package: package,
      label: (label is String && label.isNotEmpty) ? label : package,
      isDefault: raw[browserFieldIsDefault] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is BrowserTarget &&
      other.package == package &&
      other.label == label &&
      other.isDefault == isDefault;

  @override
  int get hashCode => Object.hash(package, label, isDefault);

  @override
  String toString() =>
      'BrowserTarget($package, "$label"${isDefault ? ', default' : ''})';
}

/// The outcome of an [BrowserTargets.open].
///
/// A bare bool cannot express "opened, but not where you asked" — which is
/// exactly the state R2 requires the caller to be able to detect, and R11
/// (slice 2) surfaces to the user.
@immutable
class BrowserOpenResult {
  const BrowserOpenResult({
    required this.opened,
    this.usedFallback = false,
    this.requestedPackage,
  });

  /// True when SOMETHING was started for the URL.
  final bool opened;

  /// True when a package was requested but the URL opened somewhere else
  /// (not installed, or the start failed). False when nothing opened at all —
  /// in that case no other target was used either.
  final bool usedFallback;

  /// The package the caller asked for, echoed back so a message can name it.
  final String? requestedPackage;

  /// True when the URL opened in exactly the target the caller asked for
  /// (including "the system default" when no package was named).
  bool get openedAsRequested => opened && !usedFallback;

  /// Parses an `open` result map from the platform.
  static BrowserOpenResult fromPayload(Map<Object?, Object?> raw) =>
      BrowserOpenResult(
        opened: raw[browserFieldOpened] == true,
        usedFallback: raw[browserFieldUsedFallback] == true,
        requestedPackage: raw[browserFieldRequestedPackage] as String?,
      );

  @override
  String toString() =>
      'BrowserOpenResult(opened: $opened, usedFallback: $usedFallback, '
      'requestedPackage: $requestedPackage)';
}

/// Opens [url] in the system default external browser. The SINGLE
/// `launchUrl(..., externalApplication)` call site in the app — both
/// `openDetectedUrl` (url_action_overlay.dart) and the no-channel degrade path
/// below go through it, so the two can never drift (R4).
Future<bool> launchExternalUrl(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}

/// Injectable "open in the system default" function, so a test can assert the
/// degrade path ran without launching a real browser.
typedef ExternalUrlOpener = Future<bool> Function(String url);

/// Enumerates the installed browsers and opens a URL, optionally in a named one.
abstract class BrowserTargets {
  /// The installed activities that can view an `https://` URL, deduplicated by
  /// package. EMPTY on a host with no channel (desktop, tests) — which means
  /// "offer no choice at all", not "offer an empty dropdown" (R4).
  Future<List<BrowserTarget>> listBrowsers();

  /// Open [url]. A null/absent [package] means today's behaviour (the system
  /// default). Never throws: a platform error degrades to the system default
  /// and is REPORTED through [BrowserOpenResult.usedFallback] (R2).
  Future<BrowserOpenResult> open(String url, {String? package});
}

/// Production implementation: the native `mobissh/browser` channel, degrading
/// to [launchExternalUrl] whenever the channel is absent or errors.
class PlatformBrowserTargets implements BrowserTargets {
  const PlatformBrowserTargets({
    this.channel = browserChannel,
    this.fallbackOpen = launchExternalUrl,
  });

  /// The native channel. Overridden only by tests.
  final MethodChannel channel;

  /// The R4 degrade path. Overridden only by tests.
  final ExternalUrlOpener fallbackOpen;

  @override
  Future<List<BrowserTarget>> listBrowsers() async {
    try {
      final raw = await channel.invokeMethod<List<Object?>>(
        browserMethodListBrowsers,
      );
      if (raw == null) return const <BrowserTarget>[];
      final out = <BrowserTarget>[];
      for (final entry in raw) {
        final target = BrowserTarget.fromPayload(entry);
        if (target != null) out.add(target);
      }
      return out;
    } catch (err) {
      // No channel (desktop / widget tests / missing plugin) or the native
      // side errored: an empty list means "no choice to offer" (R4).
      debugPrint('browser: listBrowsers unavailable ($err)');
      return const <BrowserTarget>[];
    }
  }

  @override
  Future<BrowserOpenResult> open(String url, {String? package}) async {
    try {
      final raw = await channel.invokeMethod<dynamic>(
        browserMethodOpen,
        <String, Object?>{browserArgUrl: url, browserArgPackage: package},
      );
      if (raw is Map<Object?, Object?>) return BrowserOpenResult.fromPayload(raw);
      // Anything else means the native side is not the one we contracted with
      // (older build, foreign handler) — treat it as no channel.
      debugPrint('browser: open returned an unexpected shape ($raw)');
    } catch (err) {
      debugPrint('browser: open via channel failed ($err)');
    }
    return _degradeToDefault(url, package);
  }

  /// The R4 degrade: open through the existing external-launch path. A named
  /// package could not be honoured here, so that IS a fallback — unless nothing
  /// opened at all, in which case no other target was used either.
  Future<BrowserOpenResult> _degradeToDefault(
    String url,
    String? package,
  ) async {
    bool opened;
    try {
      opened = await fallbackOpen(url);
    } catch (err) {
      debugPrint('browser: default open failed ($err)');
      opened = false;
    }
    return BrowserOpenResult(
      opened: opened,
      usedFallback: opened && package != null,
      requestedPackage: package,
    );
  }
}

/// The active [BrowserTargets]. Production resolves the platform channel;
/// tests override this with a [FakeBrowserTargets].
final browserTargetsProvider = Provider<BrowserTargets>(
  (ref) => const PlatformBrowserTargets(),
);

/// Test double (R3): canned targets + recorded opens, no channel, no browser.
/// Shipped in `lib/` (like [FakeCrashEnvironment]) so slice 2's widget tests
/// and the settings/profile pickers share ONE fake.
class FakeBrowserTargets implements BrowserTargets {
  FakeBrowserTargets({
    this.targets = const <BrowserTarget>[],
    this.openSucceeds = true,
  });

  /// What [listBrowsers] serves.
  final List<BrowserTarget> targets;

  /// Every [open] call, in order.
  final List<BrowserOpenRequest> opens = <BrowserOpenRequest>[];

  /// Whether [open] reports success.
  final bool openSucceeds;

  @override
  Future<List<BrowserTarget>> listBrowsers() async => targets;

  @override
  Future<BrowserOpenResult> open(String url, {String? package}) async {
    opens.add(BrowserOpenRequest(url: url, package: package));
    final installed =
        package == null || targets.any((t) => t.package == package);
    return BrowserOpenResult(
      opened: openSucceeds,
      // Mirrors the platform: a package that is not among the enumerated
      // targets opens somewhere else and says so.
      usedFallback: openSucceeds && !installed,
      requestedPackage: package,
    );
  }
}

/// One recorded [FakeBrowserTargets.open] call.
@immutable
class BrowserOpenRequest {
  const BrowserOpenRequest({required this.url, this.package});

  final String url;
  final String? package;

  @override
  String toString() => 'BrowserOpenRequest($url, package: $package)';
}
