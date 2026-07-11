// On-emulator PROOF for #1031 slice 3 — USER-DEFINED patterns end-to-end.
//
// Flow: connect to test-sshd → session menu → long-press the detection glyph
// → lab root → "Add pattern" → create a JIRA-style pattern (name, regex,
// sample line; the editor's live match echo validates it) → back to the live
// terminal → echo a matching token → assert the custom anchor appears with
// the BUBBLE wash + a GUTTER chip → tap the chip and assert the payload is
// COPIED (toast) → long-press the match and report "Not a match" → assert
// the affordances disappear (#995 suppression, family = the custom id) →
// delete the pattern in the lab (confirm discloses the pruning) → assert a
// fresh token no longer detects (live re-registration removed the pattern).
//
// Screenshot windows (the orchestrator runs `scripts/emu-shot.sh <label>`
// while each marker window is open):
//   CUSTOM1031_SHOT_EDITOR_OPEN — the creation flow (live match echo)
//   CUSTOM1031_SHOT_LIVE_OPEN   — the custom anchor live (bubble + chip)
//
// Bridge: scripts/native-connect-test.sh (127.0.0.1:2222 → socat → test-sshd).
// Run: scripts/native-connect-test.sh integration_test/detection_lab_custom_1031_test.dart

import 'dart:convert';
import 'dart:typed_data';

import 'package:flterm/flterm.dart' hide Key;
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/state/custom_patterns_providers.dart';
import 'package:mobissh/state/detection_exceptions_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/ui/ghostty_terminal_view.dart';

import 'support/connect_helpers.dart';

Future<void> _pumps(WidgetTester tester, int count, [int ms = 100]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(Duration(milliseconds: ms));
  }
}

