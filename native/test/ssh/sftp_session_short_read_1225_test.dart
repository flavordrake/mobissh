// #1225: DartSshSftpSession downloads against a REAL dartssh2 SftpClient whose
// peer is an in-process SFTP server that answers READs SHORT (the owner's
// server answered a 64 KiB READ with 32 KiB and the app published a file
// missing bytes 32,768..65,535 with a success snackbar).
//
// Every fake in the rest of the suite returns full chunks, which is why #1225
// hid. Here the client is the library's own, so the test pins the contract the
// app relies on — dartssh2 4.1.0 re-requests the remainder of a short read —
// and the app's own guard on top of it: a download is complete only when the
// bytes received equal the size the server reported for the open handle.
//
// The fake server speaks the SFTP v3 wire protocol over an SSHChannelController
// (the harness dartssh2's own sftp_file_test uses), so this reaches into
// dartssh2's src/ for the channel + packet codecs. No dartssh2 behaviour is
// stubbed: open/fstat/read/close all go through the real SftpClient.

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

/// byte i = (i * 31 + i ~/ 251) & 0xff — the #1225 fixture formula.
Uint8List _formula(int n) {
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    out[i] = (i * 31 + i ~/ 251) & 0xff;
  }
  return out;
}

/// An in-process SFTP v3 server holding one file.
///
/// [readCap] caps every READ reply (the short read under test). [statSize] is
/// what STAT/FSTAT report; when it differs from [content]'s length the server
/// models a file that shrank (or a lying size): READs return EOF at the real
/// end, so a reader that trusts the stream would publish a short file.
class _FakeSftpServer {
  _FakeSftpServer({
    required this.content,
    required this.readCap,
    int? statSize,
    this.reportSize = true,
  }) : statSize = statSize ?? content.length {
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

  final Uint8List content;
  final int readCap;
  final int statSize;
  final bool reportSize;

  late final SSHChannelController _controller;
  late final SftpClient client;

  /// The length of every READ the client asked for, in order.
  final List<int> readRequests = [];

  /// How many READ replies were cut short by [readCap].
  int cappedReads = 0;

  static final _handle = Uint8List.fromList([7, 7, 7, 7]);

  void _onClientMessage(SSHMessage message) {
    if (message is! SSH_Message_Channel_Data) return;
    final reader = SSHMessageReader(message.data);
    final length = reader.readUint32();
    final payload = reader.readBytes(length);
    // Reply asynchronously, like a real peer, never re-entrantly.
    scheduleMicrotask(() => _handle_(payload));
  }

  SftpFileAttrs get _attrs =>
      reportSize ? SftpFileAttrs(size: statSize) : SftpFileAttrs();

  void _handle_(Uint8List payload) {
    switch (payload[0]) {
      case SftpInitPacket.packetType:
        _send(SftpVersionPacket(3, {}));
      case SftpRealpathPacket.packetType:
        final p = SftpRealpathPacket.decode(payload);
        _send(SftpNamePacket(p.requestId, [
          SftpName(filename: '/home/u', longname: '/home/u', attr: SftpFileAttrs()),
        ]));
      case SftpOpenPacket.packetType:
        _send(SftpHandlePacket(SftpOpenPacket.decode(payload).requestId, _handle));
      case SftpStatPacket.packetType:
        _send(SftpAttrsPacket(SftpStatPacket.decode(payload).requestId, _attrs));
      case SftpLStatPacket.packetType:
        _send(SftpAttrsPacket(SftpLStatPacket.decode(payload).requestId, _attrs));
      case SftpFStatPacket.packetType:
        _send(SftpAttrsPacket(SftpFStatPacket.decode(payload).requestId, _attrs));
      case SftpReadPacket.packetType:
        final r = SftpReadPacket.decode(payload);
        readRequests.add(r.length);
        if (r.offset >= content.length) {
          _send(SftpStatusPacket(
            requestId: r.requestId,
            code: SftpStatusCode.eof,
            message: 'EOF',
          ));
          return;
        }
        var n = r.length;
        if (n > readCap) {
          n = readCap;
          cappedReads++;
        }
        final end = (r.offset + n).clamp(0, content.length);
        _send(SftpDataPacket(
          r.requestId,
          Uint8List.sublistView(content, r.offset, end),
        ));
      case SftpClosePacket.packetType:
        _send(SftpStatusPacket(
          requestId: SftpClosePacket.decode(payload).requestId,
          code: SftpStatusCode.ok,
          message: 'ok',
        ));
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
    tmp = await Directory.systemTemp.createTemp('mobissh_1225_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  _FakeSftpServer serve(
    Uint8List content, {
    required int readCap,
    int? statSize,
    bool reportSize = true,
  }) {
    final s = _FakeSftpServer(
      content: content,
      readCap: readCap,
      statSize: statSize,
      reportSize: reportSize,
    );
    addTearDown(s.dispose);
    return s;
  }

  group('downloadFile (the #976 browser Download path)', () {
    for (final n in [1, 32767, 32768, 32769, 65535, 65536, 65537, 94915,
        1048589]) {
      test('size=$n through a 32 KiB READ cap arrives byte-exact', () async {
        final want = _formula(n);
        final server = serve(want, readCap: 32 * 1024);
        final session = DartSshSftpSession(server.client);
        final local = '${tmp.path}/dl_$n.bin';
        final progress = <(int, int)>[];

        final done = await session.downloadFile(
          '/home/u/f.bin',
          local,
          onProgress: (d, t) => progress.add((d, t)),
        );

        expect(done, n);
        expect(await File(local).readAsBytes(), want);
        expect(progress.last, (n, n));
        expect(progress.every((p) => p.$2 == n), isTrue,
            reason: 'progress total is the server-reported size');
        if (n > 32 * 1024) {
          expect(server.cappedReads, greaterThan(0),
              reason: 'the short-read path must actually be exercised');
        }
      });
    }

    test('the owner case: stat says 94,915 but the stream ends at 62,147 → '
        'throws "Download incomplete" and deletes the partial', () async {
      final server = serve(
        _formula(62147),
        readCap: 32 * 1024,
        statSize: 94915,
      );
      final session = DartSshSftpSession(server.client);
      final local = '${tmp.path}/short.bin';

      await expectLater(
        session.downloadFile('/home/u/f.bin', local, onProgress: (_, _) {}),
        throwsA(isA<DownloadIncompleteException>()
            .having((e) => e.received, 'received', 62147)
            .having((e) => e.expected, 'expected', 94915)
            .having((e) => e.toString(), 'message',
                'Download incomplete: got 62147 of 94915 bytes')),
      );
      expect(File(local).existsSync(), isFalse,
          reason: 'a short file must never be left to publish');
    });

    test('size 0 from stat (a /proc-style file) reads to EOF and reports the '
        'count, no false mismatch', () async {
      final want = _formula(5000);
      final server = serve(want, readCap: 32 * 1024, statSize: 0);
      final session = DartSshSftpSession(server.client);
      final local = '${tmp.path}/proc.bin';

      final done = await session.downloadFile(
        '/proc/x',
        local,
        onProgress: (_, _) {},
      );
      expect(done, 5000);
      expect(await File(local).readAsBytes(), want);
    });

    test('uses the library default request size (no 64 KiB override)', () async {
      final server = serve(_formula(300000), readCap: 1 << 30);
      final session = DartSshSftpSession(server.client);
      await session.downloadFile(
        '/home/u/f.bin',
        '${tmp.path}/d.bin',
        onProgress: (_, _) {},
      );
      // downloadTo's default is 64 KiB in 4.1.0; the point is that the app no
      // longer chooses — whatever the library sends, nothing larger.
      expect(server.readRequests.reduce((a, b) => a > b ? a : b),
          lessThanOrEqualTo(64 * 1024));
    });
  });

  group('download (the chunk path: viewers, editor, Share)', () {
    Future<Uint8List> reassemble(
      DartSshSftpSession session, {
      void Function(int)? onTotal,
    }) async {
      final byOffset = <int, Uint8List>{};
      final total = await session.download(
        '/home/u/f.bin',
        onChunk: (c, o) => byOffset[o] = Uint8List.fromList(c),
      );
      onTotal?.call(total);
      final b = BytesBuilder(copy: false);
      for (final o in byOffset.keys.toList()..sort()) {
        b.add(byOffset[o]!);
      }
      return b.takeBytes();
    }

    for (final n in [32769, 94915, 1048589]) {
      test('size=$n through a 5,000-byte READ cap arrives byte-exact, chunk '
          'offsets contiguous', () async {
        final want = _formula(n);
        final server = serve(want, readCap: 5000);
        final session = DartSshSftpSession(server.client);
        int? total;
        expect(await reassemble(session, onTotal: (t) => total = t), want);
        expect(total, n);
        expect(server.cappedReads, greaterThan(0));
      });
    }

    test('stat says 94,915 but the stream ends at 62,147 → throws', () async {
      final server = serve(
        _formula(62147),
        readCap: 32 * 1024,
        statSize: 94915,
      );
      final session = DartSshSftpSession(server.client);
      await expectLater(
        session.download('/home/u/f.bin', onChunk: (_, _) {}),
        throwsA(isA<DownloadIncompleteException>()
            .having((e) => e.received, 'received', 62147)
            .having((e) => e.expected, 'expected', 94915)),
      );
    });
  });

  group('verifyDownloadComplete', () {
    test('equal counts pass; any difference throws with both numbers', () {
      verifyDownloadComplete(10, 10);
      expect(
        () => verifyDownloadComplete(9, 10),
        throwsA(isA<DownloadIncompleteException>().having(
            (e) => e.toString(), 'message', 'Download incomplete: got 9 of 10 bytes')),
      );
      expect(() => verifyDownloadComplete(11, 10),
          throwsA(isA<DownloadIncompleteException>()));
    });
  });
}
