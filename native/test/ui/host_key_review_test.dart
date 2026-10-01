// #1235: the CHANGED host-key review dialog and its Review action.
//
// The dialog is the only door to re-trusting a rotated key, so it must show
// both fingerprints in full (monospace), warn plainly, say how to verify on the
// server, default to Cancel, and style Forget as destructive.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/ui/host_key_review.dart';

const _stored = '6806a18e0f1d2c3b4a5968778695a4b3';
const _offered = '24bdc2e0aa11bb22cc33dd44ee55ff66';

const _mismatch = HostKeyMismatch(
  host: 'nv-dev.tailbe5094.ts.net',
  port: 22,
  keyType: 'ssh-ed25519',
  storedFingerprint: _stored,
  offeredFingerprint: _offered,
);

Future<bool?> _open(WidgetTester tester, HostKeyMismatch m) async {
  bool? result;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            result = await showHostKeyMismatchDialog(context, mismatch: m);
          },
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return result;
}

void main() {
  testWidgets('shows both fingerprints in full, monospace, plus the warning',
      (tester) async {
    await _open(tester, _mismatch);

    expect(find.byKey(const Key('hostkey-mismatch-dialog')), findsOneWidget);
    expect(find.textContaining('nv-dev.tailbe5094.ts.net:22'), findsWidgets);
    for (final (key, fp) in [
      ('hostkey-mismatch-stored', _stored),
      ('hostkey-mismatch-offered', _offered),
    ]) {
      final text = tester.widget<SelectableText>(find.byKey(Key(key)));
      expect(text.data, fp, reason: 'full fingerprint, never truncated');
      expect(text.style?.fontFamily, 'monospace');
    }
    expect(find.textContaining('man-in-the-middle'), findsOneWidget);
    expect(
      find.textContaining(
        'ssh-keygen -l -f /etc/ssh/ssh_host_ed25519_key.pub',
      ),
      findsOneWidget,
      reason: 'since #1226 a CHANGED key is SHA256 vs SHA256 (legacy MD5 '
          're-confirms instead), and plain ssh-keygen -l prints SHA256',
    );
    expect(find.textContaining('MD5'), findsNothing);
    expect(find.textContaining('SHA256'), findsWidgets);
  });

  testWidgets('Cancel is the default and returns false', (tester) async {
    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showHostKeyMismatchDialog(
                context,
                mismatch: _mismatch,
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final cancel = tester.widget<TextButton>(
      find.byKey(const Key('hostkey-mismatch-cancel')),
    );
    expect(cancel.autofocus, isTrue, reason: 'Cancel is the default action');
    final forget = tester.widget<FilledButton>(
      find.byKey(const Key('hostkey-mismatch-forget')),
    );
    expect(forget.autofocus, isFalse);
    expect(find.text('Forget old key and reconnect'), findsOneWidget);

    await tester.tap(find.byKey(const Key('hostkey-mismatch-cancel')));
    await tester.pumpAndSettle();
    expect(result, isFalse);
    expect(find.byKey(const Key('hostkey-mismatch-dialog')), findsNothing);
  });

  testWidgets('Forget returns true', (tester) async {
    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showHostKeyMismatchDialog(
                context,
                mismatch: _mismatch,
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('hostkey-mismatch-forget')));
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });

  testWidgets('a jump-hop mismatch names the hop', (tester) async {
    await _open(
      tester,
      const HostKeyMismatch(
        host: 'bastion.example',
        port: 2222,
        keyType: 'ssh-rsa',
        storedFingerprint: _stored,
        offeredFingerprint: _offered,
        jumpHop: true,
      ),
    );
    expect(find.textContaining('Jump host bastion.example:2222'), findsOneWidget);
    expect(find.textContaining('ssh_host_rsa_key.pub'), findsOneWidget);
  });

  group('Review action visibility', () {
    Widget host(SshSessionData data) => MaterialApp(
      home: Scaffold(
        body: HostKeyReviewAction(
          sessionId: 'sid',
          data: data,
          onForget: (_) {},
        ),
      ),
    );

    testWidgets('present for a failed session with a mismatch', (tester) async {
      await tester.pumpWidget(
        host(
          const SshSessionData(
            state: SshSessionState.failed,
            hostKeyMismatch: _mismatch,
          ),
        ),
      );
      expect(find.byKey(const Key('hostkey-review-sid')), findsOneWidget);
      expect(find.text('Host key changed — Review'), findsOneWidget);
    });

    testWidgets('kept after the service-stop disconnect', (tester) async {
      await tester.pumpWidget(
        host(
          const SshSessionData(
            state: SshSessionState.disconnected,
            hostKeyMismatch: _mismatch,
          ),
        ),
      );
      expect(find.byKey(const Key('hostkey-review-sid')), findsOneWidget);
    });

    testWidgets('absent while re-dialing', (tester) async {
      await tester.pumpWidget(
        host(
          const SshSessionData(
            state: SshSessionState.reconnecting,
            hostKeyMismatch: _mismatch,
          ),
        ),
      );
      expect(find.byKey(const Key('hostkey-review-sid')), findsNothing);
    });

    testWidgets('absent for any other failure', (tester) async {
      await tester.pumpWidget(
        host(
          const SshSessionData(
            state: SshSessionState.failed,
            error: 'TCP connect failed',
          ),
        ),
      );
      expect(find.byKey(const Key('hostkey-review-sid')), findsNothing);
    });

    testWidgets('Cancel in the review is a no-op', (tester) async {
      final forgotten = <HostKeyMismatch>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HostKeyReviewAction(
              sessionId: 'sid',
              data: const SshSessionData(
                state: SshSessionState.failed,
                hostKeyMismatch: _mismatch,
              ),
              onForget: forgotten.add,
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('hostkey-review-sid')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('hostkey-mismatch-cancel')));
      await tester.pumpAndSettle();
      expect(forgotten, isEmpty);

      await tester.tap(find.byKey(const Key('hostkey-review-sid')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('hostkey-mismatch-forget')));
      await tester.pumpAndSettle();
      expect(forgotten, [_mismatch]);
    });
  });
}
