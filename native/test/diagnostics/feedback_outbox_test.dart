// Bug-report outbox (#1259): a report that cannot be sent is kept on disk and
// sent automatically later; nothing is lost, nothing is sent twice.
//
// Plain `test()` with a real temp directory — the outbox is file I/O, which
// testWidgets' fake clock does not drain.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:mobissh/diagnostics/feedback_outbox.dart';

class _Relay {
  FeedbackPostOutcome next = FeedbackPostOutcome.failed;
  final List<String> bodies = <String>[];

  Future<FeedbackPostOutcome> post(String body) async {
    bodies.add(body);
    return next;
  }
}

void main() {
  late Directory root;
  late _Relay relay;
  late DateTime clock;

  FeedbackOutbox outbox({int maxReports = 10, int maxBytes = 1 << 30}) =>
      FeedbackOutbox(
        dir: () async => Directory('${root.path}/outbox'),
        poster: relay.post,
        maxReports: maxReports,
        maxBytes: maxBytes,
        now: () => clock,
      );

  List<String> names() {
    final d = Directory('${root.path}/outbox');
    if (!d.existsSync()) return const [];
    return d
        .listSync()
        .map((e) => e.path.split(Platform.pathSeparator).last)
        .toList()
      ..sort();
  }

  String report(String note) =>
      jsonEncode({'comment': note, 'screenshot': 'data:image/png;base64,AA=='});

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mobissh_outbox_');
    relay = _Relay();
    clock = DateTime.utc(2026, 10, 3, 12);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('a failed send keeps a byte-identical copy pending', () async {
    final body = report('relay down — keep me');
    final r = await outbox().submit(body);

    expect(r.outcome, FeedbackPostOutcome.failed);
    expect(r.id, isNotNull);
    expect(names(), ['${r.id}.json']);
    final kept = File('${root.path}/outbox/${r.id}.json').readAsStringSync();
    expect(kept, body, reason: 'the queued body is exactly what was posted');
    expect(relay.bodies.single, body);
    expect((await outbox().status()).pending, 1);
  });

  test('a delivered send leaves nothing behind', () async {
    relay.next = FeedbackPostOutcome.delivered;
    final r = await outbox().submit(report('online'));
    expect(r.outcome, FeedbackPostOutcome.delivered);
    expect(names(), isEmpty);
  });

  test('a later flush (launch / connect / resume) submits and dequeues', () async {
    final body = report('send me later');
    await outbox().submit(body);
    relay.bodies.clear();

    // A fresh instance = a relaunched process: no in-memory state.
    relay.next = FeedbackPostOutcome.delivered;
    final f = await outbox().flush();
    expect(f.sent, 1);
    expect(relay.bodies, [body]);
    expect(names(), isEmpty);

    // Nothing left: a second trigger sends nothing.
    final again = await outbox().flush();
    expect(again.sent, 0);
    expect(relay.bodies, [body]);
  });

  test('Retry replaces the same entry instead of adding a second one', () async {
    final ob = outbox();
    final first = await ob.submit(report('v1'));
    final retry = await ob.submit(report('v1 edited'), id: first.id);
    expect(retry.id, first.id);
    expect(names(), ['${first.id}.json']);
    expect(
      File('${root.path}/outbox/${first.id}.json').readAsStringSync(),
      report('v1 edited'),
    );
  });

  test('401/403 marks the report rejected and it is never retried', () async {
    relay.next = FeedbackPostOutcome.rejected;
    final r = await outbox().submit(report('wrong key'));
    expect(r.outcome, FeedbackPostOutcome.rejected);
    expect(names(), ['${r.id}.rejected']);

    relay.bodies.clear();
    relay.next = FeedbackPostOutcome.delivered;
    final f = await outbox().flush(auto: false);
    expect(f.sent, 0);
    expect(relay.bodies, isEmpty, reason: 'a rejected report is not resent');
    final s = await outbox().status();
    expect(s.rejected, 1);
    expect(s.pending, 0);
  });

  test('the cap evicts the OLDEST report and says how many', () async {
    final ob = outbox(maxReports: 3);
    final ids = <String?>[];
    for (var i = 0; i < 3; i++) {
      clock = clock.add(const Duration(seconds: 1));
      ids.add((await ob.submit(report('r$i'))).id);
    }
    clock = clock.add(const Duration(seconds: 1));
    final newest = await ob.submit(report('r3'));

    expect(newest.evicted, 1);
    expect(names(), [
      '${ids[1]}.json',
      '${ids[2]}.json',
      '${newest.id}.json',
    ]);
  });

  test('the byte cap evicts too, but never the report just saved', () async {
    final big = report('x' * 4000);
    final ob = outbox(maxBytes: 6000);
    clock = clock.add(const Duration(seconds: 1));
    final a = await ob.submit(big);
    clock = clock.add(const Duration(seconds: 1));
    final b = await ob.submit(big);
    expect(b.evicted, 1);
    expect(names(), ['${b.id}.json']);
    expect(a.id, isNot(b.id));
  });

  test('a corrupt outbox file is skipped and kept, without crashing', () async {
    final d = Directory('${root.path}/outbox')..createSync(recursive: true);
    File('${d.path}/report-00000000000000001-0000.json')
        .writeAsStringSync('{not json');
    final good = report('fine');
    File('${d.path}/report-00000000000000002-0000.json').writeAsStringSync(good);

    relay.next = FeedbackPostOutcome.delivered;
    final f = await outbox().flush();
    expect(f.sent, 1);
    expect(relay.bodies, [good], reason: 'the corrupt file is never posted');
    expect(names(), ['report-00000000000000001-0000.corrupt']);
    expect((await outbox().status()).corrupt, 1);
  });

  test('an upload interrupted by a crash is never resent (no duplicate)', () async {
    // Marker: an upload renames .json → .sending first. A .sending found by a
    // NEW process means the previous one died mid-POST; the server has no
    // idempotency key, so it is kept as .unconfirmed and never auto-resent.
    final d = Directory('${root.path}/outbox')..createSync(recursive: true);
    File('${d.path}/report-00000000000000001-0000.sending')
        .writeAsStringSync(report('maybe sent'));

    relay.next = FeedbackPostOutcome.delivered;
    final f = await outbox().flush();
    expect(f.sent, 0);
    expect(relay.bodies, isEmpty);
    expect(names(), ['report-00000000000000001-0000.unconfirmed']);
    expect((await outbox().status()).unconfirmed, 1);
  });

  test('automatic retries back off after a failure; Send now does not', () async {
    final ob = outbox();
    await ob.submit(report('offline'));
    relay.bodies.clear();

    final first = await ob.flush();
    expect(first.failed, 1);
    final tooSoon = await ob.flush();
    expect(tooSoon.skipped, isTrue, reason: 'no tight retry loop');
    expect(relay.bodies.length, 1);

    clock = clock.add(const Duration(seconds: 31));
    relay.next = FeedbackPostOutcome.delivered;
    final later = await ob.flush();
    expect(later.sent, 1);

    await ob.submit(report('again'));
    relay.next = FeedbackPostOutcome.failed;
    await ob.flush();
    final manual = await ob.flush(auto: false);
    expect(manual.skipped, isFalse, reason: 'Send now always runs');
  });

  // #1271: a report the user discarded (or took off-device with "Share
  // instead") while its upload was in flight must not be re-queued when that
  // upload fails — before, the failure renamed .sending back to .json and the
  // next flush sent it anyway.
  group('discard during an in-flight upload (#1271)', () {
    late Completer<FeedbackPostOutcome> gate;
    late int posts;
    late FeedbackOutbox ob;

    setUp(() {
      gate = Completer<FeedbackPostOutcome>();
      posts = 0;
      ob = FeedbackOutbox(
        dir: () async => Directory('${root.path}/outbox'),
        poster: (body) {
          posts++;
          return gate.future;
        },
        now: () => clock,
      );
    });

    Future<String> startUpload(Future<OutboxSubmitResult> Function() go) async {
      final pending = go();
      // Wait until the POST is actually in flight (.sending on disk).
      for (var i = 0; i < 200 && posts == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(posts, 1, reason: 'the upload never started');
      final sending = names().single;
      expect(sending, endsWith('.sending'));
      unawaited(pending);
      return sending.substring(0, sending.indexOf('.'));
    }

    test('discard(id) then the upload fails → gone, never re-sent', () async {
      final submitted = ob.submit(report('take it back'));
      final id = await startUpload(() => submitted);
      await ob.discard(id);
      gate.complete(FeedbackPostOutcome.failed);
      await submitted;

      expect(names(), isEmpty, reason: 'a discarded report is not re-queued');
      relay.next = FeedbackPostOutcome.delivered;
      final f = await outbox().flush(auto: false);
      expect(f.sent, 0);
      expect(relay.bodies, isEmpty, reason: 'the discarded report is never sent');
    });

    test('discardAll then the upload fails → gone, never re-sent', () async {
      final submitted = ob.submit(report('drop all'));
      await startUpload(() => submitted);
      await ob.discardAll();
      gate.complete(FeedbackPostOutcome.failed);
      await submitted;

      expect(names(), isEmpty);
      relay.next = FeedbackPostOutcome.delivered;
      await outbox().flush(auto: false);
      expect(relay.bodies, isEmpty);
    });

    test('a refused (401/403) upload of a discarded report is not kept', () async {
      final submitted = ob.submit(report('refused'));
      final id = await startUpload(() => submitted);
      await ob.discard(id);
      gate.complete(FeedbackPostOutcome.rejected);
      await submitted;
      expect(names(), isEmpty);
    });
  });

  // #1271: saved reports do not live forever on the device.
  group('30-day expiry (#1271)', () {
    void age(String name, Duration by) => File('${root.path}/outbox/$name')
        .setLastModifiedSync(clock.subtract(by));

    test('flush drops reports older than 30 days, in any state', () async {
      final d = Directory('${root.path}/outbox')..createSync(recursive: true);
      for (final n in [
        'report-00000000000000001-0000.json',
        'report-00000000000000002-0000.rejected',
        'report-00000000000000003-0000.unconfirmed',
        'report-00000000000000004-0000.corrupt',
        'report-00000000000000005-0000.json',
      ]) {
        File('${d.path}/$n').writeAsStringSync(report(n));
      }
      for (final n in names().take(4)) {
        age(n, const Duration(days: 31));
      }
      age('report-00000000000000005-0000.json', const Duration(days: 29));

      relay.next = FeedbackPostOutcome.delivered;
      final f = await outbox().flush();
      expect(f.expired, 4);
      expect(f.sent, 1);
      expect(relay.bodies, [report('report-00000000000000005-0000.json')],
          reason: 'an expired report is deleted, not sent');
      expect(names(), isEmpty);
    });

    test('submit drops expired reports and says how many', () async {
      final d = Directory('${root.path}/outbox')..createSync(recursive: true);
      File('${d.path}/report-00000000000000001-0000.rejected')
          .writeAsStringSync(report('ancient'));
      age('report-00000000000000001-0000.rejected', const Duration(days: 40));

      final r = await outbox().submit(report('new'));
      expect(r.expired, 1);
      expect(names(), ['${r.id}.json']);
    });
  });

  test('discardAll empties the outbox in every state', () async {
    final ob = outbox();
    await ob.submit(report('a'));
    relay.next = FeedbackPostOutcome.rejected;
    clock = clock.add(const Duration(seconds: 1));
    await ob.submit(report('b'));
    await ob.discardAll();
    expect(names(), isEmpty);
    expect((await ob.status()).total, 0);
  });
}
