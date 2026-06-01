// Tests for the task-isolate notification poster (#575). Exercises the wiring
// between a session signal, the notification update, and the tap → pending
// focus + launchApp hand-off, without binding to FlutterForegroundTask.

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/session_notification.dart';
import 'package:mobissh/services/session_notification_poster.dart';

void main() {
  test('notify updates the notification with the built title/body', () async {
    final updates = <Map<String, String>>[];
    var launched = 0;
    final bridge = PendingFocusBridge(MapKeyValueStore());
    final poster = SessionNotificationPoster(
      bridge: bridge,
      update: ({required title, required text}) async {
        updates.add({'title': title, 'text': text});
      },
      launch: () => launched++,
    );

    await poster.notify(
      sessionId: 'h:22:u:1',
      label: 'u@h:22',
      kind: SessionSignalKind.ready,
      message: 'build done',
    );

    expect(updates, hasLength(1));
    expect(updates.first['title'], 'u@h:22');
    expect(updates.first['text'], contains('build done'));
    expect(launched, 0, reason: 'posting does not launch the app');
  });

  test(
    'tap records the LAST notified session as pending focus + launches',
    () async {
      var launched = 0;
      final bridge = PendingFocusBridge(MapKeyValueStore());
      final poster = SessionNotificationPoster(
        bridge: bridge,
        update: ({required title, required text}) async {},
        launch: () => launched++,
      );

      await poster.notify(
        sessionId: 'A:22:u:1',
        label: 'u@A:22',
        kind: SessionSignalKind.ready,
      );
      await poster.notify(
        sessionId: 'B:22:u:2',
        label: 'u@B:22',
        kind: SessionSignalKind.ready,
      );

      await poster.onTapped();

      // The notification currently points at the most recently notified session.
      expect(await bridge.takePending(), 'B:22:u:2');
      expect(launched, 1);
    },
  );

  test(
    'tap before any notification is a safe no-op (still launches)',
    () async {
      var launched = 0;
      final bridge = PendingFocusBridge(MapKeyValueStore());
      final poster = SessionNotificationPoster(
        bridge: bridge,
        update: ({required title, required text}) async {},
        launch: () => launched++,
      );

      await poster.onTapped();
      expect(await bridge.takePending(), isNull);
      expect(launched, 1);
    },
  );
}
