// R23 (#1185): the ssh_config export is a shareable artifact handed to the
// EXISTING share seam, and its preview states plainly that it carries no
// secrets.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/viewer_file_actions.dart';
import 'package:mobissh/ssh/ssh_config_export.dart';
import 'package:mobissh/state/keys_providers.dart';
import 'package:mobissh/state/profiles_providers.dart';
import 'package:mobissh/storage/profiles_store.dart';
import 'package:mobissh/ui/ssh_config_export_dialog.dart';

class _SpyActions implements FileViewerActionService {
  final List<ViewerFileSource> shared = <ViewerFileSource>[];

  @override
  Future<String> downloadToDevice(
    ViewerFileSource source, {
    void Function(int received, int? total)? onProgress,
  }) async =>
      throw UnimplementedError();

  @override
  Future<void> shareFile(
    ViewerFileSource source, {
    void Function(int received, int? total)? onProgress,
  }) async {
    shared.add(source);
  }
}

Future<void> _pump(
  WidgetTester tester, {
  required List<SavedProfile> profiles,
  required _SpyActions spy,
}) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      savedProfilesProvider.overrideWith((ref) async => profiles),
      savedKeysProvider.overrideWith((ref) async => const []),
      fileViewerActionServiceProvider.overrideWithValue(spy),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showSshConfigExportDialog(context),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('preview states plainly that no secrets are included',
      (tester) async {
    final spy = _SpyActions();
    await _pump(
      tester,
      profiles: [
        SavedProfile(
          title: 'Prod',
          host: 'prod.example.com',
          port: 2222,
          username: 'deploy',
        ),
      ],
      spy: spy,
    );

    expect(find.byKey(const Key('ssh-config-export-no-secrets')), findsOneWidget);
    final preview = tester.widget<SelectableText>(
      find.byKey(const Key('ssh-config-export-preview')),
    );
    expect(preview.data, contains('Host prod'));
    expect(preview.data, contains('HostName prod.example.com'));
  });

  testWidgets('Share hands the exported text to the existing share seam',
      (tester) async {
    final spy = _SpyActions();
    final profiles = [
      SavedProfile(
        title: 'Prod',
        host: 'prod.example.com',
        port: 2222,
        username: 'deploy',
      ),
    ];
    await _pump(tester, profiles: profiles, spy: spy);

    await tester.tap(find.byKey(const Key('ssh-config-export-share')));
    await tester.pumpAndSettle();

    expect(spy.shared, hasLength(1));
    final source = spy.shared.single as BytesFileSource;
    expect(source.fileName, sshConfigExportFileName);
    expect(
      utf8.decode(source.bytes),
      buildSshConfigExport(profiles).text,
    );
  });

  testWidgets('with no saved profiles, Share is disabled', (tester) async {
    final spy = _SpyActions();
    await _pump(tester, profiles: const [], spy: spy);

    expect(find.byKey(const Key('ssh-config-export-empty')), findsOneWidget);
    final share = tester.widget<FilledButton>(
      find.byKey(const Key('ssh-config-export-share')),
    );
    expect(share.onPressed, isNull);
    expect(spy.shared, isEmpty);
  });
}
