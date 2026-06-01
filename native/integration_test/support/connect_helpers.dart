// Shared on-emulator connect helpers (#583).
//
// The home view is a profile CHOOSER now — the inline connect form was removed.
// An ad-hoc connection goes through the editor: tap "New connection", fill the
// editor's host/port/username/credential fields, then "Save & connect"
// (`connect-submit`). These helpers centralise that flow so every emulator
// smoke uses the same path.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Open the create-mode profile editor from the chooser's "New connection"
/// affordance. Works on both the home view and a pushed New-session page.
Future<void> openNewConnectionEditor(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('new-connection')));
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Fill the create-mode editor with a password connection and tap
/// "Save & connect". Assumes [openNewConnectionEditor] already ran.
Future<void> fillPasswordAndConnect(
  WidgetTester tester, {
  required String host,
  required String port,
  required String user,
  required String pass,
}) async {
  await tester.enterText(find.byKey(const Key('profile-editor-host')), host);
  await tester.enterText(find.byKey(const Key('profile-editor-port')), port);
  await tester.enterText(
    find.byKey(const Key('profile-editor-username')),
    user,
  );
  await tester.enterText(
    find.byKey(const Key('profile-editor-password')),
    pass,
  );
  await tester.pump();
  final submit = find.byKey(const Key('connect-submit'));
  await tester.ensureVisible(submit);
  await tester.pump();
  await tester.tap(submit);
}

/// Full ad-hoc password connect from the chooser: open the editor, fill, and
/// "Save & connect".
Future<void> adhocPasswordConnect(
  WidgetTester tester, {
  required String host,
  required String port,
  required String user,
  required String pass,
}) async {
  await openNewConnectionEditor(tester);
  await fillPasswordAndConnect(
    tester,
    host: host,
    port: port,
    user: user,
    pass: pass,
  );
}

/// Full ad-hoc KEY-auth connect from the chooser: open the editor, switch to
/// Key mode, paste the PEM, and "Save & connect".
Future<void> adhocKeyConnect(
  WidgetTester tester, {
  required String host,
  required String port,
  required String user,
  required String keyPem,
}) async {
  await openNewConnectionEditor(tester);
  await tester.enterText(find.byKey(const Key('profile-editor-host')), host);
  await tester.enterText(find.byKey(const Key('profile-editor-port')), port);
  await tester.enterText(
    find.byKey(const Key('profile-editor-username')),
    user,
  );
  // Switch to Key auth (SegmentedButton segment labelled "Key").
  await tester.tap(find.text('Key'));
  await tester.pump(const Duration(milliseconds: 300));
  await tester.enterText(find.byKey(const Key('profile-editor-key')), keyPem);
  await tester.pump();
  final submit = find.byKey(const Key('connect-submit'));
  await tester.ensureVisible(submit);
  await tester.pumpAndSettle(const Duration(milliseconds: 300));
  await tester.tap(submit);
}
