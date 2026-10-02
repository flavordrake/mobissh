// #1228: DartSshSftpSession UPLOADS against a REAL dartssh2 SftpClient whose
// peer is an in-process SFTP v3 server with an in-memory filesystem.
//
// The verified defects (server-side data loss):
//   1. HOLE — `uploadFile` resumed at `stat(.part).size`, but writes are
//      pipelined, so a cut `.part` can hold never-written zeros below its size.
//   2. SPLICE — any leftover `.part` not larger than the source was resumed
//      without checking its content: an edited same-name file published the
//      OLD head + the NEW tail as success.
//   3. RENAME FALLBACK — on rename failure the destination was REMOVED, then
//      the rename retried; a second failure lost the original.
//   4. NO POST-WRITE CHECK — neither path verified the server's size.
//
// The fixed contract pinned here: resume ONLY when every byte the `.part`
// holds equals the source prefix (read back and compared — identity AND
// contiguity), otherwise restart; verify the server size before publishing;
// publish with one rename (posix-rename overwrite when the server has it) and
// on failure keep BOTH files and throw; the whole-file `upload` (the editor
// save) is `.part` → verify → rename too, signature unchanged.
//
// Like sftp_session_short_read_1225_test.dart this speaks the wire protocol
// over an SSHChannelController, so open/write/read/stat/rename all go through
// the library's own client. The server logs every op so a test can assert
// what was NEVER sent (a `remove`, a `rename` after a size mismatch).

// ignore_for_file: implementation_imports

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:dartssh2/src/message/msg_channel.dart';
import 'package:dartssh2/src/sftp/sftp_packet.dart';
import 'package:dartssh2/src/ssh_channel.dart';
import 'package:dartssh2/src/ssh_message.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ssh/sftp_session.dart';

/// byte i = (i * 31 + i ~/ 251) & 0xff — the #1225/#1228 fixture formula.
Uint8List _formula(int n) {
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    out[i] = (i * 31 + i ~/ 251) & 0xff;
  }
  return out;
}

/// A second, unrelated content stream (the "edited same-name file").
Uint8List _other(int n) {
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    out[i] = (i * 17 + 5) & 0xff;
  }
  return out;
}

const _home = '/home/u';

/// An in-process SFTP v3 server over an in-memory filesystem.
class _FakeSftpServer {
  _FakeSftpServer({
    this.posixRename = true,
    this.failRename = false,
    this.dropWritesAtOrAbove,
    this.beforeOpen,
  }) {
    _controller = SSHChannelController(
      localId: 1,
      localMaximumPacketSize: 1024 * 1024,
      localInitialWindowSize: 64 * 1024 * 1024,
      remoteId: 2,
      remoteMaximumPacketSize: 1024 * 1024,
      remoteInitialWindowSize: 64 * 1024 * 1024,
      sendMessage: _onClientMessage,
    );
    client = SftpClient(_controller.channel);
  }

  /// Advertise `posix-rename@openssh.com` (OpenSSH does; a server without it
  /// only has the no-clobber SSH_FXP_RENAME).
  final bool posixRename;

  /// Every rename (either flavour) fails with SSH_FX_FAILURE.
  final bool failRename;

  /// Writes at or above this offset are ACKED but DROPPED — a server that lies
  /// about having stored the bytes, so the post-write size check must catch it.
  final int? dropWritesAtOrAbove;

  /// #1248: runs on the server just before an OPEN of a path is served — lets
  /// a test swap a symlink in between the client's lstat/remove and its open.
  final void Function(_FakeSftpServer server, String path)? beforeOpen;

  late final SSHChannelController _controller;
  late final SftpClient client;

  /// path → content. Directories are not modelled; only files.
  final files = <String, Uint8List>{};

  /// #1248: path → permission bits of a regular file (default [_umaskMode],
  /// the mode a fresh create gets). Moves with the file on rename.
  final modes = <String, int>{};

  /// #1248: path → owning uid (default [_me]). The server runs as [_me], not
  /// root: a chown to any other uid is EPERM, like a real sftp-server.
  final owners = <String, int>{};

  /// #1248: path → target of a symlink (one level). OPEN/STAT/SETSTAT follow
  /// it; LSTAT/REMOVE/RENAME act on the link itself; an EXCLUSIVE create of a
  /// link's name fails (O_CREAT|O_EXCL refuses even a dangling link).
  final links = <String, String>{};

