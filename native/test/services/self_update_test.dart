// #1216 (slice 2 of #1214) — self-update checker + installer, headless.
// Spec: docs/self-update.md. A3 (checker) and A4 (installer) plus the R12
// cleanup rule. The manifest contract is PINNED by the spec; the fixtures here
// are written against it, not against slice 1's script output.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:mobissh/services/self_update.dart';

final Uri manifestUrl =
    Uri.parse('https://mobissh.tailbe5094.ts.net/android-latest.json');
const String apkUrl =
    'https://mobissh.tailbe5094.ts.net/mobissh-native-0.1.12-rc.5+192-20260927T172906+0000.apk';

Map<String, Object?> manifestJson({
  Object? version = '0.1.12-rc.5+192',
  Object? build = 192,
  Object? abi = 'arm64-v8a',
  Object? url = apkUrl,
  Object? sha256 =
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
  Object? builtAt = '2026-09-27T17:29:06Z',
  Object? notes = 'self-update',
}) => <String, Object?>{
  'version': version,
  'build': build,
  'abi': abi,
  'url': url,
  'sha256': sha256,
  'builtAt': builtAt,
  'notes': notes,
};

Future<String> sha256Hex(List<int> bytes) async {
  final digest = await Sha256().hash(bytes);
  return digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

class FakeUpdatePlatform implements UpdatePlatform {
  FakeUpdatePlatform({
    this.supported = true,
    this.abi = 'arm64-v8a',
    required this.dir,
    this.handoff = const UpdateHandoffResult(
      status: UpdateHandoffStatus.launched,
      installer: 'com.android.packageinstaller',
    ),
  });

  final bool supported;
  final String abi;
  final Directory dir;
  UpdateHandoffResult handoff;
  final List<String> handedOff = <String>[];
  bool unmetered = true;
  bool canInstall = true;

  /// Snapshot of the file the platform was handed, taken at hand-off time.
  List<int>? bytesAtHandoff;

  @override
  Future<UpdateCapabilities> capabilities() async =>
      UpdateCapabilities(supported: supported, abi: abi);

  @override
  Future<bool> isUnmetered() async => unmetered;

  @override
  Future<bool> canInstallPackages() async => canInstall;

  @override
  Future<Directory> updatesDir() async => dir;

  @override
  Future<UpdateHandoffResult> verifyAndInstall(String path) async {
    handedOff.add(path);
    bytesAtHandoff = File(path).readAsBytesSync();
    return handoff;
  }
}

void main() {
  late Directory tmp;
  late Directory updates;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('self_update_test');
    updates = Directory('${tmp.path}/updates');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  group('A3 manifest contract', () {
    test('a well-formed manifest parses to the pinned fields', () {
      final m = UpdateManifest.parse(
        jsonEncode(manifestJson()),
        manifestUrl: manifestUrl,
      );
      expect(m.version, '0.1.12-rc.5+192');
      expect(m.build, 192);
      expect(m.abi, 'arm64-v8a');
      expect(m.url, Uri.parse(apkUrl));
      expect(m.sha256, hasLength(64));
      expect(m.notes, 'self-update');
    });

    for (final c in <String, Map<String, Object?>>{
      'build is a string (semver is never compared, D1)': manifestJson(
        build: '192',
      ),
      'build missing': manifestJson(build: null),
      'version missing': manifestJson(version: null),
      'abi missing': manifestJson(abi: null),
      'sha256 not 64 lowercase hex': manifestJson(sha256: 'ABCDEF'),
      'sha256 uppercase': manifestJson(
        sha256:
            '0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF',
      ),
      'non-https url': manifestJson(
        url: 'http://mobissh.tailbe5094.ts.net/x.apk',
      ),
      'foreign-host url': manifestJson(url: 'https://evil.example.com/x.apk'),
      'same host, different port': manifestJson(
        url: 'https://mobissh.tailbe5094.ts.net:8443/x.apk',
      ),
    }.entries) {
      test('rejected: ${c.key}', () {
        expect(
          () => UpdateManifest.parse(
            jsonEncode(c.value),
            manifestUrl: manifestUrl,
          ),
          throwsA(isA<UpdateException>()),
        );
      });
    }

    test('rejected: not JSON / not an object', () {
      expect(
        () => UpdateManifest.parse('<html>', manifestUrl: manifestUrl),
        throwsA(isA<UpdateException>()),
      );
      expect(
        () => UpdateManifest.parse('[1,2]', manifestUrl: manifestUrl),
        throwsA(isA<UpdateException>()),
      );
    });
  });

  group('A3 checker', () {
    UpdateChecker checker({
      required http.Client client,
      int? runningBuild = 191,
      bool supported = true,
      String abi = 'arm64-v8a',
    }) => UpdateChecker(
      client: client,
      platform: FakeUpdatePlatform(supported: supported, abi: abi, dir: updates),
      manifestUrl: manifestUrl,
      runningBuild: runningBuild,
    );

    MockClient serving(Object body, {int status = 200}) => MockClient(
      (req) async => http.Response(
        body is String ? body : jsonEncode(body),
        status,
      ),
    );

    test('newer build → available', () async {
      final r = await checker(client: serving(manifestJson())).check();
      expect(r.kind, UpdateCheckKind.available);
      expect(r.manifest!.build, 192);
      expect(r.installedBuild, 191);
    });

    test('same build → up to date', () async {
      final r = await checker(
        client: serving(manifestJson(build: 191)),
      ).check();
      expect(r.kind, UpdateCheckKind.upToDate);
    });

    test('older build → up to date (never a downgrade offer)', () async {
      final r = await checker(
        client: serving(manifestJson(build: 150)),
      ).check();
      expect(r.kind, UpdateCheckKind.upToDate);
    });

    test('malformed manifest → not offered, with a reason', () async {
      final r = await checker(client: serving('{"build": "x"')).check();
      expect(r.kind, UpdateCheckKind.notOffered);
      expect(r.reason, isNotEmpty);
    });

    test('non-https url → not offered', () async {
      final r = await checker(
        client: serving(manifestJson(url: 'http://mobissh.tailbe5094.ts.net/a.apk')),
      ).check();
      expect(r.kind, UpdateCheckKind.notOffered);
      expect(r.reason, contains('https'));
    });

    test('foreign-host url → not offered', () async {
      final r = await checker(
        client: serving(manifestJson(url: 'https://evil.example.com/a.apk')),
      ).check();
      expect(r.kind, UpdateCheckKind.notOffered);
      expect(r.reason, contains('host'));
    });

    test('abi mismatch → not offered, Settings can say why (R9)', () async {
      final r = await checker(
        client: serving(manifestJson()),
        abi: 'x86_64',
      ).check();
      expect(r.kind, UpdateCheckKind.notOffered);
      expect(r.reason, contains('arm64-v8a'));
      expect(r.reason, contains('x86_64'));
      expect(r.manifest, isNotNull, reason: 'Settings still shows Latest');
    });

    test('unreachable (socket error) → unreachable, quiet (R6)', () async {
      final r = await checker(
        client: MockClient((_) async => throw const SocketException('no route')),
      ).check();
      expect(r.kind, UpdateCheckKind.unreachable);
      expect(r.reason, contains('no route'));
    });

    test('HTTP 404 → unreachable', () async {
      final r = await checker(client: serving('nope', status: 404)).check();
      expect(r.kind, UpdateCheckKind.unreachable);
      expect(r.reason, contains('404'));
    });

    test('a 30x is refused, never followed (#1252)', () async {
      // The mock plays a server that redirects: a client that follows
      // redirects gets the (followed) manifest, one that does not gets the 302.
      final r = await checker(
        client: MockClient((req) async {
          if (req.followRedirects) {
            return http.Response(jsonEncode(manifestJson()), 200);
          }
          return http.Response(
            '',
            302,
            headers: {'location': 'https://evil.example.com/m.json'},
          );
        }),
      ).check();
      expect(r.kind, UpdateCheckKind.unreachable);
      expect(r.reason, contains('redirect'));
      expect(r.reason, contains('302'));
    });

    test('timeout → unreachable', () async {
      final c = UpdateChecker(
        client: MockClient((_) => Completer<http.Response>().future),
        platform: FakeUpdatePlatform(dir: updates),
        manifestUrl: manifestUrl,
        runningBuild: 191,
        timeout: const Duration(milliseconds: 20),
      );
      final r = await c.check();
      expect(r.kind, UpdateCheckKind.unreachable);
    });

    test('no MOBISSH_BUILD ordinal → not offered (R2: never % 1000)', () async {
      final r = await checker(
        client: serving(manifestJson()),
        runningBuild: null,
      ).check();
      expect(r.kind, UpdateCheckKind.notOffered);
      expect(r.reason, contains('MOBISSH_BUILD'));
    });

    test('unsupported platform (Play / desktop) → no request at all', () async {
      var requests = 0;
      final r = await checker(
        client: MockClient((_) async {
          requests++;
          return http.Response(jsonEncode(manifestJson()), 200);
        }),
        supported: false,
      ).check();
      expect(r.kind, UpdateCheckKind.unsupported);
      expect(requests, 0);
    });

    test('runningBuildFromDefine: only a positive integer counts', () {
      expect(runningBuildFromDefine('191'), 191);
      expect(runningBuildFromDefine(''), isNull);
      expect(runningBuildFromDefine('2191x'), isNull);
      expect(runningBuildFromDefine('0'), isNull);
    });
  });

  group('A4 installer', () {
    final apkBytes = List<int>.generate(300 * 1024, (i) => i % 251);

    Future<UpdateManifest> manifestFor(List<int> bytes, {int build = 192}) async =>
        UpdateManifest.parse(
          jsonEncode(manifestJson(sha256: await sha256Hex(bytes), build: build)),
          manifestUrl: manifestUrl,
        );

    MockClient streaming(List<int> bytes, {bool withLength = true}) =>
        MockClient.streaming((req, _) async {
          final chunks = <List<int>>[];
          for (var i = 0; i < bytes.length; i += 64 * 1024) {
            chunks.add(bytes.sublist(i, (i + 64 * 1024).clamp(0, bytes.length)));
          }
          return http.StreamedResponse(
            Stream<List<int>>.fromIterable(chunks),
            200,
            contentLength: withLength ? bytes.length : null,
          );
        });

    List<File> apks() => updates.existsSync()
        ? updates.listSync().whereType<File>().toList()
        : <File>[];

    test('sha mismatch → failed and NOTHING written, no hand-off', () async {
      final platform = FakeUpdatePlatform(dir: updates);
      final m = await manifestFor(apkBytes);
      final tampered = List<int>.of(apkBytes)..[1000] ^= 0xff;
      final stages = await UpdateInstaller(
        client: streaming(tampered),
        platform: platform,
      ).install(m).toList();
      expect(stages.last.stage, UpdateStage.failed);
      expect(stages.last.message, contains('checksum'));
      expect(apks(), isEmpty);
      expect(platform.handedOff, isEmpty);
      // Nothing was written at ANY stage before verification finished.
      expect(
        stages.where((s) => s.stage == UpdateStage.handingOff),
        isEmpty,
      );
    });

    test('match → written to updates/, handed off, then handedOff', () async {
      final platform = FakeUpdatePlatform(dir: updates);
      final m = await manifestFor(apkBytes);
      final stages = await UpdateInstaller(
        client: streaming(apkBytes),
        platform: platform,
      ).install(m).toList();
      expect(stages.last.stage, UpdateStage.handedOff);
      expect(platform.handedOff, hasLength(1));
      final path = platform.handedOff.single;
      expect(path, startsWith(updates.path));
      expect(path, endsWith('mobissh-update-192.apk'));
      expect(platform.bytesAtHandoff, apkBytes);
    });

    test('refused hand-off (R10) → file deleted, reason surfaced', () async {
      final platform = FakeUpdatePlatform(
        dir: updates,
        handoff: const UpdateHandoffResult(
          status: UpdateHandoffStatus.refused,
          reason: 'signing certificate does not match the installed app',
        ),
      );
      final m = await manifestFor(apkBytes);
      final stages = await UpdateInstaller(
        client: streaming(apkBytes),
        platform: platform,
      ).install(m).toList();
      expect(stages.last.stage, UpdateStage.failed);
      expect(stages.last.message, contains('signing certificate'));
      expect(platform.handedOff, hasLength(1));
      expect(apks(), isEmpty);
    });

    test('needs unknown-sources permission → persistent stage, verified file '
        'KEPT for the resume after the grant (R15)', () async {
      final platform = FakeUpdatePlatform(
        dir: updates,
        handoff: const UpdateHandoffResult(
          status: UpdateHandoffStatus.needsPermission,
        ),
      );
      final m = await manifestFor(apkBytes);
      final stages = await UpdateInstaller(
        client: streaming(apkBytes),
        platform: platform,
      ).install(m).toList();
      expect(stages.last.stage, UpdateStage.needsPermission);
      expect(stages.last.message, contains('install unknown apps'));
      expect(apks().map((f) => f.uri.pathSegments.last),
          <String>['mobissh-update-192.apk']);
    });

    test('a stored verified file is re-verified and handed off with NO HTTP '
        'request (R14/R15)', () async {
      final platform = FakeUpdatePlatform(dir: updates);
      final m = await manifestFor(apkBytes);
      updates.createSync(recursive: true);
      File('${updates.path}/mobissh-update-192.apk').writeAsBytesSync(apkBytes);
      var requests = 0;
      final stages = await UpdateInstaller(
        client: MockClient((_) async {
          requests++;
          return http.Response('', 500);
        }),
        platform: platform,
      ).install(m).toList();
      expect(requests, 0);
      expect(stages.where((s) => s.stage == UpdateStage.downloading), isEmpty);
      expect(stages.last.stage, UpdateStage.handedOff);
      expect(platform.bytesAtHandoff, apkBytes);
    });

    test('a stored file whose sha256 no longer matches is deleted and '
        're-fetched before any hand-off', () async {
      final platform = FakeUpdatePlatform(dir: updates);
      final m = await manifestFor(apkBytes);
      updates.createSync(recursive: true);
      final swapped = List<int>.of(apkBytes)..[7] ^= 0xff;
      File('${updates.path}/mobissh-update-192.apk').writeAsBytesSync(swapped);
      var requests = 0;
      final stages = await UpdateInstaller(
        client: MockClient.streaming((req, _) async {
          requests++;
          return http.StreamedResponse(Stream.value(apkBytes), 200,
              contentLength: apkBytes.length);
        }),
        platform: platform,
      ).install(m).toList();
      expect(requests, 1);
      expect(stages.last.stage, UpdateStage.handedOff);
      expect(platform.bytesAtHandoff, apkBytes,
          reason: 'the swapped file must never reach the installer');
    });

    test('verify failure on a re-fetch → no hand-off, nothing left', () async {
      final platform = FakeUpdatePlatform(dir: updates);
      final m = await manifestFor(apkBytes);
      updates.createSync(recursive: true);
      File('${updates.path}/mobissh-update-192.apk').writeAsStringSync('junk');
      final stages = await UpdateInstaller(
        client: streaming(List<int>.of(apkBytes)..[3] ^= 0xff),
        platform: platform,
      ).install(m).toList();
      expect(stages.last.stage, UpdateStage.failed);
      expect(platform.handedOff, isEmpty);
      expect(apks(), isEmpty);
    });

    test('pending notes are saved BEFORE the hand-off', () async {
      final platform = FakeUpdatePlatform(dir: updates);
      final m = await manifestFor(apkBytes);
      final events = <String>[];
      final installer = UpdateInstaller(
        client: streaming(apkBytes),
        platform: platform,
        onHandoff: (manifest) async => events.add('saved ${manifest.build}'),
      );
      await for (final p in installer.install(m)) {
        if (p.stage == UpdateStage.handedOff) {
          events.add('handed off ${platform.handedOff.length}');
        }
      }
      expect(events, <String>['saved 192', 'handed off 1']);
    });

    // R14 pre-download (nested: shares apkBytes / manifestFor).
    test('unmetered → downloads, verifies, writes, no hand-off → ready',
        () async {
      final platform = FakeUpdatePlatform(dir: updates)..unmetered = true;
      final p = await UpdateInstaller(
        client: MockClient.streaming((req, _) async =>
            http.StreamedResponse(Stream.value(apkBytes), 200)),
        platform: platform,
      ).prefetch(await manifestFor(apkBytes));
      expect(p.stage, UpdateStage.ready);
      expect(platform.handedOff, isEmpty);
      expect(File('${updates.path}/mobissh-update-192.apk').readAsBytesSync(),
          apkBytes);
    });

    test('metered → NO request, nothing written, stays idle', () async {
      final platform = FakeUpdatePlatform(dir: updates)..unmetered = false;
      var requests = 0;
      final p = await UpdateInstaller(
        client: MockClient((_) async {
          requests++;
          return http.Response('', 200);
        }),
        platform: platform,
      ).prefetch(await manifestFor(apkBytes));
      expect(p.stage, UpdateStage.idle);
      expect(requests, 0);
      expect(updates.existsSync(), isFalse);
    });

    test('sha mismatch → nothing written, idle (Install downloads as before)',
        () async {
      final platform = FakeUpdatePlatform(dir: updates);
      final p = await UpdateInstaller(
        client: MockClient.streaming((req, _) async => http.StreamedResponse(
            Stream.value(List<int>.of(apkBytes)..[0] ^= 1), 200)),
        platform: platform,
      ).prefetch(await manifestFor(apkBytes));
      expect(p.stage, UpdateStage.idle);
      expect(
        updates.existsSync() ? updates.listSync() : const <FileSystemEntity>[],
        isEmpty,
      );
    });

    test('progress WITH Content-Length reports a fraction', () async {
      final m = await manifestFor(apkBytes);
      final stages = await UpdateInstaller(
        client: streaming(apkBytes),
        platform: FakeUpdatePlatform(dir: updates),
      ).install(m).toList();
      final downloading =
          stages.where((s) => s.stage == UpdateStage.downloading).toList();
      expect(downloading.length, greaterThan(2));
      expect(downloading.last.total, apkBytes.length);
      expect(downloading.last.fraction, 1.0);
      expect(downloading.map((s) => s.received), orderedEquals(
        List<int>.of(downloading.map((s) => s.received))..sort(),
      ));
    });

    test('progress WITHOUT Content-Length is indeterminate', () async {
      final m = await manifestFor(apkBytes);
      final stages = await UpdateInstaller(
        client: streaming(apkBytes, withLength: false),
        platform: FakeUpdatePlatform(dir: updates),
      ).install(m).toList();
      final downloading =
          stages.where((s) => s.stage == UpdateStage.downloading).toList();
      expect(downloading.last.total, isNull);
      expect(downloading.last.fraction, isNull);
      expect(downloading.last.received, apkBytes.length);
      expect(stages.last.stage, UpdateStage.handedOff);
    });

    test('HTTP error on the APK → failed, nothing written', () async {
      final m = await manifestFor(apkBytes);
      final stages = await UpdateInstaller(
        client: MockClient((_) async => http.Response('gone', 404)),
        platform: FakeUpdatePlatform(dir: updates),
      ).install(m).toList();
      expect(stages.last.stage, UpdateStage.failed);
      expect(stages.last.message, contains('404'));
      expect(apks(), isEmpty);
    });

    test('redirects are NOT followed (the same-host rule would be bypassed)',
        () async {
      http.BaseRequest? seen;
      final m = await manifestFor(apkBytes);
      await UpdateInstaller(
        client: MockClient((req) async {
          seen = req;
          return http.Response('', 302,
              headers: {'location': 'https://evil.example.com/x.apk'});
        }),
        platform: FakeUpdatePlatform(dir: updates),
      ).install(m).toList();
      expect(seen!.followRedirects, isFalse);
    });
  });

  group('R12 cleanup', () {
    test('removes installed/older builds and strays, keeps a newer pending one',
        () async {
      updates.createSync(recursive: true);
      File('${updates.path}/mobissh-update-190.apk').writeAsStringSync('x');
      File('${updates.path}/mobissh-update-191.apk').writeAsStringSync('x');
      File('${updates.path}/mobissh-update-192.apk').writeAsStringSync('x');
      File('${updates.path}/something-else.apk').writeAsStringSync('x');
      await UpdateInstaller(
        client: MockClient((_) async => http.Response('', 500)),
        platform: FakeUpdatePlatform(dir: updates),
      ).cleanup(runningBuild: 191);
      final left = updates
          .listSync()
          .map((e) => e.uri.pathSegments.last)
          .toList();
      expect(left, <String>['mobissh-update-192.apk']);
    });

    test('unsupported platform → cleanup is a no-op, never throws', () async {
      await UpdateInstaller(
        client: MockClient((_) async => http.Response('', 500)),
        platform: FakeUpdatePlatform(dir: updates, supported: false),
      ).cleanup(runningBuild: 191);
    });
  });
}
