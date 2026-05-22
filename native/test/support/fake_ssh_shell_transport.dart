// Test fake for [SshShellTransport].
//
// Captures bytes the production code writes to the remote stdin, plus PTY
// resize calls. Lets the widget tests assert the keystroke pipe + resize
// wiring without spinning up a real SSH session.

import 'dart:async';
import 'dart:typed_data';

import 'package:mobissh/ssh/ssh_shell.dart';

class FakeSshShellResize {
  final int cols;
  final int rows;
  final int pixelWidth;
  final int pixelHeight;

  const FakeSshShellResize(
    this.cols,
    this.rows, {
    this.pixelWidth = 0,
    this.pixelHeight = 0,
  });

  @override
  String toString() =>
      'FakeSshShellResize($cols x $rows; px ${pixelWidth}x$pixelHeight)';
}

class FakeSshShellTransport implements SshShellTransport {
  final StreamController<Uint8List> _outputCtrl =
      StreamController<Uint8List>.broadcast();
  final Completer<void> _done = Completer<void>();

  /// All bytes the production code sent toward the remote stdin, flattened
  /// into a single buffer so tests can assert exact byte sequences.
  final BytesBuilder stdinBytes = BytesBuilder(copy: false);

  /// Each [resize] call captured in order.
  final List<FakeSshShellResize> resizes = [];

  bool closed = false;

  @override
  Stream<Uint8List> get output => _outputCtrl.stream;

  /// Push bytes from the "remote" side so tests can verify they reach
  /// `Terminal.write(...)` via the shell.
  void emit(List<int> bytes) {
    _outputCtrl.add(Uint8List.fromList(bytes));
  }

  @override
  void send(Uint8List bytes) {
    stdinBytes.add(bytes);
  }

  @override
  void resize(int cols, int rows, {int pixelWidth = 0, int pixelHeight = 0}) {
    resizes.add(FakeSshShellResize(
      cols,
      rows,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
    ));
  }

  @override
  Future<void> get done => _done.future;

  @override
  void close() {
    if (closed) return;
    closed = true;
    if (!_done.isCompleted) _done.complete();
    if (!_outputCtrl.isClosed) _outputCtrl.close();
  }
}