Future<void> _shotWindow(
  WidgetTester tester,
  String label, {
  int halfSeconds = 45,
}) async {
  debugPrint('CUSTOM1031_SHOT_${label}_OPEN');
  for (var i = 0; i < halfSeconds; i++) {
    await tester.pump(const Duration(milliseconds: 500));
  }
  debugPrint('CUSTOM1031_SHOT_${label}_CLOSED');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'user-defined pattern: create → detect → copy → suppress → delete '
    '(#1031 slice 3)',
    (tester) async {
      FlutterForegroundTask.initCommunicationPort();

      final container = ProviderContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MobisshApp(),
        ),
      );
      await tester.pump(const Duration(seconds: 1));

      await adhocPasswordConnect(
        tester,
        host: '127.0.0.1',
        port: '2222',
        user: 'testuser',
        pass: 'testpass',
      );

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

      final entry = container.read(sessionsProvider).active;
      expect(entry, isNotNull, reason: 'no active session after connect');
      final sessionId = entry!.id;

      TerminalController? controllerOf() =>
          GhosttyTerminalView.debugControllers[sessionId];
      for (var i = 0; i < 40 && controllerOf() == null; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      final controller = controllerOf();
      expect(controller, isNotNull, reason: 'no ghostty controller');

      // Wait for a live shell.
      final out = <int>[];
      final sub = entry.proxy.output.listen(out.addAll);
      addTearDown(sub.cancel);
      for (var i = 0; i < 40 && out.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(out.isNotEmpty, isTrue, reason: 'no shell prompt — dead PTY');

      // 1. CREATE: session menu → long-press detection glyph → lab root →
      // Add pattern.
      await tester.tap(find.byKey(const Key('session-menu-button')));
      await _pumps(tester, 8);
      await tester.longPress(
        find.byKey(const Key('session-menu-detection-toggle')),
      );
      await _pumps(tester, 10);
      expect(find.byKey(const Key('lab-add-pattern')), findsOneWidget,
          reason: 'lab root must offer Add pattern');
      await tester.scrollUntilVisible(
        find.byKey(const Key('lab-add-pattern')),
        200,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('detection-lab-list')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(find.byKey(const Key('lab-add-pattern')));
      await _pumps(tester, 10);

      await tester.enterText(
        find.byKey(const Key('lab-custom-name')),
        'Jira tickets',
      );
      await tester.enterText(
        find.byKey(const Key('lab-custom-regex')),
        r'\b[A-Z]{2,}-\d+\b',
      );
      await tester.enterText(
        find.byKey(const Key('lab-custom-sample')),
        'fixed in MOBI-4242 yesterday',
      );
      await _pumps(tester, 5);
      // The live echo names the match — the creation-flow validation surface.
      expect(find.textContaining('MOBI-4242'), findsWidgets);

      await _shotWindow(tester, 'EDITOR');

      await tester.tap(find.byKey(const Key('lab-custom-save')));
      await _pumps(tester, 10);

      final patterns = container.read(customPatternsProvider);
      expect(patterns, hasLength(1), reason: 'save must persist the pattern');
      final patternId = patterns.single.id;
      expect(find.byKey(Key('lab-card-$patternId')), findsOneWidget,
          reason: 'the new pattern gets a MY PATTERNS card');

      // Back to the live terminal (lab root → terminal).
      await tester.pageBack();
      await _pumps(tester, 12, 250);

      // 2. DETECT: echo a matching token; the live re-registration (customs
      // listen) must pick it up with NO reconnect.
      const token = 'MOBI-1337';
      entry.proxy.sendInput(
        Uint8List.fromList(utf8.encode('echo ticket $token ok\n')),
      );
      bool tokenDetected() => controller!.anchors.any(
        (a) => a.patternId == patternId && '${a.payload}' == token,
      );
      for (var i = 0; i < 40 && !tokenDetected(); i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(tokenDetected(), isTrue,
          reason: 'custom anchor never appeared for $token');

      // Wash + gutter chip both render for the custom anchor. #1045: the wash
      // is the controller's styled highlight bake (painted by the fork behind
      // the glyphs), so assert the custom match carries a styled range.
      bool customWashBaked() => controller!.highlights.any(
        (r) => r.payload == token && r.background != null && r.capsule,
      );
      for (var i = 0; i < 20 && !customWashBaked(); i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(customWashBaked(), isTrue,
          reason: 'custom span anchors must bake the capsule wash');
      bool anyGutterMark() => find
          .byWidgetPredicate(
            (w) => w.key is Key && '${w.key}'.contains('gutter-mark-'),
          )
          .evaluate()
          .isNotEmpty;
      for (var i = 0; i < 20 && !anyGutterMark(); i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(anyGutterMark(), isTrue, reason: 'no gutter chip for the anchor');

      await _shotWindow(tester, 'LIVE');

      // The custom anchor's geometry: its bubble rects (Stack coordinates —
      // the keyed terminal Stack IS the bubble layer's origin) and its OWN
      // gutter row (the typed `echo …` line above carries a second anchor
      // for the same token on a different row).
      final anchor = controller!.anchors.firstWhere(
        (a) => a.patternId == patternId && '${a.payload}' == token,
      );
      final gutterRow = anchor.ranges
          .map(controller.anchorGutterRow)
          .whereType<int>()
          .first;
      final rects = <Rect>[];
      for (final range in anchor.ranges) {
        rects.addAll(controller.anchorRects(range));
      }
      expect(rects, isNotEmpty, reason: 'anchor has no on-screen rects');
      final termRect =
          tester.getRect(find.byKey(Key('ghostty-terminal-$sessionId')));

      // 3. COPY: a glass TAP on the match copies its payload (the IA's v1
      // "Copy match" tap action; same path as URL tap-copy, #726).
      await tester.tapAt(termRect.topLeft + rects.first.center);
      await _pumps(tester, 10);
      expect(find.text('Copied match'), findsOneWidget,
          reason: 'a tap on the custom match must copy its payload');
      // Let the toast clear before the next gesture.
      await _pumps(tester, 20, 250);

      // 4. SUPPRESS: the gutter chip opens the generic action menu (the ONLY
      // plain-shell "Not a match" surface — the long-press match menu is
      // mouse-mode-only) → report → affordances disappear.
      await tester.tap(
        find.byKey(Key('gutter-mark-$gutterRow')),
        // The mark's hit target extends beyond its painted chip; the tap
        // lands (the copy path proved it) but the strict center check warns.
        warnIfMissed: false,
      );
      await _pumps(tester, 10);
      expect(find.byKey(const Key('url-action-menu')), findsOneWidget,
          reason: 'the custom chip must open the generic action menu');
      expect(find.text('Not a match'), findsOneWidget,
          reason: 'a custom match reports as "Not a match", not "Not a URL"');
      expect(find.byKey(const Key('url-action-open')), findsNothing,
          reason: 'no browser Open for an arbitrary token');
      await tester.tap(find.byKey(const Key('url-action-not-url')));
      await _pumps(tester, 12, 250);
      expect(
        container
            .read(detectionExceptionsProvider)
            .any((e) => e.family == patternId && e.matchedText == token),
        isTrue,
        reason: 'the report must persist under the custom family',
      );
      expect(find.byKey(Key('gutter-mark-$gutterRow')), findsNothing,
          reason: '"Not a match" must remove the row\'s chip immediately');

      // 5. DELETE: lab → card → detail → delete (confirm discloses pruning) →
      // affordances gone and a NEW token no longer detects.
      await tester.tap(find.byKey(const Key('session-menu-button')));
      await _pumps(tester, 8);
      await tester.longPress(
        find.byKey(const Key('session-menu-detection-toggle')),
      );
      await _pumps(tester, 10);
      await tester.scrollUntilVisible(
        find.byKey(Key('lab-card-tile-$patternId')),
        200,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('detection-lab-list')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(find.byKey(Key('lab-card-tile-$patternId')));
      await _pumps(tester, 10);
      await tester.scrollUntilVisible(
        find.byKey(const Key('lab-custom-delete-button')),
        200,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('lab-detail-controls')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(find.byKey(const Key('lab-custom-delete-button')));
      await _pumps(tester, 10);
      // Review change 5: the confirm DISCLOSES the exception pruning.
      expect(find.textContaining('saved detection exception'), findsOneWidget);
      await tester.tap(find.byKey(const Key('lab-custom-delete-confirm')));
      await _pumps(tester, 12, 250);
      expect(container.read(customPatternsProvider), isEmpty);
      expect(
        container
            .read(detectionExceptionsProvider)
            .any((e) => e.family == patternId),
        isFalse,
        reason: 'delete must prune the pattern\'s exception family',
      );
      expect(find.byKey(Key('lab-card-$patternId')), findsNothing);

      // Back to the terminal; a fresh token must NOT detect any more.
      await tester.pageBack();
      await _pumps(tester, 12, 250);
      const token2 = 'MOBI-9999';
      entry.proxy.sendInput(
        Uint8List.fromList(utf8.encode('echo later $token2 end\n')),
      );
      var seen2 = false;
      for (var i = 0; i < 16; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (utf8.decode(out, allowMalformed: true).contains(token2)) {
          seen2 = true;
        }
      }
      expect(seen2, isTrue, reason: 'the follow-up echo never landed');
      expect(
        controller.anchors.any((a) => a.patternId == patternId),
        isFalse,
        reason: 'a deleted pattern must not anchor new output',
      );
    },
  );
}
