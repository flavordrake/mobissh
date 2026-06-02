// Unit tests for the #684 switchable terminal backend preference.
//
// Locks the persisted-enum contract: default xterm, hydrate a stored value,
// set+persist, and a corrupt/unknown stored id falling back to the default
// (a stale pref must never crash the terminal).

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/state/terminal_backend.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _settle() async {
  // Let the StateNotifier _hydrate Future resolve.
  await Future<void>.delayed(const Duration(milliseconds: 10));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('terminalBackendFromId', () {
    test('null falls back to the default (xterm)', () {
      expect(terminalBackendFromId(null), terminalBackendDefault);
      expect(terminalBackendDefault, TerminalBackend.xterm);
    });

    test('known ids parse to the matching enum', () {
      expect(terminalBackendFromId('xterm'), TerminalBackend.xterm);
      expect(terminalBackendFromId('ghostty'), TerminalBackend.ghostty);
    });

    test('unknown/corrupt id falls back to the default', () {
      expect(terminalBackendFromId('flterm'), terminalBackendDefault);
      expect(terminalBackendFromId(''), terminalBackendDefault);
      expect(terminalBackendFromId('XTERM'), terminalBackendDefault);
    });
  });

  group('TerminalBackendNotifier', () {
    test('defaults to xterm with no stored value', () async {
      final n = TerminalBackendNotifier(prefs: SharedPreferences.getInstance());
      await _settle();
      expect(n.state, TerminalBackend.xterm);
    });

    test('hydrates a stored ghostty value', () async {
      SharedPreferences.setMockInitialValues({
        terminalBackendPrefKey: 'ghostty',
      });
      final n = TerminalBackendNotifier(prefs: SharedPreferences.getInstance());
      await _settle();
      expect(n.state, TerminalBackend.ghostty);
    });

    test('hydrate with a corrupt stored value keeps the default', () async {
      SharedPreferences.setMockInitialValues({
        terminalBackendPrefKey: 'nonsense',
      });
      final n = TerminalBackendNotifier(prefs: SharedPreferences.getInstance());
      await _settle();
      expect(n.state, TerminalBackend.xterm);
    });

    test('set updates state and persists the enum name', () async {
      final n = TerminalBackendNotifier(prefs: SharedPreferences.getInstance());
      await _settle();
      await n.set(TerminalBackend.ghostty);
      expect(n.state, TerminalBackend.ghostty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(terminalBackendPrefKey), 'ghostty');
    });

    test('set back to xterm persists xterm', () async {
      SharedPreferences.setMockInitialValues({
        terminalBackendPrefKey: 'ghostty',
      });
      final n = TerminalBackendNotifier(prefs: SharedPreferences.getInstance());
      await _settle();
      expect(n.state, TerminalBackend.ghostty);
      await n.set(TerminalBackend.xterm);
      expect(n.state, TerminalBackend.xterm);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(terminalBackendPrefKey), 'xterm');
    });
  });
}
