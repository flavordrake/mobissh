// File browser favorites widget tests (#632).
//
// Renders [FileBrowserScreen] against the same task-side [SessionHost] +
// scripted SFTP harness as file_browser_widget_test.dart, and exercises the
// per-profile favorites UX:
//   - TAP the app-bar star toggles favoriting the current path (filled/outline)
//   - LONG-PRESS the star opens the unified favorites menu
//   - tapping a favorite navigates the files view there (the deepLink seam)
//   - LONG-PRESS a favorite removes it
//   - "Clear all" empties the set
//   - LONG-PRESS a file/folder entry opens the SAME menu (and does NOT navigate)
//   - favorites are PER-PROFILE and persist (a fresh store reads them back)
//
// The host's timers are cancelled inline at the END of each test body via
// `host.disposeSyncForTest()` — addTearDown runs after the framework's
// pending-timer invariant check, so it can't be relied on for that (mirrors
// file_browser_widget_test.dart).

import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/session_host.dart';
import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/sftp_session.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/storage/favorites_store.dart';
import 'package:mobissh/ui/file_browser_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

SshSessionController _stubControllerFactory() {
  return SshSessionController(
    socketOpener: (host, port, {timeout}) => Completer<SSHSocket>().future,
  );
}

class _ScriptedSftpSession implements SftpSession {
  _ScriptedSftpSession(this._byPath);

  final Map<String, List<SftpEntry>> _byPath;

  @override
  Future<List<SftpEntry>> list(String path) async => _byPath[path] ?? const [];

  @override
  Future<int?> sizeOf(String path) async => 0;

  @override
  Future<int> download(
    String path, {
    required void Function(Uint8List chunk, int offset) onChunk,
    int chunkSize = 64 * 1024,
  }) async => 0;

  @override
  Future<int> upload(String path, Uint8List bytes) async => bytes.length;

  @override
  Future<void> close() async {}
}

Future<void> _pump(WidgetTester tester, {int count = 12}) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

/// Standard tree: root `/` has `docs/` (→ inner.bin) + `a.bin`. host:port:user
/// = `h:22:u` so the favorites identity key is deterministic.
const Map<String, List<SftpEntry>> _tree = {
  '/': [
    SftpEntry(name: 'docs', path: '/docs', isDirectory: true),
    SftpEntry(name: 'a.bin', path: '/a.bin', isDirectory: false, size: 4),
  ],
  '/docs': [
    SftpEntry(
      name: 'inner.bin',
      path: '/docs/inner.bin',
      isDirectory: false,
      size: 4,
    ),
  ],
};

const SshConnectParams _params = SshConnectParams(
  host: 'h',
  port: 22,
  username: 'u',
  auth: SshAuth.password('p'),
);
const String _profileKey = 'h:22:u';

class _Harness {
  _Harness(this.host, this.container, this.entry);
  final SessionHost host;
  final ProviderContainer container;
  final SessionEntry entry;

  /// Cancel the host's timers + drop the container. Call INLINE at the end of a
  /// test body (before the framework's pending-timer invariant check).
  void dispose() {
    host.disposeSyncForTest();
    container.dispose();
  }
}

Future<_Harness> _mount(WidgetTester tester) async {
  final pair = InMemoryGatewayPair();
  final host = SessionHost(
    gateway: pair.taskSide,
    controllerFactory: _stubControllerFactory,
    sftpOpener: (_) async => _ScriptedSftpSession(_tree),
    snapshotInterval: const Duration(hours: 1),
  );
  final container = ProviderContainer(
    overrides: [taskSshGatewayProvider.overrideWithValue(pair.uiSide)],
  );
  final entry = container.read(sessionsProvider.notifier).addOrActivate(_params);
  entry.proxy.connect(_params);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: FileBrowserScreen(sessionId: entry.id)),
    ),
  );
  await _pump(tester);
  return _Harness(host, container, entry);
}

