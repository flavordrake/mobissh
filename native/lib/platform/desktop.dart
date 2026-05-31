// Desktop-platform detection (#577).
//
// The native app targets Android (foreground-service + task-isolate machinery)
// AND desktop (macOS / Linux / Windows). On desktop the OS does not kill the
// process, so the SSH `SessionHost` runs in-process and the
// `flutter_foreground_task` keep-alive service is skipped entirely.
//
// Detection is INJECTABLE for tests: the real `Platform` is read only inside
// [kIsDesktop]; providers resolve through [isDesktopProvider] which a test can
// override to force desktop vs android without binding to a real platform.

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// True on a desktop platform (macOS / Linux / Windows). Reads the real
/// `Platform`; tests should NOT call this directly — override
/// [isDesktopProvider] instead.
bool get kIsDesktop =>
    !kIsWeb && (Platform.isMacOS || Platform.isLinux || Platform.isWindows);

/// Injectable desktop flag. Production resolves to [kIsDesktop]; tests override
/// this provider to force the desktop or android code path deterministically
/// (no real `Platform` read in the test isolate).
final isDesktopProvider = Provider<bool>((ref) => kIsDesktop);