  static const _umaskMode = 420; // 0644
  static const _me = 1000;

  int modeOf(String path) => modes[path] ?? _umaskMode;

  /// Every request the client sent, one line each, in order.
  final ops = <String>[];

  final _handles = <int, String>{};
  var _nextHandle = 1;

  void _onClientMessage(SSHMessage message) {
    if (message is! SSH_Message_Channel_Data) return;
    final reader = SSHMessageReader(message.data);
    final length = reader.readUint32();
    final payload = reader.readBytes(length);
    // Reply asynchronously, like a real peer, never re-entrantly.
    scheduleMicrotask(() => _handle_(payload));
  }

  void _status(int requestId, int code, [String message = '']) {
    _send(SftpStatusPacket(requestId: requestId, code: code, message: message));
  }

  void _ok(int requestId) => _status(requestId, SftpStatusCode.ok, 'ok');

  void _attrsFor(int requestId, String path, {bool follow = true}) {
    final link = links[path];
    if (link != null && !follow) {
      _send(SftpAttrsPacket(
        requestId,
        SftpFileAttrs(
          size: link.length,
          mode: const SftpFileMode.value(41471), // 0120777 symlink
          userID: _me,
          groupID: _me,
        ),
      ));
      return;
    }
    final real = link ?? path;
    final content = files[real];
    if (content == null) {
      _status(requestId, SftpStatusCode.noSuchFile, 'No such file');
      return;
    }
    _send(SftpAttrsPacket(
      requestId,
      SftpFileAttrs(
        size: content.length,
        mode: SftpFileMode.value(32768 | modeOf(real)), // 0100000 | perms
        userID: owners[real] ?? _me,
        groupID: _me,
      ),
    ));
  }

  /// SETSTAT / FSETSTAT on the (already link-resolved) [path].
  void _setStat(int requestId, String path, SftpFileAttrs a, String verb) {
    if (!files.containsKey(path)) {
      _status(requestId, SftpStatusCode.noSuchFile, 'No such file');
      return;
    }
    final uid = a.userID;
    if (uid != null) {
      ops.add('$verb $path uid=$uid');
      if (uid != (owners[path] ?? _me) || uid != _me) {
        _status(requestId, SftpStatusCode.permissionDenied, 'Permission denied');
        return;
      }
    }
    final mode = a.mode;
    if (mode != null) {
      ops.add('$verb $path mode=${(mode.value & 4095).toRadixString(8)}');
      modes[path] = mode.value & 4095;
    }
    _ok(requestId);
  }

  String _pathOf(Uint8List handle) {
    final id = ByteData.sublistView(handle).getUint32(0);
    return _handles[id]!;
  }

  void _rename(int requestId, String from, String to, {required bool clobber}) {
    if (failRename) {
      _status(requestId, SftpStatusCode.failure, 'Failure');
      return;
    }
    final link = links[from];
    final content = files[from];
    if (content == null && link == null) {
      _status(requestId, SftpStatusCode.noSuchFile, 'No such file');
      return;
    }
    if (!clobber && (files.containsKey(to) || links.containsKey(to))) {
      // The standard SSH_FXP_RENAME must not overwrite (OpenSSH says Failure).
      _status(requestId, SftpStatusCode.failure, 'Failure');
      return;
    }
    // rename(2) moves the NAME: a link stays a link, a file keeps its mode.
    files.remove(to);
    modes.remove(to);
    owners.remove(to);
    links.remove(to);
    if (link != null) {
      links[to] = links.remove(from)!;
    } else {
      files[to] = files.remove(from)!;
      final m = modes.remove(from);
      if (m != null) modes[to] = m;
      final o = owners.remove(from);
      if (o != null) owners[to] = o;
    }
    _ok(requestId);
  }

