// Widget tests for the EDITABLE markdown viewer (#859 — part 3 of #854).
//
// The render+raw toggle shipped in #858; the SFTP WRITE chain shipped in #892
// ([TextFileWriter] / [textFileWriterProvider]). This slice is UI-only: a third
// view mode (EDIT) in [MarkdownFileViewerScreen] plus a Save that pushes the
// edited text back through the EXISTING writer seam to the ORIGINAL path.
//
// Assert:
//   - edit → change → Save calls the injected writer ONCE with the edited text
//     and the original entry path, and the rendered document then shows the
//     saved text,
//   - a writer failure leaves a PERSISTENT inline error affordance (still on
//     screen well past any toast duration — project rule: actionable guidance
//     never vanishes) with the edit buffer intact, and Retry re-issues the
//     write,
//   - Save is inert while nothing has changed,
//   - popping the route with unsaved edits prompts (Discard / Keep editing)
//     instead of silently dropping the buffer (#842 capture-before-clear).
//
// The writer is faked via [textFileWriterProvider].overrideWithValue — the
// mirror of how markdown_file_viewer_widget_test.dart fakes
// [textFileFetcherProvider].

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/services/text_file_fetcher.dart';
import 'package:mobissh/services/text_file_writer.dart';
import 'package:mobissh/ui/markdown_file_viewer.dart';

/// Injectable text fetcher: returns canned markdown without touching SFTP.
/// Extends (not implements) so the interface's default `fetchContent` —
/// a canned String is editable — applies unless [content] overrides it (#1227).
class _CannedTextFetcher extends TextFileFetcher {
  _CannedTextFetcher(this.text, {this.content});
  final String text;
  final TextFileContent? content;

  @override
  Future<String> fetch(
    String sessionId,
    SftpEntry entry, {
    int maxBytes = 2 * 1024 * 1024,
    void Function(int received, int? total)? onProgress,
  }) async => text;

  @override
  Future<TextFileContent> fetchContent(
    String sessionId,
    SftpEntry entry, {
    int maxBytes = 2 * 1024 * 1024,
    void Function(int received, int? total)? onProgress,
  }) async => content ?? TextFileContent(text: text);
}

/// Records every write; optionally fails with [error] (set/cleared per test).
class _RecordingWriter implements TextFileWriter {
  final calls = <({String sessionId, String path, String content})>[];
  Object? error;

  @override
  Future<int> write(String sessionId, String path, String content) async {
    calls.add((sessionId: sessionId, path: path, content: content));
    final e = error;
    if (e != null) throw e;
    return content.length;
  }
}

const _sessionId = 'sess-1';
const _entry = SftpEntry(
  name: 'DOC.md',
  path: '/notes/DOC.md',
  isDirectory: false,
  size: 32,
);
const _sourceMarkdown = '# Heading One\n\nOriginal body text.\n';

Future<void> _pump(WidgetTester tester, {int count = 12}) async {
  for (var i = 0; i < count; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 30));
  }
}

/// Lets any in-flight top toast finish its timer + exit animation so the test
/// doesn't end on a pending timer — and, for the failure test, proves the
/// inline error is NOT a toast.
Future<void> _settleToasts(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 3));
  await _pump(tester);
}

/// Pumps the viewer as a PUSHED route (so there is something to pop back to)
/// and returns the fake writer.
Future<_RecordingWriter> _openViewer(
  WidgetTester tester, {
  TextFileContent? content,
}) async {
  final writer = _RecordingWriter();
  final navKey = GlobalKey<NavigatorState>();
  final container = ProviderContainer(
    overrides: [
      textFileFetcherProvider.overrideWithValue(
        _CannedTextFetcher(content?.text ?? _sourceMarkdown, content: content),
      ),
      textFileWriterProvider.overrideWithValue(writer),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        navigatorKey: navKey,
        home: const Scaffold(body: Center(child: Text('browser-root'))),
      ),
    ),
  );
  await _pump(tester);

  navKey.currentState!.push(
    MaterialPageRoute<void>(
      builder: (_) =>
          const MarkdownFileViewerScreen(sessionId: _sessionId, entry: _entry),
    ),
  );
  await _pump(tester);
  return writer;
}

Future<void> _enterEditMode(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('markdown-edit-toggle')));
  await _pump(tester);
}

