// #1197 (slice 2 of #1195) — the extracted-link OPEN path. Spec:
// `docs/link-browser-routing.md` R9/R11, test A7.
//
// PINNED API (`lib/ui/url_action_overlay.dart`):
//   Future<BrowserOpenResult> openDetectedUrl(String url,
//                                             {LinkBrowserContext? browser})
//   void showUrlActions(context, url, {..., LinkBrowserContext? browser})
//
// R11: when the chosen browser was missing the user is TOLD, where the action
// was — a link that silently opens in the wrong browser is the exact failure
// this feature exists to remove.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobissh/services/browser_targets.dart';
import 'package:mobissh/services/link_browser_router.dart';
import 'package:mobissh/ui/url_action_overlay.dart';

const _url = 'https://example.com/path';
const _chrome = BrowserTarget(
  package: 'com.android.chrome',
  label: 'Chrome',
  isDefault: true,
);
const _prisma = BrowserTarget(package: 'com.work.prisma', label: 'Prisma');

LinkBrowserContext _context(
  FakeBrowserTargets targets,
  String? package, {
  String? sessionId,
}) => LinkBrowserContext(
  LinkBrowserRouter(targets: targets, packageFor: (_) => package),
  sessionId: sessionId,
);

Future<void> _pumpAndOpen(
  WidgetTester tester,
  LinkBrowserContext browser,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => showUrlActions(
                context,
                _url,
                highlightRects: const [Rect.fromLTWH(40, 40, 120, 18)],
                anchor: const Offset(100, 60),
                browser: browser,
              ),
              child: const Text('show'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('show'));
  await tester.pump();
  await tester.tap(find.byKey(const Key('url-action-open')));
  await tester.pump();
  await tester.pump();
}

Future<void> _settle(WidgetTester tester) async {
  debugDismissUrlActions();
  await tester.pump();
  await tester.pump(const Duration(seconds: 3));
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => debugUrlOpenerOverride = null);
  tearDown(() => debugUrlOpenerOverride = null);

  group('A7 — the menu Open action routes and reports (R9/R11)', () {
    testWidgets('opens in the session\'s chosen browser', (tester) async {
      final targets = FakeBrowserTargets(targets: const [_chrome, _prisma]);
      await _pumpAndOpen(tester, _context(targets, 'com.work.prisma'));

      expect(targets.opens, hasLength(1));
      expect(targets.opens.single.url, _url);
      expect(targets.opens.single.package, 'com.work.prisma');
      await _settle(tester);
    });

    testWidgets('a missing browser still opens AND is named to the user',
        (tester) async {
      // Prisma is chosen but NOT installed → the platform falls back.
      final targets = FakeBrowserTargets(targets: const [_chrome]);
      await _pumpAndOpen(tester, _context(targets, 'com.work.prisma'));
      await tester.pump();

      expect(targets.opens.single.package, 'com.work.prisma');
      expect(
        find.textContaining('com.work.prisma'),
        findsOneWidget,
        reason: 'R11 — the user is told WHICH browser was missing',
      );
      await _settle(tester);
    });

    testWidgets('a normal open shows no fallback message', (tester) async {
      final targets = FakeBrowserTargets(targets: const [_chrome]);
      await _pumpAndOpen(tester, _context(targets, 'com.android.chrome'));
      await tester.pump();

      expect(find.textContaining('default browser'), findsNothing);
      await _settle(tester);
    });

    testWidgets('no browser context → today\'s system-default behaviour',
        (tester) async {
      // No LinkBrowserContext and no override: the single launchExternalUrl
      // path. Pinned by the debug override so the test never leaves the app.
      final launched = <String>[];
      debugUrlOpenerOverride = (u) async {
        launched.add(u);
        return true;
      };
      final result = await openDetectedUrl(_url);
      expect(launched, [_url]);
      expect(result.opened, isTrue);
      expect(result.usedFallback, isFalse);
    });
  });

  group('A7 — openDetectedUrl seam', () {
    test('passes the context\'s sessionId through to the resolver', () async {
      final seen = <String?>[];
      final targets = FakeBrowserTargets(targets: const [_prisma]);
      final router = LinkBrowserRouter(
        targets: targets,
        packageFor: (sessionId) {
          seen.add(sessionId);
          return 'com.work.prisma';
        },
      );
      await openDetectedUrl(
        _url,
        browser: LinkBrowserContext(router, sessionId: 'sess-a'),
      );
      expect(seen, ['sess-a']);
      expect(targets.opens.single.package, 'com.work.prisma');
    });

    test('the debug override still wins (existing test seam)', () async {
      final targets = FakeBrowserTargets(targets: const [_prisma]);
      debugUrlOpenerOverride = (_) async => true;
      final result = await openDetectedUrl(
        _url,
        browser: _context(targets, 'com.work.prisma'),
      );
      expect(result.opened, isTrue);
      expect(targets.opens, isEmpty);
    });
  });
}