  void _handle_(Uint8List payload) {
    switch (payload[0]) {
      case SftpInitPacket.packetType:
        _send(SftpVersionPacket(
          3,
          posixRename ? {'posix-rename@openssh.com': '1'} : {},
        ));
      case SftpRealpathPacket.packetType:
        final p = SftpRealpathPacket.decode(payload);
        _send(SftpNamePacket(p.requestId, [
          SftpName(filename: _home, longname: _home, attr: SftpFileAttrs()),
        ]));
      case SftpOpenPacket.packetType:
        final p = SftpOpenPacket.decode(payload);
        beforeOpen?.call(this, p.path);
        ops.add('open ${p.path} flags=${p.flags}');
        final create = p.flags & SftpFileOpenMode.create.flag != 0;
        final truncate = p.flags & SftpFileOpenMode.truncate.flag != 0;
        final exclusive = p.flags & SftpFileOpenMode.exclusive.flag != 0;
        if (exclusive && links.containsKey(p.path)) {
          _status(p.requestId, SftpStatusCode.failure, 'Failure');
          return;
        }
        // open(2) without O_NOFOLLOW follows a link to its target.
        final path = links[p.path] ?? p.path;
        final exists = files.containsKey(path);
        if (!exists && !create) {
          _status(p.requestId, SftpStatusCode.noSuchFile, 'No such file');
          return;
        }
        if (exists && exclusive) {
          _status(p.requestId, SftpStatusCode.failure, 'Failure');
          return;
        }
        if (!exists || truncate) files[path] = Uint8List(0);
        final id = _nextHandle++;
        _handles[id] = path;
        _send(SftpHandlePacket(
          p.requestId,
          Uint8List(4)..buffer.asByteData().setUint32(0, id),
        ));
      case SftpWritePacket.packetType:
        final p = SftpWritePacket.decode(payload);
        final path = _pathOf(p.handle);
        ops.add('write $path @${p.offset} +${p.data.length}');
        final drop = dropWritesAtOrAbove;
        if (drop != null && p.offset >= drop) {
          _ok(p.requestId); // acked, never stored
          return;
        }
        final old = files[path]!;
        final end = p.offset + p.data.length;
        // A write past the current end zero-fills the gap: that is exactly
        // how a pipelined upload leaves a HOLE when it is cut.
        final grown = end > old.length ? (Uint8List(end)..setAll(0, old)) : old;
        grown.setRange(p.offset, end, p.data);
        files[path] = grown;
        _ok(p.requestId);
      case SftpReadPacket.packetType:
        final p = SftpReadPacket.decode(payload);
        final content = files[_pathOf(p.handle)]!;
        if (p.offset >= content.length) {
          _status(p.requestId, SftpStatusCode.eof, 'EOF');
          return;
        }
        final end = (p.offset + p.length).clamp(0, content.length);
        _send(SftpDataPacket(
          p.requestId,
          Uint8List.sublistView(content, p.offset, end),
        ));
      case SftpStatPacket.packetType:
        final p = SftpStatPacket.decode(payload);
        ops.add('stat ${p.path}');
        _attrsFor(p.requestId, p.path);
      case SftpLStatPacket.packetType:
        final p = SftpLStatPacket.decode(payload);
        ops.add('lstat ${p.path}');
        _attrsFor(p.requestId, p.path, follow: false);
      case SftpFStatPacket.packetType:
        final p = SftpFStatPacket.decode(payload);
        final path = _pathOf(p.handle);
        ops.add('fstat $path');
        _attrsFor(p.requestId, path);
      case SftpClosePacket.packetType:
        _ok(SftpClosePacket.decode(payload).requestId);
      case SftpRemovePacket.packetType:
        final p = SftpRemovePacket.decode(payload);
        ops.add('remove ${p.filename}');
        // unlink(2) removes a link itself, never its target.
        if (links.remove(p.filename) == null &&
            files.remove(p.filename) == null) {
          _status(p.requestId, SftpStatusCode.noSuchFile, 'No such file');
          return;
        }
        modes.remove(p.filename);
        owners.remove(p.filename);
        _ok(p.requestId);
      case SftpSetStatPacket.packetType:
        final p = SftpSetStatPacket.decode(payload);
        final path = links[p.path] ?? p.path;
        _setStat(p.requestId, path, p.attributes, 'setstat');
      case SftpFSetStatPacket.packetType:
        final p = SftpFSetStatPacket.decode(payload);
        _setStat(p.requestId, _pathOf(p.handle), p.attributes, 'fsetstat');
      case SftpRenamePacket.packetType:
        final p = SftpRenamePacket.decode(payload);
        ops.add('rename ${p.oldPath} ${p.newPath}');
        _rename(p.requestId, p.oldPath, p.newPath, clobber: false);
      case SftpExtendedPacket.packetType:
        final p = SftpExtendedPacket.decode(payload);
        final r = SSHMessageReader(p.payload);
        final name = r.readUtf8();
        if (name != 'posix-rename@openssh.com') {
          _status(p.requestId, SftpStatusCode.opUnsupported, 'Unsupported');
          return;
        }
        final from = r.readUtf8();
        final to = r.readUtf8();
        ops.add('posix-rename $from $to');
        _rename(p.requestId, from, to, clobber: true);
      default:
        fail('fake SFTP server: unexpected packet type ${payload[0]}');
    }
  }

