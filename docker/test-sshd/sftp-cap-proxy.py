#!/usr/bin/env python3
"""READ-capping SFTP relay for the #1225 emulator test.

sshd runs this as the sftp subsystem ONLY while sftp_bytes_roundtrip_1225_test
runs (scripts/sftp-bytes-1225-setup.sh switches it in, the teardown switches
back to internal-sftp). It spawns the real sftp-server and relays packets both
ways byte-for-byte, except that every client->server SSH_FXP_READ has its
length rewritten to min(len, 32768). The server then answers a 64 KiB request
with 32 KiB, which is what the owner's server did and what the stock
internal-sftp never does. That short reply is the #1225 trigger.

Each session keeps one line in /tmp/sftp-cap-proxy/<pid>.log:
  pid=<pid> reads=<n> capped=<n>
so the setup self-check and the teardown can show that the cap engaged.
Stdlib only.
"""

import os
import struct
import subprocess
import sys
import threading

SERVER = "/usr/lib/ssh/sftp-server"
CAP = 32768
LOG = "/tmp/sftp-cap-proxy/%d.log" % os.getpid()
FXP_READ = 5

reads = 0
capped = 0


def record():
    # Rewritten on every READ, not only at exit: a session the app never closes
    # cleanly (a failed test, a killed app) must still show that the cap engaged.
    try:
        with open(LOG, "w") as f:
            f.write("pid=%d reads=%d capped=%d\n" % (os.getpid(), reads, capped))
    except OSError:
        pass


def read_exact(fd, n):
    buf = bytearray()
    while len(buf) < n:
        chunk = os.read(fd, n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return bytes(buf)


def write_all(fd, data):
    view = memoryview(data)
    while view:
        n = os.write(fd, view)
        view = view[n:]


def client_to_server(server_in):
    global reads, capped
    try:
        while True:
            head = read_exact(0, 4)
            if head is None:
                break
            (length,) = struct.unpack(">I", head)
            body = read_exact(0, length)
            if body is None:
                break
            if length >= 1 and body[0] == FXP_READ:
                # type, id, string handle, uint64 offset, uint32 len (last 4).
                (want,) = struct.unpack(">I", body[-4:])
                reads += 1
                if want > CAP:
                    capped += 1
                    body = body[:-4] + struct.pack(">I", CAP)
                record()
            write_all(server_in, head + body)
    except OSError:
        pass
    finally:
        try:
            os.close(server_in)
        except OSError:
            pass


def server_to_client(server_out):
    try:
        while True:
            chunk = os.read(server_out, 65536)
            if not chunk:
                break
            write_all(1, chunk)
    except OSError:
        pass


def main():
    proc = subprocess.Popen(
        [SERVER], stdin=subprocess.PIPE, stdout=subprocess.PIPE, bufsize=0
    )
    server_in = os.dup(proc.stdin.fileno())
    proc.stdin.close()
    up = threading.Thread(target=client_to_server, args=(server_in,), daemon=True)
    up.start()
    # The session ends when the server's output ends (it exits once its stdin
    # closes, i.e. once the client went away) or the server dies on its own.
    server_to_client(proc.stdout.fileno())
    proc.wait()
    record()
    sys.stdout.flush()
    os._exit(0)


if __name__ == "__main__":
    main()
