// Show/hide toggle on secret fields (owner request on the export dialog:
// "passwords should have preview toggle"). Pins: starts obscured, eye toggles
// visibility both ways, and the export dialog (a real consumer) carries the
// toggle on both passphrase fields under the original field keys.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobissh/ui/export_backup_dialog.dart';
import 'package:mobissh/ui/revealable_field.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  bool obscuredOf(WidgetTester tester, String keyName) =>
      tester.widget<TextField>(find.byKey(Key(keyName))).obscureText;

  testWidgets('starts obscured; eye toggles both ways', (tester) async {
    final ctrl = TextEditingController();
    addTearDown(ctrl.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RevealableTextField(
          fieldKeyName: 'secret-field',
          controller: ctrl,
          labelText: 'Secret',
        ),
      ),
    ));
    await tester.enterText(find.byKey(const Key('secret-field')), 'hunter2!');
    expect(obscuredOf(tester, 'secret-field'), isTrue);

    await tester.tap(find.byKey(const Key('secret-field-reveal')));
    await tester.pump();
    expect(obscuredOf(tester, 'secret-field'), isFalse,
        reason: 'the eye reveals the typed value');

    await tester.tap(find.byKey(const Key('secret-field-reveal')));
    await tester.pump();
    expect(obscuredOf(tester, 'secret-field'), isTrue);
  });

  testWidgets('export dialog passphrase fields carry the toggle',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: ExportBackupDialog()),
    ));
    await tester.pump();

    expect(find.byKey(const Key('export-backup-passphrase-reveal')),
        findsOneWidget);
    expect(find.byKey(const Key('export-backup-confirm-reveal')),
        findsOneWidget);
    expect(obscuredOf(tester, 'export-backup-passphrase'), isTrue);

    await tester.tap(find.byKey(const Key('export-backup-passphrase-reveal')));
    await tester.pump();
    expect(obscuredOf(tester, 'export-backup-passphrase'), isFalse);
    // Confirm field is independent — still hidden.
    expect(obscuredOf(tester, 'export-backup-confirm'), isTrue);
  });
}
