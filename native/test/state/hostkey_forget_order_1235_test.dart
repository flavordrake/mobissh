// #1235 device finding (fleet emulator, first run of
// hostkey_retrust_1235_test): a failed first connect STOPS the foreground
// service, and the dying isolate's last `closed` event flipped the UI gateway
// back to ready. A forget sent before the restart went to the dead transport,
// so the restarted host never saw it and the reconnect hit the CHANGED key
// again. The forget must go out only AFTER the service start completes, and
// still ahead of the reconnect's connect.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/host_key_mismatch.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/state/keepalive_providers.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('forget is sent after the service start, before the connect', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final log = <String>[];
    final pair = InMemoryGatewayPair();
    addTearDown(pair.dispose);
    final c = ProviderContainer(
      overrides: [
        taskSshGatewayProvider.overrideWithValue(pair.uiSide),
        keepaliveServiceStarterProvider.overrideWithValue(() async {
          log.add('start-begin');
          await Future<void>.delayed(const Duration(milliseconds: 30));
          log.add('start-done');
        }),
      ],
    );
    addTearDown(c.dispose);
    final sub = pair.taskSide.incoming.listen(
      (cmd) => log.add('cmd:${cmd['kind']}'),
    );
    addTearDown(sub.cancel);

    final entry = c
        .read(sessionsProvider.notifier)
        .addOrActivate(
          const SshConnectParams(
            host: 'nv-dev',
            port: 22,
            username: 'u',
            auth: SshAuth.password('p'),
          ),
        );
    pair.taskSide.send(
      SshStateEvent(
        sessionId: entry.proxy.sessionId,
        state: 'failed',
        hostKeyMismatch: const HostKeyMismatch(
          host: 'nv-dev',
          port: 22,
          keyType: 'ssh-ed25519',
          storedFingerprint: 'aabb',
          offeredFingerprint: 'dead',
        ),
      ).toJson(),
    );
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(entry.proxy.data.hostKeyMismatch, isNotNull);
    log.clear();

    await c.read(sessionsProvider.notifier).forgetHostKeyAndReconnect(entry.id);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final forgetAt = log.indexOf('cmd:forgetHostKey');
    expect(forgetAt, greaterThan(log.indexOf('start-done')), reason: '$log');
    expect(log.indexOf('start-done'), greaterThanOrEqualTo(0), reason: '$log');
    // No saved profile here, so the revive degrades to the held-params
    // `reconnect` command; with one it is a `connect`. Either follows forget.
    final redialAt = log.indexWhere(
      (l) => l == 'cmd:connect' || l == 'cmd:reconnect',
    );
    expect(redialAt, greaterThan(forgetAt), reason: '$log');
  });
}
