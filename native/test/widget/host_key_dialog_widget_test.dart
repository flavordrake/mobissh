// Widget tests for the host-key trust prompt (#505 backfill).
//
// Characterizes `showHostKeyDialog` (lib/ui/host_key_dialog.dart) directly —
// the dialog the chooser pops on a trust-on-first-use challenge. Existing tests
// only hit it INDIRECTLY (profile_chooser_test's relocation guard); this file
// locks the dialog's own contract:
//
//   1. It renders host:port, the key type, and the fingerprint VERBATIM
//      (the human verifies the fingerprint, so it must be shown exactly).
//   2. "Trust + connect" and "Cancel" buttons are rendered.
//   3. Tapping "Trust + connect" resolves the Future<bool> with true (accept →
//      caller records trust + proceeds).
//   4. Tapping "Cancel" resolves with false (reject → caller cancels).
//   5. The prompt is FORCED: it is a non-dismissible barrier, so tapping outside
//      does NOT auto-dismiss/auto-accept it (mirrors the auth/host-key emulator
//      expectation that the prompt must be forced and explicitly answered).
//
// No providers/network needed — `showHostKeyDialog` is a pure showDialog wrapper
// over a PendingHostKey value object.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/ui/host_key_dialog.dart';

const _pending = PendingHostKey(
  host: 'server.example',
  port: 2222,
  keyType: 'ssh-ed25519',
  fingerprint: 'SHA256:abcDEF123+ghi/jklMNO456pqrSTU789vwxYZ0',
);

/// Pump a launcher that opens the dialog on a button tap and captures the
/// resolved `Future<bool>`. Returns a getter for the result (null while pending).
Future<Future<bool?> Function()> _mountDialog(
  WidgetTester tester, {
  PendingHostKey pending = _pending,
}) async {
  bool? result;
  bool resolved = false;

  Future<bool?> readResult() async {
    return resolved ? result : null;
  }

  // A host with a button that opens the dialog; we tap it to launch so the
  // dialog has a real Navigator/Overlay context.
  late BuildContext dialogContext;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) {
            dialogContext = ctx;
            return Center(
              child: ElevatedButton(
                key: const Key('launch'),
                onPressed: () async {
                  final r = await showHostKeyDialog(
                    dialogContext,
                    pending: pending,
                  );
                  result = r;
                  resolved = true;
                },
                child: const Text('launch'),
              ),
            );
          },
        ),
      ),
    ),
  );

  return readResult;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('renders host:port, key type, and fingerprint verbatim', (
    tester,
  ) async {
    await _mountDialog(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('launch')));
    await tester.pumpAndSettle();

    // host:port shown exactly.
    expect(find.text('server.example:2222'), findsOneWidget);
    // Key type shown.
    expect(find.text('Key type: ssh-ed25519'), findsOneWidget);
    // Fingerprint shown VERBATIM — the user compares this against the server's
    // expected fingerprint, so a single transformed char would be a real bug.
    expect(find.text(_pending.fingerprint), findsOneWidget);

    // Both actions rendered.
    expect(find.text('Trust + connect'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
  });

  testWidgets('tapping "Trust + connect" resolves the Future with true', (
    tester,
  ) async {
    final readResult = await _mountDialog(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('launch')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Trust + connect'));
    await tester.pumpAndSettle();

    expect(await readResult(), isTrue);
    // Dialog is gone after answering.
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('tapping "Cancel" resolves the Future with false', (
    tester,
  ) async {
    final readResult = await _mountDialog(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('launch')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(await readResult(), isFalse);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets(
    'prompt is FORCED: tapping outside the barrier does not dismiss it',
    (tester) async {
      final readResult = await _mountDialog(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('launch')));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);

      // Tap the top-left corner (outside the dialog, on the modal barrier).
      // barrierDismissible:false means this must NOT close the dialog and must
      // NOT silently resolve the Future — the host-key decision can only be
      // made by an explicit Trust/Cancel tap.
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();

      expect(
        find.byType(AlertDialog),
        findsOneWidget,
        reason: 'host-key prompt must be forced (non-dismissible barrier)',
      );
      expect(
        await readResult(),
        isNull,
        reason: 'barrier tap must not resolve the trust decision',
      );

      // Clean up so the test binding doesn't flag a pending dialog route.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await readResult(), isFalse);
    },
  );

  // #1226: a saved legacy MD5 fingerprint can't be compared with the SHA256
  // the server now reports. The re-confirm is a DISTINCT, forced warning — not
  // the first-contact wording, not a toast.
  group('format-changed re-confirm variant (#1226)', () {
    const reconfirm = PendingHostKey(
      host: 'server.example',
      port: 2222,
      keyType: 'ssh-ed25519',
      fingerprint: 'SHA256:abcDEF123+ghi/jklMNO456pqrSTU789vwxYZ0',
      formatChanged: true,
    );

    testWidgets('renders the older-format warning with the SHA256 verbatim', (
      tester,
    ) async {
      await _mountDialog(tester, pending: reconfirm);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('launch')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('host-key-reconfirm-dialog')), findsOneWidget);
      expect(
        find.textContaining(
          'The saved key for server.example:2222 uses an older fingerprint '
          "format and can't be compared.",
        ),
        findsOneWidget,
      );
      expect(find.text(reconfirm.fingerprint), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
      expect(find.text('Trust + connect'), findsNothing,
          reason: 'distinct from the first-contact prompt');
      expect(find.text('Confirm + connect'), findsOneWidget);
    });

    testWidgets('Confirm resolves true, Cancel resolves false', (tester) async {
      var readResult = await _mountDialog(tester, pending: reconfirm);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('launch')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm + connect'));
      await tester.pumpAndSettle();
      expect(await readResult(), isTrue);

      readResult = await _mountDialog(tester, pending: reconfirm);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('launch')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await readResult(), isFalse);
    });
  });
}
