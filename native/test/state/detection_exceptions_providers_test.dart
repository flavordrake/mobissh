// Detection exceptions provider (#995) — session-facing suppression lookup.
//
// Contract under test:
//   - hydrates persisted exceptions once (ready future)
//   - report() persists + immediately suppresses the exact matched text
//   - suppression is per pattern FAMILY: a url report suppresses the same text
//     seen via osc8 (and vice versa), but NOT the same text as a path
//   - a DIFFERENT text in the same family stays visible (exact-match v1)
//   - removeException() restores detection and persists the removal
//   - isSuppressed is cheap (hash-set) — smoke: many lookups after one load

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/state/detection_exceptions_providers.dart';
import 'package:mobissh/storage/detection_exceptions_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Future<DetectionExceptionsNotifier> notifier() async {
    final prefs = await SharedPreferences.getInstance();
    final n = DetectionExceptionsNotifier(
      store: DetectionExceptionsStore(prefs: prefs),
    );
    await n.ready;
    return n;
  }

  test('report persists + suppresses the exact matched text', () async {
    final n = await notifier();
    expect(n.isSuppressed('url', 'https://a.b/c'), isFalse);

    await n.report(
      patternId: 'url',
      matchedText: 'https://a.b/c',
      contextLine: 'log line',
      host: 'test-sshd',
    );

    expect(n.isSuppressed('url', 'https://a.b/c'), isTrue);
    // Exact-match v1: a different text in the same family stays visible.
    expect(n.isSuppressed('url', 'https://a.b/other'), isFalse);
    // Record fields captured.
    expect(n.state, hasLength(1));
    expect(n.state.single.host, 'test-sshd');
    expect(n.state.single.contextLine, 'log line');
    expect(n.state.single.tsMs, greaterThan(0));

    // Persisted: a FRESH notifier over the same prefs hydrates it.
    final n2 = await notifier();
    expect(n2.isSuppressed('url', 'https://a.b/c'), isTrue);
  });

  test('url and osc8 share one suppression family; path does not', () async {
    final n = await notifier();
    await n.report(patternId: 'url', matchedText: 'https://a.b/c');

    expect(n.isSuppressed('osc8', 'https://a.b/c'), isTrue);
    expect(n.isSuppressed('path', 'https://a.b/c'), isFalse);
  });

  test('removeException restores detection and persists', () async {
    final n = await notifier();
    await n.report(patternId: 'path', matchedText: '/etc/hosts');
    expect(n.isSuppressed('path', '/etc/hosts'), isTrue);

    await n.removeException(n.state.single);
    expect(n.isSuppressed('path', '/etc/hosts'), isFalse);
    expect(n.state, isEmpty);

    final n2 = await notifier();
    expect(n2.isSuppressed('path', '/etc/hosts'), isFalse);
  });

  test('duplicate report is a no-op (one record)', () async {
    final n = await notifier();
    await n.report(patternId: 'url', matchedText: 'https://a.b/c');
    await n.report(patternId: 'osc8', matchedText: 'https://a.b/c');
    expect(n.state, hasLength(1));
  });

  test('hydrates a stored corpus on construction', () async {
    final prefs = await SharedPreferences.getInstance();
    final seed = DetectionExceptionsStore(prefs: prefs);
    await seed.add(
      const DetectionException(matchedText: '/config', patternId: 'path'),
    );

    final n = await notifier();
    expect(n.isSuppressed('path', '/config'), isTrue);
  });
}
