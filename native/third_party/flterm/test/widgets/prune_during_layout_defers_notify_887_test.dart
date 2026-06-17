@Tags(['ffi'])
library;

// #887 cycle 2 — REGRESSION pin: the controller's per-redraw detection prune /
// `_onTerminalChanged` tail must NOT run its rebuild/geometry side-effects
// synchronously when the terminal notify arrives DURING a frame's layout/paint
// phase.
//
// MECHANISM (reproduced on emulator in sftp_browse_smoke_test, pinned here
// headless): libghostty's `Terminal.resize` is invoked synchronously from
// `TerminalRenderBox.performLayout` when the grid is re-sized (the SFTP browser
// opens / the keyboard inset changes the layout). That resize fires the
// terminal listener mid-frame -> `TerminalControllerImpl._onTerminalChanged`,
// whose notify-producing tail is illegal during layout/paint:
//   1. the controller's general `notifyListeners()` (via `highlights=` in the
//      prune, or the `changed` notify) -> `_TerminalViewState._onController
//      Changed` -> `_updateTextInputGeometry` reads `RenderBox.size`
//      (`getTransformTo`) + a `setState` -> "RenderBox.size accessed beyond the
//      scope of resize, layout…" / "Build scheduled during frame".
//   2. `_DecorationNotifier.notify()` -> a decorator `AnimatedBuilder`/setState
//      rebuild scheduled mid-frame -> "Build scheduled during frame".
//
// The fix: when `SchedulerBinding.schedulerPhase` is mid-frame
// (`persistentCallbacks`/`midFrameMicrotasks`) `_onTerminalChanged` DEFERS that
// whole tail to a post-frame callback. The synchronous path is kept for the
// normal (non-layout) notify so #873 eviction stays immediate when safe.
//
// This test asserts the GUARD as a binding-portable INVARIANT: it records the
// scheduler phase at every controller notify AND every decoration notify, then
// forces a real grid resize from `performLayout` (with a live URL anchor) and
// requires that NEITHER notify ever lands while a frame is mid-layout/paint
// (`persistentCallbacks`/`midFrameMicrotasks`). With the fix any such notify is
// deferred to `idle` (post-frame).
//
// AUTHORITATIVE RED BASELINE: the device-class repro is the on-emulator
// `integration_test/sftp_browse_smoke_test.dart`, where opening the SFTP
// browser resizes the grid WHILE shell output is streaming — that timing
// coincidence makes `_onTerminalChanged` emit its `changed`/decoration notify
// mid-layout and throws "Build scheduled during frame" / "RenderBox.size
// accessed beyond the scope…". It was GREEN on +58, RED on the #887 cycle-1
// branch, and GREEN again with this guard. `AutomatedTestWidgetsFlutterBinding`
// fires the resize notify but a PURE resize never sets the prune `changed` flag
// (#883 keeps shifted-frame matches rather than dropping them) so it cannot
// stage the streaming-output coincidence deterministically — hence the emulator
// suite, not this headless test, is the regression gate. This test still guards
// the invariant against any future binding/path that DOES emit mid-frame.

import 'dart:typed_data';

