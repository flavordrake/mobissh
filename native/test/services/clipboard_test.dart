// Unit tests for the hardened clipboard helper (#845, #924).
//
// `copyToClipboard` must:
//   - write via the `mobissh/clipboard` native channel with a NON-empty label
//     plus the text (the empty-label clip was the root cause of the missing
//     Gboard history entry, #845);
//   - return `true` as soon as the native write completes — the native write is
//     authoritative and is NOT gated on a synchronous self-readback (#924: the
//     synchronous readback could disturb Android-13 cross-app propagation, so it
//     was removed from the write path and deferred to diagnostics);
//   - treat a NULL native channel (desktop / widget tests) as a fall-back to
//     Flutter's plain `Clipboard.setData` and still return true;
//   - skip empty / whitespace-only payloads (return false, no write).

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobissh/services/clipboard.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  // Captures of the native-channel `setText` call.
  Map<dynamic, dynamic>? lastSetText;
  // Backing store for the mocked Flutter platform clipboard (read-back +
  // fall-back write).
  String? platformClipboard;
  // When true, the native channel handler THROWS (simulates desktop / a host
  // with no native plugin registered).
  bool nativeThrows = false;
  // When true, `Clipboard.getData` returns null (Android can deny READ when
  // focus just changed).
  bool readBackNull = false;

  setUp(() {
    lastSetText = null;
    platformClipboard = null;
    nativeThrows = false;
    readBackNull = false;

    messenger.setMockMethodCallHandler(clipboardChannel, (call) async {
      if (nativeThrows) {
        throw PlatformException(code: 'NO_PLUGIN');
      }
      if (call.method == 'setText') {
        lastSetText = call.arguments as Map<dynamic, dynamic>;
        platformClipboard = lastSetText!['text'] as String?;
        return true;
      }
      return null;
    });

    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        platformClipboard = (call.arguments as Map)['text'] as String?;
        return null;
      }
      if (call.method == 'Clipboard.getData') {
        if (readBackNull) return <String, dynamic>{'text': null};
        return <String, dynamic>{'text': platformClipboard};
      }
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(clipboardChannel, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  test('invokes mobissh/clipboard setText with label + text', () async {
    final ok = await copyToClipboard('https://example.com/path');
    expect(ok, isTrue);
    expect(lastSetText, isNotNull);
    expect(lastSetText!['text'], 'https://example.com/path');
    // The non-empty label is the whole point of #845.
    expect(lastSetText!['label'], 'MobiSSH');
    expect((lastSetText!['label'] as String).isNotEmpty, isTrue);
  });

  test('native write is authoritative — returns true without awaiting a '
      'readback (#924)', () async {
    // Count how many times Clipboard.getData is invoked DURING the
    // copyToClipboard call. The #924 fix removed the synchronous, awaited
    // readback from the write path, so the write must NOT block on getData.
    var getDataCallsDuringWrite = 0;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        platformClipboard = (call.arguments as Map)['text'] as String?;
        return null;
      }
      if (call.method == 'Clipboard.getData') {
        getDataCallsDuringWrite++;
        return <String, dynamic>{'text': platformClipboard};
      }
      return null;
    });

    final ok = await copyToClipboard('verify-me');
    expect(ok, isTrue);
    // The native channel write ran with our text.
    expect(lastSetText!['text'], 'verify-me');
    // No synchronous readback gated the write (it is deferred / fire-and-forget).
    expect(getDataCallsDuringWrite, 0);
  });

  test('null read-back is irrelevant to the result (write authoritative)',
      () async {
    readBackNull = true;
    final ok = await copyToClipboard('focus-changed');
    expect(ok, isTrue);
    // The native write still ran regardless of any (deferred) readback outcome.
    expect(lastSetText!['text'], 'focus-changed');
  });

  test('deferred readback runs AFTER the write settles, never gating it (#924)',
      () async {
    // The deferred readback is OFF under `flutter test` by default (it would
    // leave a pending timer that testWidgets rejects, and it's on-device-only
    // diagnostics). Force it on for this one assertion, then restore.
    final previous = setDeferredReadbackEnabledForTest(true);
    addTearDown(() => setDeferredReadbackEnabledForTest(previous));

    var getDataCalls = 0;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') {
        getDataCalls++;
        return <String, dynamic>{'text': platformClipboard};
      }
      if (call.method == 'Clipboard.setData') {
        platformClipboard = (call.arguments as Map)['text'] as String?;
        return null;
      }
      return null;
    });

    final ok = await copyToClipboard('deferred-me');
    expect(ok, isTrue);
    // Right after the write returns, the deferred readback has NOT yet fired —
    // this is the core #924 guarantee (no synchronous readback in the write
    // path).
    expect(getDataCalls, 0);
    // After waiting past the deferral delay, the diagnostic readback has fired.
    await Future<void>.delayed(
      clipboardReadbackDelay + const Duration(milliseconds: 50),
    );
    expect(getDataCalls, 1);
  });

  test('deferred readback is OFF by default under flutter test (no timer leak)',
      () async {
    // Default path: no force-enable. The write must NOT schedule any readback
    // timer (that pending timer is what broke the widget tests).
    var getDataCalls = 0;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') {
        getDataCalls++;
        return <String, dynamic>{'text': platformClipboard};
      }
      if (call.method == 'Clipboard.setData') {
        platformClipboard = (call.arguments as Map)['text'] as String?;
        return null;
      }
      return null;
    });

    final ok = await copyToClipboard('no-timer-leak');
    expect(ok, isTrue);
    await Future<void>.delayed(
      clipboardReadbackDelay + const Duration(milliseconds: 50),
    );
    // No readback fired — the timer was never scheduled.
    expect(getDataCalls, 0);
  });

  test('a diagnostics-map result (native readback #962) still returns true',
      () async {
    // #962: the native setText now returns a diagnostics MAP (sdk/model/focus/
    // readback) instead of a bare bool. copyToClipboard must accept it, log it,
    // and still report success — the write is authoritative regardless.
    messenger.setMockMethodCallHandler(clipboardChannel, (call) async {
      if (call.method == 'setText') {
        lastSetText = call.arguments as Map<dynamic, dynamic>;
        final text = lastSetText!['text'] as String;
        return <String, dynamic>{
          'ok': true,
          'sdk': 34,
          'release': '15',
          'model': 'Pixel 9',
          'wroteLen': text.length,
          'hasPrimaryClip': true,
          'readbackLen': text.length,
          'matches': true,
          'sensitiveReadback': false,
          'windowFocus': true,
        };
      }
      return null;
    });

    final ok = await copyToClipboard('map-result');
    expect(ok, isTrue);
    expect(lastSetText!['text'], 'map-result');
  });

  test('native channel error falls back to Clipboard.setData → true', () async {
    nativeThrows = true;
    final ok = await copyToClipboard('fallback-text');
    expect(ok, isTrue);
    // Native setText never captured (it threw); the fall-back platform write
    // populated the clipboard instead.
    expect(lastSetText, isNull);
    expect(platformClipboard, 'fallback-text');
  });

  test('empty text → no write, returns false', () async {
    final ok = await copyToClipboard('');
    expect(ok, isFalse);
    expect(lastSetText, isNull);
    expect(platformClipboard, isNull);
  });

  test('whitespace-only text → no write, returns false', () async {
    final ok = await copyToClipboard('   \n\t  ');
    expect(ok, isFalse);
    expect(lastSetText, isNull);
    expect(platformClipboard, isNull);
  });
}