  void _send(SftpPacket packet) {
    final body = packet.encode();
    final writer = SSHMessageWriter();
    writer.writeUint32(body.length);
    writer.writeBytes(body);
    _controller.handleMessage(
      SSH_Message_Channel_Data(
        recipientChannel: _controller.localId,
        data: writer.takeBytes(),
      ),
    );
  }

  void dispose() {
    unawaited(client.close());
    _controller.destroy();
  }
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mobissh_1228_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  _FakeSftpServer serve({
    bool posixRename = true,
    bool failRename = false,
    int? dropWritesAtOrAbove,
    void Function(_FakeSftpServer server, String path)? beforeOpen,
  }) {
    final s = _FakeSftpServer(
      posixRename: posixRename,
      failRename: failRename,
      dropWritesAtOrAbove: dropWritesAtOrAbove,
      beforeOpen: beforeOpen,
    );
    addTearDown(s.dispose);
    return s;
  }

  Future<String> localFile(Uint8List bytes, [String name = 'src.bin']) async {
    final f = File('${tmp.path}/$name');
    await f.writeAsBytes(bytes, flush: true);
    return f.path;
  }

  const dest = '$_home/f.bin';
  const part = '$dest.part';

  /// The smallest write offset the client sent to [path] (null: none).
  int? lowestWrite(_FakeSftpServer s, String path) {
    int? low;
    for (final op in s.ops) {
      final m = RegExp(r'^write (\S+) @(\d+) ').firstMatch(op);
      if (m == null || m.group(1) != path) continue;
      final o = int.parse(m.group(2)!);
      if (low == null || o < low) low = o;
    }
    return low;
  }

  Iterable<String> opsNamed(_FakeSftpServer s, String verb) =>
      s.ops.where((o) => o.startsWith('$verb '));

