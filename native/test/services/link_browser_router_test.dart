// #1197 (slice 2 of #1195) — link-browser ROUTING. Spec:
// `docs/link-browser-routing.md` R8/R9/R11, tests A5/A6/A7.
//
// PINNED API (`lib/services/link_browser_router.dart`):
//   String? resolveLinkBrowserPackage({
//     required String? sessionId,
//     required String? activeSessionId,
//     required String? Function(String sessionId) profileKeyOf,
//     required String? Function(String profileKey) overrideOf,
//     required String? globalDefault,
//   })
//   class LinkBrowserRouter {
//     const LinkBrowserRouter({required BrowserTargets targets,
//                              required LinkBrowserPackageFor packageFor});
//     Future<BrowserOpenResult> open(String url, {String? sessionId});
//     Future<String> labelFor(String package);
//   }
//   class LinkBrowserContext { LinkBrowserContext(router, {sessionId}); }
//   Future<String?> linkBrowserFallbackMessage(
//       BrowserOpenResult result, LinkBrowserContext? browser)
//
// Every test runs against slice 1's `FakeBrowserTargets` (R3) — no channel,
// no real browser.

import 'package:flutter_test/flutter_test.dart';

import 'package:mobissh/services/browser_targets.dart';
import 'package:mobissh/services/link_browser_router.dart';

const _chrome = BrowserTarget(
  package: 'com.android.chrome',
  label: 'Chrome',
  isDefault: true,
);
const _prisma = BrowserTarget(package: 'com.work.prisma', label: 'Prisma');

void main() {
  group('A5 resolution order (R8): profile > global > system', () {
    String? resolve({
      String? sessionId = 'sess-a',
      String? override,
      String? globalDefault,
      String? profileKey = 'work.example:22:me',
    }) => resolveLinkBrowserPackage(
      sessionId: sessionId,
      activeSessionId: 'sess-a',
      profileKeyOf: (id) => id == 'sess-a' ? profileKey : null,
      overrideOf: (key) => key == profileKey ? override : null,
      globalDefault: globalDefault,
    );

    test('profile override wins over the global default', () {
      expect(
        resolve(override: 'com.work.prisma', globalDefault: 'com.android.chrome'),
        'com.work.prisma',
      );
    });

    test('global default applies when the profile has no override', () {
      expect(resolve(globalDefault: 'com.android.chrome'), 'com.android.chrome');
    });

    test('neither set → null = the system default', () {
      expect(resolve(), isNull);
    });

    test('an empty stored value is treated as unset, not as a package', () {
      expect(resolve(override: '', globalDefault: ''), isNull);
      expect(resolve(override: '', globalDefault: 'com.android.chrome'),
          'com.android.chrome');
    });

    test('a session with no known profile falls through to the global', () {
      expect(
        resolve(profileKey: null, globalDefault: 'com.android.chrome'),
        'com.android.chrome',
      );
    });
  });

  group('A6 isolation (R9): a link resolves against ITS session', () {
    // Two connected sessions on different profiles with different browsers.
    String? packageFor(String? sessionId) => resolveLinkBrowserPackage(
      sessionId: sessionId,
      activeSessionId: 'sess-b',
      profileKeyOf: (id) => switch (id) {
        'sess-a' => 'work.example:22:me',
        'sess-b' => 'home.example:22:me',
        _ => null,
      },
      overrideOf: (key) => switch (key) {
        'work.example:22:me' => 'com.work.prisma',
        'home.example:22:me' => 'com.android.chrome',
        _ => null,
      },
      globalDefault: null,
    );

    test('session A uses A\'s browser while B is connected with another', () {
      expect(packageFor('sess-a'), 'com.work.prisma');
      expect(packageFor('sess-b'), 'com.android.chrome');
    });

    test('no session context → the ACTIVE session (the visible terminal)', () {
      expect(packageFor(null), 'com.android.chrome');
    });

    test('the router passes the resolved package straight to BrowserTargets', () async {
      final targets = FakeBrowserTargets(targets: const [_chrome, _prisma]);
      final router = LinkBrowserRouter(targets: targets, packageFor: packageFor);

      await router.open('https://a.example', sessionId: 'sess-a');
      await router.open('https://b.example', sessionId: 'sess-b');
      await router.open('https://c.example');

      expect(targets.opens.map((o) => o.package).toList(), [
        'com.work.prisma',
        'com.android.chrome',
        'com.android.chrome',
      ]);
      expect(targets.opens.first.url, 'https://a.example');
    });
  });

  group('A7 missing package (R11): opens anyway AND names what was missing', () {
    // Prisma is CHOSEN but not among the enumerated (installed) targets.
    LinkBrowserRouter routerWithout() => LinkBrowserRouter(
      targets: FakeBrowserTargets(targets: const [_chrome]),
      packageFor: (_) => 'com.work.prisma',
    );

    test('the URL still opens, and the result reports the fallback', () async {
      final result = await routerWithout().open('https://x.example');
      expect(result.opened, isTrue);
      expect(result.usedFallback, isTrue);
      expect(result.requestedPackage, 'com.work.prisma');
      expect(result.openedAsRequested, isFalse);
    });

    test('the fallback message names the missing browser', () async {
      final router = routerWithout();
      final result = await router.open('https://x.example');
      final message = await linkBrowserFallbackMessage(
        result,
        LinkBrowserContext(router),
      );
      expect(message, isNotNull);
      expect(message, contains('com.work.prisma'));
    });

    test('an INSTALLED browser gets its OS label in the message', () async {
      // The chosen package IS enumerated but the platform still fell back
      // (start failed): the user is told by LABEL, not package.
      final router = LinkBrowserRouter(
        targets: FakeBrowserTargets(targets: const [_chrome, _prisma]),
        packageFor: (_) => 'com.work.prisma',
      );
      const result = BrowserOpenResult(
        opened: true,
        usedFallback: true,
        requestedPackage: 'com.work.prisma',
      );
      final message = await linkBrowserFallbackMessage(
        result,
        LinkBrowserContext(router),
      );
      expect(message, contains('Prisma'));
    });

    test('no fallback → no message (a normal open stays silent)', () async {
      final router = LinkBrowserRouter(
        targets: FakeBrowserTargets(targets: const [_chrome]),
        packageFor: (_) => 'com.android.chrome',
      );
      final result = await router.open('https://x.example');
      expect(result.usedFallback, isFalse);
      expect(
        await linkBrowserFallbackMessage(result, LinkBrowserContext(router)),
        isNull,
      );
    });

    test('labelFor falls back to the package when it is not installed', () async {
      expect(
        await routerWithout().labelFor('com.work.prisma'),
        'com.work.prisma',
      );
    });
  });
}
