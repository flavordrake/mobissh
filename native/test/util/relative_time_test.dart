// Unit tests for the file-browser relative-time formatter (#951).

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/util/relative_time.dart';

void main() {
  // Fixed reference instant so every case is deterministic.
  final now = DateTime(2026, 6, 29, 12, 0, 0);
  int epochSecondsAgo(Duration d) =>
      now.subtract(d).millisecondsSinceEpoch ~/ 1000;

  group('formatRelative', () {
    test('null epoch → empty string', () {
      expect(formatRelative(null, now: now), '');
    });

    test('zero / negative epoch → empty string (never a 1969 date)', () {
      expect(formatRelative(0, now: now), '');
      expect(formatRelative(-100, now: now), '');
    });

    test('future timestamp (clock skew) → just now', () {
      final future = now.add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000;
      expect(formatRelative(future, now: now), 'just now');
    });

    test('seconds bucket', () {
      expect(formatRelative(epochSecondsAgo(const Duration(seconds: 5)), now: now),
          '5s ago');
      expect(formatRelative(epochSecondsAgo(const Duration(seconds: 59)), now: now),
          '59s ago');
    });

    test('minutes bucket', () {
      expect(formatRelative(epochSecondsAgo(const Duration(minutes: 1)), now: now),
          '1m ago');
      expect(formatRelative(epochSecondsAgo(const Duration(minutes: 59)), now: now),
          '59m ago');
    });

    test('hours bucket', () {
      expect(formatRelative(epochSecondsAgo(const Duration(hours: 1)), now: now),
          '1h ago');
      expect(formatRelative(epochSecondsAgo(const Duration(hours: 23)), now: now),
          '23h ago');
    });

    test('yesterday', () {
      expect(formatRelative(epochSecondsAgo(const Duration(days: 1)), now: now),
          'yesterday');
    });

    test('days bucket', () {
      expect(formatRelative(epochSecondsAgo(const Duration(days: 3)), now: now),
          '3d ago');
      expect(formatRelative(epochSecondsAgo(const Duration(days: 6)), now: now),
          '6d ago');
    });

    test('weeks bucket', () {
      expect(formatRelative(epochSecondsAgo(const Duration(days: 7)), now: now),
          '1w ago');
      expect(formatRelative(epochSecondsAgo(const Duration(days: 20)), now: now),
          '2w ago');
    });

    test('months bucket', () {
      expect(formatRelative(epochSecondsAgo(const Duration(days: 30)), now: now),
          '1mo ago');
      expect(formatRelative(epochSecondsAgo(const Duration(days: 364)), now: now),
          '12mo ago');
    });

    test('years bucket', () {
      expect(formatRelative(epochSecondsAgo(const Duration(days: 365)), now: now),
          '1y ago');
      expect(formatRelative(epochSecondsAgo(const Duration(days: 800)), now: now),
          '2y ago');
    });
  });
}
