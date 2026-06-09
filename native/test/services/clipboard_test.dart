// Unit tests for the hardened clipboard helper (#845).
//
// `copyToClipboard` must:
//   - write via the `mobissh/clipboard` native channel with a NON-empty label
//     plus the text (the empty-label clip was the root cause of the missing
//     Gboard history entry);
//   - read back via `Clipboard.getData(text/plain)` and confirm containment;
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

  test('read-back containment match returns true', () async {
    // The native handler stores the text; read-back returns it → contains.
    final ok = await copyToClipboard('verify-me');
    expect(ok, isTrue);
    expect(platformClipboard, 'verify-me');
  });

  test('null read-back is not a failure (write authoritative)', () async {
    readBackNull = true;
    final ok = await copyToClipboard('focus-changed');
    expect(ok, isTrue);
    // The native write still ran.
    expect(lastSetText!['text'], 'focus-changed');
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
