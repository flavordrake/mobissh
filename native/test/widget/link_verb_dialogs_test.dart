// #1149 (PR E of #1117) — link dialogs with a verb.
//
// R16: the R12 confirmation names the EXACT command that will run when the
// link carries a verb, and shows nothing of the sort without one.
// R23(b): the live-session confirmation names the command; Run → true,
// Cancel → false.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobissh/services/connect_link_router.dart';
import 'package:mobissh/services/link_verb.dart';
import 'package:mobissh/storage/profiles_store.dart';
import 'package:mobissh/ui/link_dialogs.dart';

final _alice = SavedProfile(
  title: 'Alice box',
  host: 'box.example',
  port: 22,
  username: 'alice',
);
const _cmd = 'tmux new-session -A -s main';

Future<void> _pumpHost(
  WidgetTester tester,
  void Function(BuildContext ctx) onPressed,
) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (ctx) => TextButton(
          key: const Key('open'),
          onPressed: () => onPressed(ctx),
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await tester.tap(find.byKey(const Key('open')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('R16: confirm dialog names the command when a verb is present',
      (tester) async {
    LinkConfirmChoice? result;
    await _pumpHost(tester, (ctx) async {
      result = await showLinkConfirmDialog(ctx, _alice, verb: TmuxAttach('main'));
    });
    expect(find.byKey(const Key('link-confirm-dialog')), findsOneWidget);
    expect(find.byKey(const Key('link-confirm-command')), findsOneWidget);
    expect(find.text(_cmd), findsOneWidget);
    await tester.tap(find.byKey(const Key('link-confirm-once')));
    await tester.pumpAndSettle();
    expect(result, LinkConfirmChoice.once);
  });

  testWidgets('R16: confirm dialog shows no command line without a verb',
      (tester) async {
    await _pumpHost(tester, (ctx) => showLinkConfirmDialog(ctx, _alice));
    expect(find.byKey(const Key('link-confirm-dialog')), findsOneWidget);
    expect(find.byKey(const Key('link-confirm-command')), findsNothing);
    expect(find.textContaining('tmux'), findsNothing);
  });

  testWidgets('R23b: live-session run dialog names the command; Run → true',
      (tester) async {
    bool? result;
    await _pumpHost(tester, (ctx) async {
      result = await showLinkVerbRunDialog(ctx, _alice, TmuxAttach('main'));
    });
    expect(find.byKey(const Key('link-verb-run-dialog')), findsOneWidget);
    expect(find.text(_cmd), findsOneWidget);
    await tester.tap(find.byKey(const Key('link-verb-run')));
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });

  testWidgets('R23b: Cancel → false', (tester) async {
    bool? result;
    await _pumpHost(tester, (ctx) async {
      result = await showLinkVerbRunDialog(ctx, _alice, TmuxAttach('main'));
    });
    await tester.tap(find.byKey(const Key('link-verb-cancel')));
    await tester.pumpAndSettle();
    expect(result, isFalse);
  });
}