  group('uploadFile — resume decision table (#1228)', () {
    for (final n in [32769, 94915, 1048589]) {
      test('fresh upload of $n bytes: exact, .part gone, progress 0→n, '
          'published by one posix-rename, nothing removed', () async {
        final s = serve();
        final want = _formula(n);
        final session = DartSshSftpSession(s.client);
        final progress = <(int, int)>[];

        final total = await session.uploadFile(
          await localFile(want),
          dest,
          onProgress: (a, b) => progress.add((a, b)),
        );

        expect(total, n);
        expect(s.files[dest], want);
        expect(s.files.containsKey(part), isFalse, reason: '.part left behind');
        expect(progress.first.$1, 0);
        expect(progress.last, (n, n));
        expect(progress.every((p) => p.$2 == n), isTrue);
        expect(opsNamed(s, 'remove'), isEmpty,
            reason: 'publish must never delete anything');
        expect(opsNamed(s, 'posix-rename').toList(), ['posix-rename $part $dest']);
        expect(opsNamed(s, 'rename'), isEmpty);
      });
    }

    test('5 MiB fresh upload is exact', () async {
      final s = serve();
      final want = _formula(5 * 1024 * 1024);
      final session = DartSshSftpSession(s.client);
      await session.uploadFile(await localFile(want), dest,
          onProgress: (_, _) {});
      expect(s.files[dest], want);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('.part == exact source prefix → RESUMES: no write below its size, '
        'progress starts at the resume offset, result exact', () async {
      const n = 94915;
      const partLen = 40000;
      final s = serve();
      final want = _formula(n);
      s.files[part] = Uint8List.sublistView(want, 0, partLen);
      final session = DartSshSftpSession(s.client);
      final progress = <(int, int)>[];

      await session.uploadFile(await localFile(want), dest,
          onProgress: (a, b) => progress.add((a, b)));

      expect(s.files[dest], want);
      expect(s.files.containsKey(part), isFalse);
      expect(lowestWrite(s, part), partLen,
          reason: 'a verified prefix must be resumed, not rewritten');
      expect(progress.first, (partLen, n));
      expect(progress.last, (n, n));
    });

    for (final (label, holeLo) in [('third', 32768), ('second', 16384)]) {
      test('.part with a HOLE ($label 16 KiB write lost) → restarts from 0, '
          'result exact with no zeros', () async {
        const n = 94915;
        final s = serve();
        final want = _formula(n);
        final holed = Uint8List.fromList(want.sublist(0, 65536));
        holed.fillRange(holeLo, holeLo + 16384, 0);
        s.files[part] = holed;
        final session = DartSshSftpSession(s.client);

        await session.uploadFile(await localFile(want), dest,
            onProgress: (_, _) {});

        expect(s.files[dest], want);
        expect(s.files.containsKey(part), isFalse);
        expect(lowestWrite(s, part), 0, reason: 'a holed .part is not trusted');
      });
    }

    test('.part with DIFFERENT content (edited same-name file) → restarts, '
        'result equals the NEW source exactly (no splice)', () async {
      const n = 94915;
      final s = serve();
      final want = _formula(n);
      s.files[part] = _other(65536);
      final session = DartSshSftpSession(s.client);

      await session.uploadFile(await localFile(want), dest,
          onProgress: (_, _) {});

      expect(s.files[dest], want);
      expect(s.files.containsKey(part), isFalse);
      expect(lowestWrite(s, part), 0);
    });

    test('.part that differs only in its LAST byte → restarts (the whole '
        'prefix is compared, not just a head)', () async {
      const n = 94915;
      final s = serve();
      final want = _formula(n);
      final nearly = Uint8List.fromList(want.sublist(0, 65536));
      nearly[65535] ^= 0xff;
      s.files[part] = nearly;
      final session = DartSshSftpSession(s.client);

      await session.uploadFile(await localFile(want), dest,
          onProgress: (_, _) {});

      expect(s.files[dest], want);
      expect(lowestWrite(s, part), 0);
    });

    test('.part LARGER than the source → truncated restart, result is exactly '
        'the source size', () async {
      const n = 94915;
      final s = serve();
      final want = _formula(n);
      s.files[part] = _formula(100000); // a superset prefix, still stale
      final session = DartSshSftpSession(s.client);

      await session.uploadFile(await localFile(want), dest,
          onProgress: (_, _) {});

      expect(s.files[dest], want);
      expect(s.files[dest]!.length, n);
      expect(lowestWrite(s, part), 0);
      // #1248: a restart removes the stale `.part` and creates it EXCLUSIVELY
      // (never truncate-open a name that could be a link). Only `.part` goes.
      expect(opsNamed(s, 'remove').toList(), ['remove $part']);
    });

    test('.part already holds the whole file (cut before the rename) → no '
        'writes at all, just verify + publish', () async {
      const n = 32769;
      final s = serve();
      final want = _formula(n);
      s.files[part] = Uint8List.fromList(want);
      final session = DartSshSftpSession(s.client);
      final progress = <(int, int)>[];

      await session.uploadFile(await localFile(want), dest,
          onProgress: (a, b) => progress.add((a, b)));

      expect(s.files[dest], want);
      expect(opsNamed(s, 'write'), isEmpty);
      expect(progress.last, (n, n));
    });

    test('a same-size .part with the whole file but one wrong byte → restarts',
        () async {
      const n = 32769;
      final s = serve();
      final want = _formula(n);
      final wrong = Uint8List.fromList(want);
      wrong[12345] ^= 0x01;
      s.files[part] = wrong;
      final session = DartSshSftpSession(s.client);

      await session.uploadFile(await localFile(want), dest,
          onProgress: (_, _) {});

      expect(s.files[dest], want);
      expect(lowestWrite(s, part), 0);
    });
  });

  group('uploadFile — publish (#1228)', () {
    test('an existing destination is replaced by posix-rename; it is NEVER '
        'removed first', () async {
      final s = serve();
      final want = _formula(32769);
      s.files[dest] = _other(5000);
      final session = DartSshSftpSession(s.client);

      await session.uploadFile(await localFile(want), dest,
          onProgress: (_, _) {});

      expect(s.files[dest], want);
      expect(opsNamed(s, 'remove'), isEmpty);
    });

    test('rename FAILS → throws UploadPublishException naming both paths; the '
        'original is intact and the complete .part is kept', () async {
      final s = serve(failRename: true);
      final want = _formula(32769);
      final original = _other(5000);
      s.files[dest] = Uint8List.fromList(original);
      final session = DartSshSftpSession(s.client);

      await expectLater(
        session.uploadFile(await localFile(want), dest, onProgress: (_, _) {}),
        throwsA(isA<UploadPublishException>()
            .having((e) => e.partPath, 'partPath', part)
            .having((e) => e.destination, 'destination', dest)
            .having((e) => e.toString(), 'message', contains(dest))
            .having((e) => e.toString(), 'message', contains(part))),
      );
      expect(s.files[dest], original, reason: 'the original must survive');
      expect(s.files[part], want, reason: 'the new content must be kept');
      expect(opsNamed(s, 'remove'), isEmpty,
          reason: 'never delete the destination to make room');
    });

    test('server WITHOUT posix-rename and an existing destination → the plain '
        'rename refuses; fails loudly, both files kept', () async {
      final s = serve(posixRename: false);
      final want = _formula(32769);
      final original = _other(5000);
      s.files[dest] = Uint8List.fromList(original);
      final session = DartSshSftpSession(s.client);

      await expectLater(
        session.uploadFile(await localFile(want), dest, onProgress: (_, _) {}),
        throwsA(isA<UploadPublishException>()),
      );
      expect(s.files[dest], original);
      expect(s.files[part], want);
      expect(opsNamed(s, 'remove'), isEmpty);
      expect(opsNamed(s, 'posix-rename'), isEmpty);
    });

    test('server WITHOUT posix-rename and NO existing destination → the plain '
        'rename publishes fine', () async {
      final s = serve(posixRename: false);
      final want = _formula(32769);
      final session = DartSshSftpSession(s.client);

      await session.uploadFile(await localFile(want), dest,
          onProgress: (_, _) {});

      expect(s.files[dest], want);
      expect(s.files.containsKey(part), isFalse);
      expect(opsNamed(s, 'rename').toList(), ['rename $part $dest']);
    });

    test('server DROPS bytes (acked, not stored) → UploadIncompleteException '
        'with both sizes; nothing is published, the original is intact',
        () async {
      const n = 94915;
      final s = serve(dropWritesAtOrAbove: 65536);
      final want = _formula(n);
      final original = _other(5000);
      s.files[dest] = Uint8List.fromList(original);
      final session = DartSshSftpSession(s.client);

      await expectLater(
        session.uploadFile(await localFile(want), dest, onProgress: (_, _) {}),
        throwsA(isA<UploadIncompleteException>()
            .having((e) => e.written, 'written', 65536)
            .having((e) => e.expected, 'expected', n)
            .having((e) => e.toString(), 'message',
                'Upload incomplete: server has 65536 of $n bytes')),
      );
      expect(s.files[dest], original);
      expect(opsNamed(s, 'rename'), isEmpty);
      expect(opsNamed(s, 'posix-rename'), isEmpty);
      expect(opsNamed(s, 'remove'), isEmpty);
    });

    test('~-relative destination resolves against the SFTP home', () async {
      final s = serve();
      final want = _formula(1000);
      final session = DartSshSftpSession(s.client);
      await session.uploadFile(await localFile(want), '~/sub/x.bin',
          onProgress: (_, _) {});
      expect(s.files['$_home/sub/x.bin'], want);
    });
  });

  group('upload — whole-file (the editor save path, #892/#1227)', () {
    test('writes to .part, verifies, renames over an existing destination; '
        'exact content, no .part, nothing removed', () async {
      final s = serve();
      final want = _formula(94915);
      s.files[dest] = _other(5000);
      final session = DartSshSftpSession(s.client);

      final written = await session.upload(dest, want);

      expect(written, 94915);
      expect(s.files[dest], want);
      expect(s.files.containsKey(part), isFalse);
      expect(opsNamed(s, 'remove'), isEmpty);
      expect(opsNamed(s, 'posix-rename').toList(), ['posix-rename $part $dest']);
      // The destination itself is never opened for writing: a crash mid-write
      // can no longer leave it half-written (the #1227 non-atomic save).
      expect(s.ops.where((o) => o.startsWith('open $dest ')), isEmpty);
    });

    test('an empty save works (0 bytes)', () async {
      final s = serve();
      s.files[dest] = _other(5000);
      final session = DartSshSftpSession(s.client);
      expect(await session.upload(dest, Uint8List(0)), 0);
      expect(s.files[dest], Uint8List(0));
      expect(s.files.containsKey(part), isFalse);
    });

    test('rename FAILS → UploadPublishException, original intact, .part kept',
        () async {
      final s = serve(failRename: true);
      final want = _formula(32769);
      final original = _other(5000);
      s.files[dest] = Uint8List.fromList(original);
      final session = DartSshSftpSession(s.client);

      await expectLater(session.upload(dest, want),
          throwsA(isA<UploadPublishException>()));
      expect(s.files[dest], original);
      expect(s.files[part], want);
      expect(opsNamed(s, 'remove'), isEmpty);
    });

    test('server DROPS bytes → UploadIncompleteException, nothing published',
        () async {
      final s = serve(dropWritesAtOrAbove: 16384);
      final want = _formula(32769);
      final original = _other(5000);
      s.files[dest] = Uint8List.fromList(original);
      final session = DartSshSftpSession(s.client);

      await expectLater(
        session.upload(dest, want),
        throwsA(isA<UploadIncompleteException>()
            .having((e) => e.written, 'written', 16384)
            .having((e) => e.expected, 'expected', 32769)),
      );
      expect(s.files[dest], original);
      expect(opsNamed(s, 'posix-rename'), isEmpty);
    });

    test('a stale .part from an interrupted uploadFile is simply replaced',
        () async {
      final s = serve();
      final want = _formula(32769);
      s.files[part] = _other(65536);
      final session = DartSshSftpSession(s.client);
      await session.upload(dest, want);
      expect(s.files[dest], want);
      expect(s.files.containsKey(part), isFalse);
    });

    test('~-relative path resolves against the SFTP home (#867)', () async {
      final s = serve();
      final want = _formula(1000);
      final session = DartSshSftpSession(s.client);
      await session.upload('~/.ssh/config', want);
      expect(s.files['$_home/.ssh/config'], want);
    });
  });

  // #1248 (release blocker, regression from #1228): the `.part` got the
  // server's default mode and the rename made it the file's mode (0600
  // `~/.ssh/config` → 0644, refused by OpenSSH; scripts lost +x); and a
  // pre-existing symlink `.part` was followed, writing the bytes to its target.
  group('#1248 — the destination\'s mode survives the publish', () {
    /// Index of the first op matching [prefix] (-1: none).
    int firstOp(_FakeSftpServer s, String prefix) =>
        s.ops.indexWhere((o) => o.startsWith(prefix));

    test('upload: a 0600 file stays 0600, and the .part is chmodded BEFORE '
        'any byte is written (a secret is never staged world-readable)',
        () async {
      final s = serve();
      s.files[dest] = _other(5000);
      s.modes[dest] = 384; // 0600
      final want = _formula(32769);

      await DartSshSftpSession(s.client).upload(dest, want);

      expect(s.files[dest], want);
      expect(s.modeOf(dest).toRadixString(8), '600');
      final chmod = firstOp(s, 'fsetstat $part mode=600');
      expect(chmod, isNonNegative, reason: 'the .part handle gets the mode');
      expect(chmod, lessThan(firstOp(s, 'write $part')));
    });

    test('uploadFile: a 0755 file stays 0755', () async {
      final s = serve();
      s.files[dest] = _other(5000);
      s.modes[dest] = 493; // 0755
      final want = _formula(94915);

      await DartSshSftpSession(s.client)
          .uploadFile(await localFile(want), dest, onProgress: (_, _) {});

      expect(s.files[dest], want);
      expect(s.modeOf(dest).toRadixString(8), '755');
    });

    test('uploadFile RESUME of a verified .part: 0600 still survives', () async {
      const n = 94915;
      final s = serve();
      final want = _formula(n);
      s.files[dest] = _other(5000);
      s.modes[dest] = 384;
      s.files[part] = Uint8List.sublistView(want, 0, 40000);

      await DartSshSftpSession(s.client)
          .uploadFile(await localFile(want), dest, onProgress: (_, _) {});

      expect(s.files[dest], want);
      expect(lowestWrite(s, part), 40000, reason: 'still a resume');
      expect(s.modeOf(dest).toRadixString(8), '600');
    });

    test('uploadFile whose .part already holds everything (no writes): 0700 '
        'still survives', () async {
      const n = 32769;
      final s = serve();
      final want = _formula(n);
      s.files[dest] = _other(5000);
      s.modes[dest] = 448; // 0700
      s.files[part] = Uint8List.fromList(want);

      await DartSshSftpSession(s.client)
          .uploadFile(await localFile(want), dest, onProgress: (_, _) {});

      expect(s.files[dest], want);
      expect(opsNamed(s, 'write'), isEmpty);
      expect(s.modeOf(dest).toRadixString(8), '700');
    });

    test('a NEW destination keeps the server default mode', () async {
      final s = serve();
      await DartSshSftpSession(s.client).upload(dest, _formula(1000));
      expect(s.modeOf(dest).toRadixString(8), '644');
    });

    test('a destination owned by another user: the chown is refused (EPERM, '
        'ignored), the mode is still preserved and the save succeeds',
        () async {
      final s = serve();
      s.files[dest] = _other(5000);
      s.modes[dest] = 416; // 0640
      s.owners[dest] = 0;
      final want = _formula(1000);

      await DartSshSftpSession(s.client).upload(dest, want);

      expect(s.files[dest], want);
      expect(s.modeOf(dest).toRadixString(8), '640');
      expect(firstOp(s, 'fsetstat $part uid=0'), isNonNegative,
          reason: 'ownership is attempted');
    });
  });

  group('#1248 — a symlink .part is never written through', () {
    const canary = '$_home/canary';

    test('upload: a pre-existing symlink .part is removed (the link, not its '
        'target), the target is unchanged, the destination is correct',
        () async {
      final s = serve();
      final canaryBytes = _other(777);
      s.files[canary] = Uint8List.fromList(canaryBytes);
      s.links[part] = canary;
      final want = _formula(32769);

      await DartSshSftpSession(s.client).upload(dest, want);

      expect(s.files[canary], canaryBytes, reason: 'written through the link');
      expect(s.files[dest], want);
      expect(s.links, isEmpty);
      expect(opsNamed(s, 'remove').toList(), ['remove $part']);
    });

    test('uploadFile fresh: a symlink .part is removed, never followed',
        () async {
      final s = serve();
      final canaryBytes = _other(777);
      s.files[canary] = Uint8List.fromList(canaryBytes);
      s.links[part] = canary;
      final want = _formula(94915);

      await DartSshSftpSession(s.client)
          .uploadFile(await localFile(want), dest, onProgress: (_, _) {});

      expect(s.files[canary], canaryBytes);
      expect(s.files[dest], want);
      expect(s.links, isEmpty);
    });

    test('uploadFile RESUME: a symlink .part whose target IS a valid source '
        'prefix is not resumed (never read, never appended to)', () async {
      const n = 94915;
      final s = serve();
      final want = _formula(n);
      final canaryBytes = Uint8List.fromList(want.sublist(0, 40000));
      s.files[canary] = Uint8List.fromList(canaryBytes);
      s.links[part] = canary;

      await DartSshSftpSession(s.client)
          .uploadFile(await localFile(want), dest, onProgress: (_, _) {});

      expect(s.files[canary], canaryBytes, reason: 'appended through the link');
      expect(s.files[dest], want);
      expect(s.links, isEmpty);
      expect(lowestWrite(s, part), 0, reason: 'a link is not a resumable .part');
      expect(s.ops.where((o) => o == 'open $part flags=1'), isEmpty,
          reason: 'the link was opened for the resume read-back');
    });

    for (final viaFile in [false, true]) {
      test('${viaFile ? 'uploadFile' : 'upload'}: a symlink swapped in at the '
          'open makes the EXCLUSIVE create fail loudly; target and '
          'destination untouched', () async {
        final s = serve(beforeOpen: (srv, path) {
          if (path == part) srv.links[part] = canary;
        });
        final canaryBytes = _other(777);
        final original = _other(5000);
        s.files[canary] = Uint8List.fromList(canaryBytes);
        s.files[dest] = Uint8List.fromList(original);
        final want = _formula(32769);
        final session = DartSshSftpSession(s.client);

        final run = viaFile
            ? session.uploadFile(await localFile(want), dest,
                onProgress: (_, _) {})
            : session.upload(dest, want);

        await expectLater(
          run,
          throwsA(isA<UploadStagingException>()
              .having((e) => e.partPath, 'partPath', part)
              .having((e) => e.toString(), 'message', contains(part))),
        );
        expect(s.files[canary], canaryBytes);
        expect(s.files[dest], original);
        expect(opsNamed(s, 'write'), isEmpty);
        expect(opsNamed(s, 'posix-rename'), isEmpty);
      });
    }
  });
}
