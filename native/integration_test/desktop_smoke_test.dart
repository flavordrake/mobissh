// Desktop (Linux) E2E smoke — Phase 0 of the desktop-targets arc (#1012).
//
// Runs ON THE HOST, no emulator/adb: scripts/desktop-smoke.sh drives
// `flutter test integration_test/desktop_smoke_test.dart -d linux` under Xvfb.
// The host process reaches test-sshd DIRECTLY over the docker network
// (test-sshd:22) — no socat bridge, no adb reverse. Host/port are injectable
// via --dart-define (SMOKE_HOST / SMOKE_PORT) for other environments; the
// Android smokes hardcode 127.0.0.1:2222 because they run inside the emulator.
//
// What this proves (the #577 desktop path, end-to-end):
//   - taskSshGatewayProvider resolves the IN-PROCESS SessionHost (no
//     flutter_foreground_task, no task isolate — kIsDesktop gates FFT off).
//   - dartssh2 connects directly over dart:io.
//   - libghostty's prebuilt linux .so loads and the terminal renders — the
//     same download+FFI path macOS will use with its dylib.
//
// Mirrors shell_bytes_smoke_test.dart: prompt bytes must arrive, and a typed
// command must echo back through the proxy round-trip.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/state/profiles_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/storage/secrets_store.dart';

import 'support/connect_helpers.dart';

const _host = String.fromEnvironment('SMOKE_HOST', defaultValue: 'test-sshd');
const _port = String.fromEnvironment('SMOKE_PORT', defaultValue: '22');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('desktop in-process host connects and streams shell bytes', (
    tester,
  ) async {
    // NO FlutterForegroundTask.initCommunicationPort() here — that's the
    // Android smoke's bootstrap. On desktop the plugin isn't registered and
    // the SessionHost is hosted in-process (#577).
    //
    // PHASE 0 FINDING (#1012): the real vault (flutter_secure_storage_linux →
    // libsecret) throws "Failed to unlock the keyring" in a headless container
    // — there is no Secret Service / gnome-keyring on this box. A real Linux
    // desktop session provides one; macOS uses the Keychain (no daemon
    // dependency). The smoke overrides the secrets store with the in-memory
    // backend so it exercises SSH + rendering, not keyring availability.
    // Graceful app-level handling of a missing Secret Service is follow-up UX.
    final container = ProviderContainer(
      overrides: [
        secretsStoreProvider.overrideWithValue(
          SecretsStore(backend: InMemorySecretsBackend()),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MobisshApp(),
      ),
    );
    await tester.pump(const Duration(seconds: 1));

    // Ad-hoc connect via "New connection" → editor → "Save & connect" (#583).
    await adhocPasswordConnect(
      tester,
      host: _host,
      port: _port,
      user: 'testuser',
      pass: 'testpass',
    );

    // Reach the terminal screen, accepting the host-key prompt if shown.
    var connected = false;
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      final accept = find.text('Trust + connect');
      if (accept.evaluate().isNotEmpty) {
        await tester.tap(accept.first);
        await tester.pump(const Duration(milliseconds: 300));
      }
      if (find.byKey(const Key('session-menu-button')).evaluate().isNotEmpty) {
        connected = true;
        break;
      }
    }
    expect(connected, isTrue, reason: 'never reached the terminal screen');

    // Capture everything the in-process host streams to the UI terminal.
    final entry = container.read(sessionsProvider).active;
    expect(entry, isNotNull, reason: 'no active session after connect');
    final out = <int>[];
    final sub = entry!.proxy.output.listen(out.addAll);
    addTearDown(sub.cancel);

    // 1) The shell must produce SOME output (a prompt) — proves the PTY opened
    //    and bytes flow through the in-process gateway pair.
    var gotPrompt = false;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (out.isNotEmpty) {
        gotPrompt = true;
        break;
      }
    }
    expect(
      gotPrompt,
      isTrue,
      reason: 'terminal received ZERO bytes after connect on desktop',
    );

    // 2) A typed command must echo back through the proxy round-trip.
    const marker = 'MOBISSH_DESKTOP_OK_1012';
    entry.proxy.sendInput(Uint8List.fromList(utf8.encode('echo $marker\n')));
    var sawMarker = false;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (utf8.decode(out, allowMalformed: true).contains(marker)) {
        sawMarker = true;
        break;
      }
    }
    expect(
      sawMarker,
      isTrue,
      reason: 'typed command never echoed back — input not routed to the PTY',
    );

    // Hold the final frame so the runner's display-capture watcher
    // (scripts/desktop-smoke.sh) grabs the rendered terminal with the echoed
    // marker visible — the screenshot IS the visual half of this smoke.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
  });
}
