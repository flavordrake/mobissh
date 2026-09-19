// Browser-target seam unit tests (#1196, slice 1 of #1195).
//
// Covers A1/A2/A3 from `docs/link-browser-routing.md`:
//   A1 — payload mapping, package pass-through, and a PlatformException that
//        surfaces as a FALLBACK RESULT rather than a throw (R1/R2).
//   A2 — the channel CONTRACT: method names and argument/result keys are pinned
//        here so a Kotlin-side rename fails a Dart test instead of a device.
//   A3 — no channel (desktop / test host): `listBrowsers` is EMPTY and `open`
//        degrades to the existing `launchUrl(..., externalApplication)` path
//        (R4).
//
// Every test runs against a MOCK binary messenger or an injected fallback
// opener — no test touches a real channel handler or a real browser (R3).

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobissh/services/browser_targets.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  // Recorded calls seen by the fake channel handler.
  late List<MethodCall> calls;
  // What the fake handler does for `listBrowsers` / `open`.
  late Object? Function(MethodCall call) respond;
  // Recorded URLs handed to the injected fallback (`launchUrl`) opener.
  late List<String> fallbackOpens;
  // What the injected fallback opener returns.
  late bool fallbackResult;

  /// A service wired to a mocked channel (A1/A2).
  PlatformBrowserTargets withMockChannel() {
    messenger.setMockMethodCallHandler(browserChannel, (call) async {
      calls.add(call);
      return respond(call);
    });
    addTearDown(() => messenger.setMockMethodCallHandler(browserChannel, null));
    return PlatformBrowserTargets(
      fallbackOpen: (url) async {
        fallbackOpens.add(url);
        return fallbackResult;
      },
    );
  }

  /// A service whose channel has NO handler at all — the desktop / test-host
  /// case, where `invokeMethod` throws `MissingPluginException` (A3/R4).
  PlatformBrowserTargets withNoChannel() {
    messenger.setMockMethodCallHandler(browserChannel, null);
    return PlatformBrowserTargets(
      fallbackOpen: (url) async {
        fallbackOpens.add(url);
        return fallbackResult;
      },
    );
  }

  setUp(() {
    calls = <MethodCall>[];
    fallbackOpens = <String>[];
    fallbackResult = true;
    respond = (_) => null;
  });

  group('A1 — payload mapping and package pass-through (R1/R2)', () {
    test('listBrowsers maps the platform payload to BrowserTargets', () async {
      respond = (call) => <Object?>[
        <Object?, Object?>{
          'package': 'com.android.chrome',
          'label': 'Chrome',
          'isDefault': true,
        },
        <Object?, Object?>{
          'package': 'org.mozilla.firefox',
          'label': 'Firefox',
          'isDefault': false,
        },
      ];

      final list = await withMockChannel().listBrowsers();

      expect(list, hasLength(2));
      expect(list.first.package, 'com.android.chrome');
      expect(list.first.label, 'Chrome');
      expect(list.first.isDefault, isTrue);
      expect(list.last.package, 'org.mozilla.firefox');
      expect(list.last.label, 'Firefox');
      expect(list.last.isDefault, isFalse);
    });

    test('listBrowsers drops malformed entries instead of throwing', () async {
      respond = (call) => <Object?>[
        <Object?, Object?>{'label': 'No package', 'isDefault': false},
        <Object?, Object?>{'package': '', 'label': 'Empty package'},
        'not a map',
        <Object?, Object?>{'package': 'com.opera.browser'},
      ];

      final list = await withMockChannel().listBrowsers();

      expect(list, hasLength(1));
      expect(list.single.package, 'com.opera.browser');
      // A missing label falls back to the package so the UI is never blank.
      expect(list.single.label, 'com.opera.browser');
      expect(list.single.isDefault, isFalse);
    });

    test('open passes the requested package through to the channel', () async {
      respond = (call) => <Object?, Object?>{
        'opened': true,
        'usedFallback': false,
        'requestedPackage': 'org.mozilla.firefox',
      };

      final res = await withMockChannel().open(
        'https://example.com/a',
        package: 'org.mozilla.firefox',
      );

      final args = calls.single.arguments as Map<Object?, Object?>;
      expect(args['url'], 'https://example.com/a');
      expect(args['package'], 'org.mozilla.firefox');
      expect(res.opened, isTrue);
      expect(res.usedFallback, isFalse);
      expect(res.requestedPackage, 'org.mozilla.firefox');
      expect(res.openedAsRequested, isTrue);
      // The native side handled it — the launchUrl path stays untouched.
      expect(fallbackOpens, isEmpty);
    });

    test('open with no package sends a null package (today behaviour)', () async {
      respond = (call) => <Object?, Object?>{
        'opened': true,
        'usedFallback': false,
        'requestedPackage': null,
      };

      final res = await withMockChannel().open('https://example.com/b');

      final args = calls.single.arguments as Map<Object?, Object?>;
      expect(args['package'], isNull);
      expect(res.opened, isTrue);
      expect(res.usedFallback, isFalse);
      expect(res.requestedPackage, isNull);
    });

    test('native fallback is reported, not hidden (R2)', () async {
      respond = (call) => <Object?, Object?>{
        'opened': true,
        'usedFallback': true,
        'requestedPackage': 'com.missing.browser',
      };

      final res = await withMockChannel().open(
        'https://example.com/c',
        package: 'com.missing.browser',
      );

      expect(res.opened, isTrue);
      expect(res.usedFallback, isTrue);
      expect(res.requestedPackage, 'com.missing.browser');
      // The whole point of the shape: "opened, but not where you asked".
      expect(res.openedAsRequested, isFalse);
    });

    test('a PlatformException surfaces as a fallback result, not a throw', () async {
      respond = (call) => throw PlatformException(code: 'OPEN_FAILED');

      final targets = withMockChannel();
      final res = await targets.open(
        'https://example.com/d',
        package: 'com.missing.browser',
      );

      expect(res.opened, isTrue);
      expect(res.usedFallback, isTrue);
      expect(res.requestedPackage, 'com.missing.browser');
      expect(fallbackOpens, <String>['https://example.com/d']);
    });

    test('a PlatformException on listBrowsers yields an empty list', () async {
      respond = (call) => throw PlatformException(code: 'LIST_FAILED');

      expect(await withMockChannel().listBrowsers(), isEmpty);
    });

    test('a failed fallback open reports opened:false and no fallback target',
        () async {
      respond = (call) => throw PlatformException(code: 'OPEN_FAILED');
      fallbackResult = false;

      final res = await withMockChannel().open(
        'https://example.com/e',
        package: 'com.missing.browser',
      );

      // Nothing opened at all, so no OTHER target was used either.
      expect(res.opened, isFalse);
      expect(res.usedFallback, isFalse);
      expect(res.requestedPackage, 'com.missing.browser');
    });
  });

  group('A2 — channel contract pinned on the Dart side', () {
    test('channel name and method names match the Kotlin handler', () {
      expect(browserChannelName, 'mobissh/browser');
      expect(browserChannel.name, browserChannelName);
      expect(browserMethodListBrowsers, 'listBrowsers');
      expect(browserMethodOpen, 'open');
    });

    test('argument keys and payload/result keys are pinned', () {
      expect(browserArgUrl, 'url');
      expect(browserArgPackage, 'package');
      expect(browserFieldPackage, 'package');
      expect(browserFieldLabel, 'label');
      expect(browserFieldIsDefault, 'isDefault');
      expect(browserFieldOpened, 'opened');
      expect(browserFieldUsedFallback, 'usedFallback');
      expect(browserFieldRequestedPackage, 'requestedPackage');
    });

    test('the invoked method names are the pinned constants', () async {
      respond = (call) => call.method == browserMethodListBrowsers
          ? <Object?>[]
          : <Object?, Object?>{'opened': true, 'usedFallback': false};

      final targets = withMockChannel();
      await targets.listBrowsers();
      await targets.open('https://example.com/f', package: 'com.x');

      expect(calls.map((c) => c.method).toList(), <String>[
        browserMethodListBrowsers,
        browserMethodOpen,
      ]);
      final openArgs = calls.last.arguments as Map<Object?, Object?>;
      expect(openArgs.keys.toSet(), <Object?>{
        browserArgUrl,
        browserArgPackage,
      });
    });
  });

  group('A3 — no channel degrades to the existing path (R4)', () {
    test('listBrowsers returns an empty list (offer no choice)', () async {
      expect(await withNoChannel().listBrowsers(), isEmpty);
    });

    test('open still opens through the existing launchUrl path', () async {
      final res = await withNoChannel().open('https://example.com/g');

      expect(fallbackOpens, <String>['https://example.com/g']);
      expect(res.opened, isTrue);
      // No package was asked for, so the system default IS what was requested —
      // this is not a fallback in the R2 sense.
      expect(res.usedFallback, isFalse);
      expect(res.requestedPackage, isNull);
      expect(res.openedAsRequested, isTrue);
    });

    test('open with a package on a channel-less host reports the fallback',
        () async {
      final res = await withNoChannel().open(
        'https://example.com/h',
        package: 'org.mozilla.firefox',
      );

      expect(fallbackOpens, <String>['https://example.com/h']);
      expect(res.opened, isTrue);
      expect(res.usedFallback, isTrue);
      expect(res.requestedPackage, 'org.mozilla.firefox');
    });
  });

  group('FakeBrowserTargets (R3 — the shared test double)', () {
    test('serves canned targets and records opens', () async {
      final fake = FakeBrowserTargets(
        targets: const <BrowserTarget>[
          BrowserTarget(
            package: 'com.android.chrome',
            label: 'Chrome',
            isDefault: true,
          ),
        ],
      );

      expect(await fake.listBrowsers(), hasLength(1));

      final res = await fake.open('https://example.com/i', package: 'com.x');
      expect(res.opened, isTrue);
      // 'com.x' is not in the canned list → the fake reports a fallback, the
      // same way the platform does for a package that is not installed.
      expect(res.usedFallback, isTrue);
      expect(fake.opens.single.url, 'https://example.com/i');
      expect(fake.opens.single.package, 'com.x');
    });

    test('an empty fake enumerates nothing and still opens', () async {
      final fake = FakeBrowserTargets();
      expect(await fake.listBrowsers(), isEmpty);
      final res = await fake.open('https://example.com/j');
      expect(res.opened, isTrue);
      expect(res.usedFallback, isFalse);
    });
  });
}