String _editorText(WidgetTester tester) {
  final field = tester.widget<TextField>(
    find.byKey(const Key('markdown-viewer-editor')),
  );
  return field.controller!.text;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('edit → Save writes the edited text to the original path', (
    tester,
  ) async {
    final writer = await _openViewer(tester);
    expect(find.byType(MarkdownFileViewerScreen), findsOneWidget);

    await _enterEditMode(tester);
    expect(find.byKey(const Key('markdown-viewer-editor')), findsOneWidget);
    // Seeded from the fetched source.
    expect(_editorText(tester), _sourceMarkdown);

    const edited = '# Edited Heading\n\nRewritten body.\n';
    await tester.enterText(
      find.byKey(const Key('markdown-viewer-editor')),
      edited,
    );
    await _pump(tester);

    await tester.tap(find.byKey(const Key('markdown-viewer-save')));
    await _pump(tester);

    expect(writer.calls.length, 1);
    expect(writer.calls.single.sessionId, _sessionId);
    expect(writer.calls.single.path, '/notes/DOC.md');
    expect(writer.calls.single.content, edited);

    // Back out of edit mode; the rendered document reflects the saved text.
    expect(find.byKey(const Key('markdown-viewer-editor')), findsNothing);
    expect(find.byType(Markdown), findsOneWidget);
    expect(find.textContaining('Edited Heading'), findsOneWidget);
    expect(find.textContaining('Original body text.'), findsNothing);

    await _settleToasts(tester);
  });

  testWidgets('save failure shows a PERSISTENT error + Retry, buffer kept', (
    tester,
  ) async {
    final writer = await _openViewer(tester);
    writer.error = Exception('permission denied');

    await _enterEditMode(tester);
    const edited = '# Edited Heading\n\nRewritten body.\n';
    await tester.enterText(
      find.byKey(const Key('markdown-viewer-editor')),
      edited,
    );
    await _pump(tester);
    await tester.tap(find.byKey(const Key('markdown-viewer-save')));
    await _pump(tester);

    expect(writer.calls.length, 1);

    // PERSISTENT: still there after any toast would have vanished.
    await _settleToasts(tester);
    expect(find.byKey(const Key('markdown-viewer-save-error')), findsOneWidget);
    expect(find.textContaining('permission denied'), findsOneWidget);

    // The edit buffer survived the failure.
    expect(find.byKey(const Key('markdown-viewer-editor')), findsOneWidget);
    expect(_editorText(tester), edited);

    // Retry re-issues the write; on success the error clears and we leave edit.
    writer.error = null;
    await tester.tap(find.byKey(const Key('markdown-viewer-save-retry')));
    await _pump(tester);

    expect(writer.calls.length, 2);
    expect(writer.calls.last.content, edited);
    expect(find.byKey(const Key('markdown-viewer-save-error')), findsNothing);
    expect(find.byKey(const Key('markdown-viewer-editor')), findsNothing);
    expect(find.textContaining('Edited Heading'), findsOneWidget);

    await _settleToasts(tester);
  });

  // #1221 (owner P0): on Android `enableSuggestions: false` sets
  // TYPE_TEXT_FLAG_NO_SUGGESTIONS, which makes Gboard drop glide typing, the
  // suggestion strip AND the voice key — the editor degraded to one tap per
  // letter. Pin the full-keyboard configuration so a future "protect the
  // source text" change cannot silently take swipe and voice away again.
  testWidgets('editor keeps swipe typing, suggestions and voice (#1221)', (
    tester,
  ) async {
    await _openViewer(tester);
    await _enterEditMode(tester);

    final field = tester.widget<TextField>(
      find.byKey(const Key('markdown-viewer-editor')),
    );
    expect(
      field.enableSuggestions,
      isTrue,
      reason: 'false = NO_SUGGESTIONS on Android: no glide typing, no voice',
    );
    expect(field.autocorrect, isTrue);

    final editable = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const Key('markdown-viewer-editor')),
        matching: find.byType(EditableText),
      ),
    );
    expect(editable.enableSuggestions, isTrue);
    expect(editable.autocorrect, isTrue);
    expect(editable.keyboardType, TextInputType.multiline);
  });

  // #1227 item 2: bytes that don't survive a strict UTF-8 round-trip were
  // decoded lossily and a Save wrote U+FFFD over the server's bytes. Such a
  // file still opens for VIEWING, but Edit is disabled with a PERSISTENT
  // explanation where the action is — never a toast.
  testWidgets('a file that is not valid UTF-8 opens read-only: Edit disabled '
      'with a persistent explanation (#1227)', (tester) async {
    final writer = await _openViewer(
      tester,
      content: const TextFileContent(
        text: '# Latin\n\ncaf� body\n',
        readOnlyReason: notUtf8ReadOnlyMessage,
      ),
    );
    // Viewing works.
    expect(find.byType(Markdown), findsOneWidget);
    expect(find.textContaining('body'), findsOneWidget);

    final toggle = tester.widget<IconButton>(
      find.byKey(const Key('markdown-edit-toggle')),
    );
    expect(toggle.onPressed, isNull, reason: 'Edit must be disabled');
    expect(
      find.byKey(const Key('markdown-viewer-edit-disabled')),
      findsOneWidget,
    );
    expect(find.textContaining("isn't valid UTF-8"), findsOneWidget);

    // PERSISTENT: still there long after any toast would have gone.
    await _settleToasts(tester);
    expect(
      find.byKey(const Key('markdown-viewer-edit-disabled')),
      findsOneWidget,
    );

    // Tapping the disabled action opens no editor and writes nothing.
    await tester.tap(
      find.byKey(const Key('markdown-edit-toggle')),
      warnIfMissed: false,
    );
    await _pump(tester);
    expect(find.byKey(const Key('markdown-viewer-editor')), findsNothing);
    expect(writer.calls, isEmpty);
  });

  testWidgets('BOM + CRLF + emoji/CJK survive load → edit → Save byte-exact '
      '(#1227)', (tester) async {
    const body = '# T\r\n\r\ncafé ✓ 日本語 🎉\r\n';
    final writer = await _openViewer(
      tester,
      content: const TextFileContent(text: body, hasBom: true),
    );
    await _enterEditMode(tester);
    // The BOM is not in the edit buffer (it is not the user's text).
    expect(_editorText(tester), body);

    const added = 'added ✓ 日本語 🎉\r\n';
    await tester.enterText(
      find.byKey(const Key('markdown-viewer-editor')),
      '$body$added',
    );
    await _pump(tester);
    await tester.tap(find.byKey(const Key('markdown-viewer-save')));
    await _pump(tester);

    expect(writer.calls.length, 1);
    expect(
      utf8.encode(writer.calls.single.content),
      [0xEF, 0xBB, 0xBF, ...utf8.encode('$body$added')],
      reason: 'saved bytes == BOM + original (CRLF intact) + the edit',
    );
    await _settleToasts(tester);
  });

  testWidgets('Save is inert when nothing changed', (tester) async {
    final writer = await _openViewer(tester);
    await _enterEditMode(tester);

    final save = tester.widget<IconButton>(
      find.byKey(const Key('markdown-viewer-save')),
    );
    expect(save.onPressed, isNull, reason: 'unchanged buffer → disabled Save');

    await tester.tap(
      find.byKey(const Key('markdown-viewer-save')),
      warnIfMissed: false,
    );
    await _pump(tester);

    expect(writer.calls, isEmpty);
    expect(find.byKey(const Key('markdown-viewer-editor')), findsOneWidget);
  });

  testWidgets('popping with unsaved edits prompts and keeps the buffer', (
    tester,
  ) async {
    final writer = await _openViewer(tester);
    await _enterEditMode(tester);

    const edited = '# Edited Heading\n\nRewritten body.\n';
    await tester.enterText(
      find.byKey(const Key('markdown-viewer-editor')),
      edited,
    );
    await _pump(tester);

    // Back → the route does NOT silently pop; a confirm prompt appears.
    await tester.tap(find.byType(BackButton));
    await _pump(tester);
    expect(
      find.byKey(const Key('markdown-viewer-unsaved-dialog')),
      findsOneWidget,
    );
    expect(find.byType(MarkdownFileViewerScreen), findsOneWidget);

    // Keep editing → dialog closes, buffer intact, nothing written.
    await tester.tap(find.text('Keep editing'));
    await _pump(tester);
    expect(
      find.byKey(const Key('markdown-viewer-unsaved-dialog')),
      findsNothing,
    );
    expect(find.byKey(const Key('markdown-viewer-editor')), findsOneWidget);
    expect(_editorText(tester), edited);
    expect(writer.calls, isEmpty);

    // Discard → the route really leaves.
    await tester.tap(find.byType(BackButton));
    await _pump(tester);
    await tester.tap(find.text('Discard'));
    await _pump(tester, count: 40);
    expect(find.byType(MarkdownFileViewerScreen), findsNothing);
    expect(find.text('browser-root'), findsOneWidget);
    expect(writer.calls, isEmpty);
  });
}
