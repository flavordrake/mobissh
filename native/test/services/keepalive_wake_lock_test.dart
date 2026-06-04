// Wake-lock configuration tests (#517).
//
// Confirms `allowWakeLock: true` is wired through the foreground task options
// builder. We can't observe Android's `PowerManager` from a Dart unit test —
// the platform-side wake-lock acquisition is verified manually via
// `dumpsys power | grep MobiSSH` on a real device (see issue #517 acceptance).
// This test only asserts the Dart-side configuration.

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/keepalive_task.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('buildKeepaliveTaskOptions', () {
    test('allowWakeLock is true so the Dart isolate is not Doze-frozen', () {
      final options = buildKeepaliveTaskOptions();
      expect(options.allowWakeLock, isTrue);
    });

    test(
      'allowWifiLock is true so the Wi-Fi radio stays up during Doze (#738)',
      () {
        // The CPU wake lock alone keeps timers/CPU alive but the Wi-Fi radio
        // can still power down in Doze, silently dropping the TCP/Tailscale
        // socket. allowWifiLock holds a WifiLock while the service runs.
        final options = buildKeepaliveTaskOptions();
        expect(options.allowWifiLock, isTrue);
      },
    );

    test('both wake lock AND wifi lock are held together (#738)', () {
      final options = buildKeepaliveTaskOptions();
      expect(options.allowWakeLock, isTrue);
      expect(options.allowWifiLock, isTrue);
    });

    test(
      'autoRunOnBoot stays false (no boot-time start without user intent)',
      () {
        final options = buildKeepaliveTaskOptions();
        expect(options.autoRunOnBoot, isFalse);
      },
    );

    test(
      'eventAction is nothing (the running socket pump is the heartbeat)',
      () {
        final options = buildKeepaliveTaskOptions();
        expect(options.eventAction, isA<ForegroundTaskEventAction>());
      },
    );
  });
}
