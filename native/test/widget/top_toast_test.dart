// Top-toast helper (#667).
//
// All transient confirmations/errors used bottom-anchored Material SnackBars,
// which occlude the bottom controls (keybar / session bar / compose bar) — the
// premium control real estate on the terminal screen. [showTopToast] surfaces
// the same messages at the TOP instead.
//
// Contract under test:
//   - renders Key('top-toast') carrying the message text,
//   - is positioned in the TOP half of the screen (center y above mid),
//   - auto-dismisses after the given duration (pump past it → gone),
//   - tap-to-dismiss.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ui/top_toast.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Pump a trivial app and fire the toast from a button so we have a real
  // Overlay + MediaQuery in the tree.
  Future<void> pumpAndFire(
    WidgetTester tester,
    String message, {
    Duration duration = const Duration(seconds: 2),
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () =>
                    showTopToast(context, message, duration: duration),
                child: const Text('fire'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('fire'));
    await tester.pump(); // insert overlay entry
    await tester.pump(const Duration(milliseconds: 300)); // settle animation
  }

  testWidgets('renders Key(top-toast) with the message', (tester) async {
    await pumpAndFire(tester, 'Hello toast');
    expect(find.byKey(const Key('top-toast')), findsOneWidget);
    expect(find.text('Hello toast'), findsOneWidget);
  });

  testWidgets('is positioned in the TOP half of the screen', (tester) async {
    await pumpAndFire(tester, 'Top please');
    final screenH =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    final toastCenter = tester.getCenter(find.byKey(const Key('top-toast')));
    expect(
      toastCenter.dy,
      lessThan(screenH / 2),
      reason:
          'toast center y ${toastCenter.dy} must be above mid ${screenH / 2}',
    );
  });

  testWidgets('auto-dismisses after the duration', (tester) async {
    await pumpAndFire(
      tester,
      'Transient',
      duration: const Duration(seconds: 1),
    );
    expect(find.byKey(const Key('top-toast')), findsOneWidget);
    // Pump past duration + the exit animation.
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('top-toast')), findsNothing);
  });

  testWidgets('tap dismisses early', (tester) async {
    await pumpAndFire(tester, 'Tap me', duration: const Duration(seconds: 30));
    expect(find.byKey(const Key('top-toast')), findsOneWidget);
    await tester.tap(find.byKey(const Key('top-toast')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('top-toast')), findsNothing);
  });
}