import 'package:flterm/src/foundation.dart';
import 'package:flterm/src/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'a terminal notify arriving mid-layout (grid resize from performLayout) '
    'defers its general + decoration notify out of the layout/paint phase (#887)',
    (tester) async {
      final controller = TerminalController();
      addTearDown(controller.dispose);

      // A live structured-text anchor so the prune has a non-empty match set to
      // operate on and the decoration/highlight side-effects are reachable.
      controller.registerTextPattern(TextPattern.url());

      // Record the scheduler phase at EVERY notify. A notify that fires while a
      // frame is mid-layout/paint (`persistentCallbacks`/`midFrameMicrotasks`)
      // is the #887 hazard — that is exactly when reading RenderBox.size or
      // scheduling a build throws.
      final controllerNotifyPhases = <SchedulerPhase>[];
      final decorationNotifyPhases = <SchedulerPhase>[];
      controller.addListener(
        () => controllerNotifyPhases
            .add(SchedulerBinding.instance.schedulerPhase),
      );
      controller.decorationListenable.addListener(
        () => decorationNotifyPhases
            .add(SchedulerBinding.instance.schedulerPhase),
      );

      // Drive a REAL TerminalView whose constraints we can change, so a pump
      // re-runs `performLayout` -> grid resize -> `Terminal.resize` ->
      // synchronous terminal notify mid-frame (the exact device trigger).
      var width = 800.0;
      var height = 480.0;
      late StateSetter setOuter;
      Widget app() {
        return MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                setOuter = setState;
                return Center(
                  child: SizedBox(
                    width: width,
                    height: height,
                    child: TerminalView(controller: controller),
                  ),
                );
              },
            ),
          ),
        );
      }

      await tester.pumpWidget(app());
      await tester.pump();

      // Print a long URL near the right edge so SHRINKING the width re-wraps it
      // across a different column boundary — that reflow moves/drops the match
      // in the prune (`changed`), exercising the prune's `highlights=` general
      // notify + `_decorationNotifier.notify()` (the throwing side-effects). Let
      // the detection debounce (~120ms) settle so a live anchor exists first.
      controller.write(
        Uint8List.fromList(
          'open https://example.com/some/fairly/long/path/segment/here now\r\n'
              .codeUnits,
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));
      expect(
        controller.highlights,
        isNotEmpty,
        reason: 'precondition: a live URL anchor exists for the prune to act on',
      );

      // Clear the phases captured during normal (non-layout) operation; we only
      // care about notifies provoked by the resize-during-layout below.
      controllerNotifyPhases.clear();
      decorationNotifyPhases.clear();

      // Shrink BOTH dimensions substantially -> the TerminalView gets new
      // constraints -> `performLayout` re-derives fewer grid cols AND rows ->
      // `Terminal.resize` fires the terminal listener SYNCHRONOUSLY mid-frame
      // (the exact device trigger). The narrower grid re-wraps the URL, so the
      // prune relocates/drops the match and runs its `highlights=`/decoration
      // notify — the side-effects that throw if not deferred.
      setOuter(() {
        width = 320.0;
        height = 160.0;
      });
      await tester.pump();

      // A notify scheduled mid-layout/paint also surfaces a framework assertion;
      // capture it as a second signal.
      final resizeException = tester.takeException();

      // Drain the deferred post-frame work + the (re)armed detection debounce so
      // no FakeTimer is left pending at test end and the reconcile completes.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      bool midFrame(SchedulerPhase p) =>
          p == SchedulerPhase.persistentCallbacks ||
          p == SchedulerPhase.midFrameMicrotasks;

      // THE #887 ASSERTIONS: no notify (general or decoration) provoked by the
      // resize fired during the layout/paint phase. Pre-fix the resize notify
      // lands at `persistentCallbacks`; post-fix it is deferred to `idle`.
      expect(
        controllerNotifyPhases.where(midFrame),
        isEmpty,
        reason: 'the controller general notify (highlights=/changed) must be '
            'deferred out of the layout/paint phase when _onTerminalChanged '
            'fires from performLayout (#887). Phases: $controllerNotifyPhases',
      );
      expect(
        decorationNotifyPhases.where(midFrame),
        isEmpty,
        reason: 'the decoration notify must be deferred out of the layout/paint '
            'phase when _onTerminalChanged fires from performLayout (#887). '
            'Phases: $decorationNotifyPhases',
      );
      expect(
        resizeException,
        isNull,
        reason: 'no "Build scheduled during frame" / "RenderBox.size beyond the '
            'scope" assertion from the resize frame (#887). Got: '
            '$resizeException',
      );

      // The reconcile still happens — the anchor survives the resize reflow
      // rather than being silently dropped or left un-notified.
      expect(
        controller.highlights,
        isNotEmpty,
        reason: 'the URL anchor is re-anchored after the resize reflow, not lost',
      );
    },
  );
}
