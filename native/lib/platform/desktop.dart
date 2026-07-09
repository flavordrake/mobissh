// Platform detection: desktop (#577) + hosting model (#1026).
//
// The native app targets Android (foreground-service + task-isolate
// machinery), desktop (macOS / Linux / Windows), and iOS. Two DISTINCT
// predicates live here — pick by meaning, not by platform list:
//
//   - [kIsDesktop]: "this is a desktop OS" (windowed UX, hardware keyboard,
//     the OS never kills the process).
//   - [kUsesInProcessHost]: "the SSH `SessionHost` runs in-process — there is
//     no Android foreground service and no task isolate". True on desktop AND
//     on iOS: iOS has no FGS equivalent, so backgrounded sessions drop and
//     revive on foreground via the resume machinery (#1026).
//
// Detection is INJECTABLE for tests: the real `Platform` is read only through
// [debugOperatingSystemOverride]; providers resolve through
// [isDesktopProvider] / [usesInProcessHostProvider] which a test can override
// to force a platform path without binding to a real platform.

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Test seam: force the operating-system name ('android', 'ios', 'macos',
/// 'linux', 'windows') the predicates below resolve against. Production leaves
/// this null → the real `Platform.operatingSystem` is read.
@visibleForTesting
String? debugOperatingSystemOverride;

String get _os => debugOperatingSystemOverride ?? Platform.operatingSystem;

/// True on a desktop platform (macOS / Linux / Windows). Reads the real
/// `Platform` (via the test seam); tests should NOT call this directly —
/// override [isDesktopProvider] instead.
bool get kIsDesktop =>
    !kIsWeb && (_os == 'macos' || _os == 'linux' || _os == 'windows');

/// True where the SSH `SessionHost` runs IN-PROCESS: no Android foreground
/// service, no task isolate (#1026). Desktop qualifies because the OS never
/// kills the process; iOS qualifies because it has NO foreground-service
/// equivalent — the app suspends on background, sessions drop, and the
/// existing resume/reconnect machinery revives them on foreground. Only
/// Android uses the `flutter_foreground_task` task-isolate host.
bool get kUsesInProcessHost => kIsDesktop || (!kIsWeb && _os == 'ios');

/// Injectable desktop flag. Production resolves to [kIsDesktop]; tests override
/// this provider to force the desktop or android code path deterministically
/// (no real `Platform` read in the test isolate).
final isDesktopProvider = Provider<bool>((ref) => kIsDesktop);

/// Injectable hosting-model flag (#1026). Derived from [isDesktopProvider]
/// (so existing desktop-flag overrides keep steering the hosting path) OR the
/// iOS check. Tests can also override this provider directly, or set
/// [debugOperatingSystemOverride] = 'ios' to exercise the full production
/// resolution chain.
final usesInProcessHostProvider = Provider<bool>(
  (ref) => ref.watch(isDesktopProvider) || (!kIsWeb && _os == 'ios'),
);