Finder _starIcon(IconData icon) => find.descendant(
  of: find.byKey(const Key('file-browser-star')),
  matching: find.byIcon(icon),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('star is outline by default; tap favorites; tap again clears', (
    tester,
  ) async {
    final h = await _mount(tester);

    // Default: at root `/`, nothing favorited → outline star.
    expect(_starIcon(Icons.star_border), findsOneWidget);
    expect(_starIcon(Icons.star), findsNothing);

    // Tap → favorited (filled).
    await tester.tap(find.byKey(const Key('file-browser-star')));
    await _pump(tester);
    expect(_starIcon(Icons.star), findsOneWidget);
    expect(await FavoritesStore().isFavorite(_profileKey, '/'), isTrue);

    // Tap again → un-favorited (outline).
    await tester.tap(find.byKey(const Key('file-browser-star')));
    await _pump(tester);
    expect(_starIcon(Icons.star_border), findsOneWidget);
    expect(await FavoritesStore().isFavorite(_profileKey, '/'), isFalse);

    h.dispose();
  });

  testWidgets('star reflects favorited state of the CURRENT directory', (
    tester,
  ) async {
    await FavoritesStore().add(_profileKey, '/docs');

    final h = await _mount(tester);

    // At `/` (not favorited) → outline.
    expect(_starIcon(Icons.star_border), findsOneWidget);

    // Navigate into /docs (favorited) → filled.
    await tester.tap(find.byKey(const Key('file-entry-docs')));
    await _pump(tester);
    expect(find.text('/docs'), findsOneWidget);
    expect(_starIcon(Icons.star), findsOneWidget);

    h.dispose();
  });

  testWidgets('long-press star opens menu; tap a favorite navigates there', (
    tester,
  ) async {
    await FavoritesStore().add(_profileKey, '/docs');

    final h = await _mount(tester);

    expect(find.byKey(const Key('file-entry-a.bin')), findsOneWidget);

    // Long-press the star → favorites menu.
    await tester.longPress(find.byKey(const Key('file-browser-star')));
    await _pump(tester);
    expect(find.byKey(const Key('favorites-list')), findsOneWidget);
    expect(find.byKey(const Key('favorite-item-/docs')), findsOneWidget);

    // Tap the favorite → files view navigates to /docs (deepLink seam).
    await tester.tap(find.byKey(const Key('favorite-item-/docs')));
    await _pump(tester);
    expect(find.byKey(const Key('favorite-item-/docs')), findsNothing);
    expect(find.byKey(const Key('file-entry-inner.bin')), findsOneWidget);
    expect(find.text('/docs'), findsOneWidget);

    h.dispose();
  });

  testWidgets('long-press a favorite removes it', (tester) async {
    await FavoritesStore().add(_profileKey, '/docs');
    await FavoritesStore().add(_profileKey, '/a');

    final h = await _mount(tester);

    await tester.longPress(find.byKey(const Key('file-browser-star')));
    await _pump(tester);
    expect(find.byKey(const Key('favorite-item-/docs')), findsOneWidget);

    // Long-press the favorite → removed from the list + storage.
    await tester.longPress(find.byKey(const Key('favorite-item-/docs')));
    await _pump(tester);
    expect(find.byKey(const Key('favorite-item-/docs')), findsNothing);
    expect(find.byKey(const Key('favorite-item-/a')), findsOneWidget);
    expect(await FavoritesStore().isFavorite(_profileKey, '/docs'), isFalse);

    h.dispose();
  });

  testWidgets('clear all empties the favorites set', (tester) async {
    await FavoritesStore().add(_profileKey, '/docs');
    await FavoritesStore().add(_profileKey, '/a');

    final h = await _mount(tester);

    await tester.longPress(find.byKey(const Key('file-browser-star')));
    await _pump(tester);
    expect(find.byKey(const Key('favorites-list')), findsOneWidget);

    await tester.tap(find.byKey(const Key('favorites-clear-all')));
    await _pump(tester);
    expect(find.byKey(const Key('favorites-empty')), findsOneWidget);
    expect(await FavoritesStore().favoritesFor(_profileKey), isEmpty);

    h.dispose();
  });

  testWidgets('long-press a file entry opens the menu (does NOT navigate)', (
    tester,
  ) async {
    await FavoritesStore().add(_profileKey, '/docs');

    final h = await _mount(tester);

    // Long-press the `docs` directory entry → favorites menu, NOT navigation.
    await tester.longPress(find.byKey(const Key('file-entry-docs')));
    await _pump(tester);
    expect(find.byKey(const Key('favorites-list')), findsOneWidget);
    // Still at root: inner.bin (which only exists inside /docs) is NOT shown.
    expect(find.byKey(const Key('file-entry-inner.bin')), findsNothing);

    h.dispose();
  });

  testWidgets('favorites are per-profile (profile B does not see A)', (
    tester,
  ) async {
    await FavoritesStore().add(_profileKey, '/docs');
    expect(await FavoritesStore().favoritesFor('other:22:bob'), isEmpty);

    final h = await _mount(tester);
    // This session (profile A) DOES see /docs as favorited.
    await tester.tap(find.byKey(const Key('file-entry-docs')));
    await _pump(tester);
    expect(_starIcon(Icons.star), findsOneWidget);

    h.dispose();
  });
}
