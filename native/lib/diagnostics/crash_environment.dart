// Test seam for the crash reporter.
//
// All platform-channel calls (path_provider / device_info_plus /
// package_info_plus) are routed through a [CrashEnvironment] so the unit
// tests can swap in a fake that uses a tempfile directory and a fixed
// snapshot. Without this seam the tests would have to wire MethodChannel
// mocks for three plugins.

import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

/// Snapshot of device + build identifiers stamped into each crash report.
class CrashEnvironmentInfo {
  final String appVersion;
  final String buildSha;
  final String platformVersion;
  final String deviceModel;

  const CrashEnvironmentInfo({
    required this.appVersion,
    required this.buildSha,
    required this.platformVersion,
    required this.deviceModel,
  });
}

/// Abstract dependency layer for [CrashReporter]. Concrete impls supply the
/// crashes directory + a device snapshot.
abstract class CrashEnvironment {
  /// Where crash JSON files live. Returns null if the storage layer is
  /// unavailable (rare — only on platforms without app-doc storage).
  Future<Directory?> crashesDir();

  /// Static, cheap-to-fetch metadata for the report payload.
  Future<CrashEnvironmentInfo> snapshot();
}

/// Production implementation. Caches the snapshot the first time it's
/// requested — device + version info never changes during a process lifetime.
class DefaultCrashEnvironment implements CrashEnvironment {
  const DefaultCrashEnvironment();

  // Caches must be top-level since the class is const. Using a tiny
  // module-level holder keeps `const DefaultCrashEnvironment()` valid.
  @override
  Future<Directory?> crashesDir() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      return Directory('${docs.path}${Platform.pathSeparator}crashes');
    } catch (err, st) {
      debugPrint('[CrashEnvironment] crashesDir failed: $err\n$st');
      return null;
    }
  }

  @override
  Future<CrashEnvironmentInfo> snapshot() async {
    final cached = _DefaultCache.value;
    if (cached != null) return cached;
    String appVersion = '';
    String buildSha = '';
    String platformVersion = '';
    String deviceModel = '';
    try {
      final pkg = await PackageInfo.fromPlatform();
      appVersion = '${pkg.version}+${pkg.buildNumber}';
      buildSha = pkg.buildSignature.isEmpty ? '' : pkg.buildSignature;
    } catch (err) {
      debugPrint('[CrashEnvironment] PackageInfo failed: $err');
    }
    try {
      if (Platform.isAndroid) {
        final info = await DeviceInfoPlugin().androidInfo;
        platformVersion = 'Android ${info.version.sdkInt} (${info.version.release})';
        deviceModel = '${info.manufacturer} ${info.model}';
      } else if (Platform.isIOS) {
        final info = await DeviceInfoPlugin().iosInfo;
        platformVersion = 'iOS ${info.systemVersion}';
        deviceModel = info.utsname.machine;
      } else {
        platformVersion = Platform.operatingSystemVersion;
        deviceModel = Platform.operatingSystem;
      }
    } catch (err) {
      debugPrint('[CrashEnvironment] DeviceInfo failed: $err');
    }
    final result = CrashEnvironmentInfo(
      appVersion: appVersion,
      buildSha: buildSha,
      platformVersion: platformVersion,
      deviceModel: deviceModel,
    );
    _DefaultCache.value = result;
    return result;
  }
}

class _DefaultCache {
  static CrashEnvironmentInfo? value;
}

/// Test impl: a fixed directory + a fixed snapshot. Lets unit tests run
/// without any platform channels mounted.
class FakeCrashEnvironment implements CrashEnvironment {
  final Directory dir;
  final CrashEnvironmentInfo info;

  FakeCrashEnvironment({
    required this.dir,
    CrashEnvironmentInfo? info,
  }) : info = info ??
            const CrashEnvironmentInfo(
              appVersion: 'test+1',
              buildSha: 'testsha',
              platformVersion: 'TestOS 1.0',
              deviceModel: 'TestVendor TestModel',
            );

  @override
  Future<Directory?> crashesDir() async => dir;

  @override
  Future<CrashEnvironmentInfo> snapshot() async => info;
}
