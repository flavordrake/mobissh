// #1031 slice 1 — Riverpod surface for the detection style store: a notifier
// holding the hydrated DetectionStyles value (resolve-on-change; painters
// never read prefs per frame — the detectionSettingsProvider caching idiom)
// plus a family provider for cheap per-pattern watches (the lab UI slice
// watches ONE pattern's override without rebuilding on siblings).

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/state/detection_style_providers.dart';
import 'package:mobissh/storage/detection_styles_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ProviderContainer> containerWith(Map<String, Object> initial) async {
    SharedPreferences.setMockInitialValues(initial);
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        detectionStylesProvider.overrideWith(
          (ref) =>
              DetectionStylesNotifier(store: DetectionStylesStore(prefs: prefs)),
        ),
      ],
    );
    addTearDown(container.dispose);
    // Providers are lazy: instantiate the notifier, then let hydrate land.
    container.read(detectionStylesProvider);
    await pumpEventQueue();
    return container;
  }

  test('hydrates a stored override on startup', () async {
    final container = await containerWith({
      detectionStylesPrefsKey:
          '{"v":1,"styles":{"path":{"color":"#33AA55","active":1.4}}}',
    });
    final styles = container.read(detectionStylesProvider);
    expect(styles.of('path')!.colorHex, '#33AA55');
    expect(styles.of('path')!.activeIntensity, 1.4);
  });

  test('defaults to EMPTY while nothing is stored', () async {
    final container = await containerWith({});
    expect(container.read(detectionStylesProvider).isEmpty, isTrue);
  });

  test('mutations update state AND persist', () async {
    final container = await containerWith({});
    final notifier = container.read(detectionStylesProvider.notifier);
    await notifier.setColorHex('url', '#FF8800');
    await notifier.setInactiveIntensity('url', 1.2);
    await notifier.setActiveIntensity('path', 0.8);

    final styles = container.read(detectionStylesProvider);
    expect(styles.of('url')!.colorHex, '#FF8800');
    expect(styles.of('url')!.inactiveIntensity, 1.2);
    expect(styles.of('path')!.activeIntensity, 0.8);

    // Persisted: a FRESH store over the same prefs sees the same value.
    final prefs = await SharedPreferences.getInstance();
    final reloaded = await DetectionStylesStore(prefs: prefs).load();
    expect(reloaded.of('url')!.colorHex, '#FF8800');
    expect(reloaded.of('path')!.activeIntensity, 0.8);
  });

  test('clearing a field back to null drops it (absent = default)', () async {
    final container = await containerWith({});
    final notifier = container.read(detectionStylesProvider.notifier);
    await notifier.setColorHex('url', '#FF8800');
    await notifier.setColorHex('url', null);
    expect(
      container.read(detectionStylesProvider).of('url'),
      isNull,
      reason: 'an all-null style is no override at all',
    );
  });

  test('resetPattern clears one pattern; clearAllTuned clears everything',
      () async {
    final container = await containerWith({});
    final notifier = container.read(detectionStylesProvider.notifier);
    await notifier.setColorHex('url', '#FF8800');
    await notifier.setColorHex('path', '#33AA55');

    await notifier.resetPattern('url');
    expect(container.read(detectionStylesProvider).of('url'), isNull);
    expect(container.read(detectionStylesProvider).of('path'), isNotNull);

    await notifier.clearAllTuned();
    expect(container.read(detectionStylesProvider).isEmpty, isTrue);
  });

  test('knob setters (#1031 slice 2) update state and persist', () async {
    final container = await containerWith({});
    final notifier = container.read(detectionStylesProvider.notifier);
    await notifier.setVerifyShortPaths('path', false);
    await notifier.setLexicon('command', ['git', 'kubectl']);

    final styles = container.read(detectionStylesProvider);
    expect(styles.of('path')!.verifyShortPaths, isFalse);
    expect(styles.of('command')!.lexicon, ['git', 'kubectl']);

    // Clearing back to null drops the field (absent = shipped default).
    await notifier.setVerifyShortPaths('path', null);
    await notifier.setLexicon('command', null);
    expect(container.read(detectionStylesProvider).isEmpty, isTrue);
  });

  group('detectionPatternStyleProvider (family)', () {
    test('exposes ONE pattern\'s override', () async {
      final container = await containerWith({
        detectionStylesPrefsKey: '{"v":1,"styles":{"url":{"color":"#FF8800"}}}',
      });
      expect(
        container.read(detectionPatternStyleProvider('url'))!.colorHex,
        '#FF8800',
      );
      expect(container.read(detectionPatternStyleProvider('path')), isNull);
    });

    test('a sibling-pattern change does NOT rebuild an unrelated watcher '
        '(cheap per-pattern watch)', () async {
      final container = await containerWith({});
      var urlRebuilds = 0;
      container.listen(
        detectionPatternStyleProvider('url'),
        (_, _) => urlRebuilds++,
        fireImmediately: false,
      );
      final notifier = container.read(detectionStylesProvider.notifier);
      await notifier.setColorHex('path', '#33AA55');
      await pumpEventQueue();
      expect(
        urlRebuilds,
        0,
        reason: 'the family provider must isolate per-pattern watches',
      );
      await notifier.setColorHex('url', '#FF8800');
      await pumpEventQueue();
      expect(urlRebuilds, 1);
    });
  });
}
