#!/usr/bin/env bash
# scripts/editor-integrity-1227-setup.sh — seed /home/testuser/edit_1227/ on
# test-sshd with content the editor_integrity_1227 emulator test knows
# INDEPENDENTLY (#1227: the editor's load→save chain rewrote server bytes).
#
#   utf8.md    ~100 KB UTF-8 markdown: a BOM, CRLF line endings, 2/3/4-byte
#              characters in the heading, and a 4-byte emoji placed so it
#              STRADDLES byte offsets 32768 and 65536 (the chunk boundaries that
#              bit #1225). Recipe:
#                EF BB BF, "# edit 1227 café ✓ 日本語 🎉\r\n\r\n", then 43-byte
#                ASCII lines "line %05d the quick brown fox jumps over\r\n";
#                before each boundary B, pad with "x" to B-2, then "🎉\r\n";
#                then lines until >= 100000 bytes.
#   latin1.md  Latin-1 (NOT UTF-8) bytes: "# latin1 1227\r\n\r\n" + 40 ×
#              "café naïve résumé © 2026\r\n" encoded as ISO-8859-1.
#
# The test recomputes both recipes in Dart, so nothing is verified by comparing
# one transfer with another through the same reader. Any previous run's
# leftovers are removed first. Honours SSHD_HOST (the runner pins it).
#
# Runs as the test's declared Setup (scripts/lib/integration-fixtures.sh).
set -euo pipefail

MOBISSH_TMPDIR="${MOBISSH_TMPDIR:-/tmp/mobissh}"
WORK="${MOBISSH_TMPDIR}/editor-integrity-1227"
rm -rf "$WORK"
mkdir -p "$WORK/stage"
LOGFILE="${WORK}/setup.log"
exec > >(tee -a "$LOGFILE") 2>&1

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEY="${WORK}/testuser_key"
cp "${REPO_ROOT}/docker/test-sshd/testuser_id_ed25519" "$KEY"
chmod 600 "$KEY"
HOST="${SSHD_HOST:-test-sshd}"

echo "> generating fixtures in ${WORK}/stage ($(date +%Y%m%dT%H%M%S%z))"
python3 -c '
import sys, os
root = sys.argv[1]
out = bytearray(b"\xef\xbb\xbf")
out += "# edit 1227 café ✓ 日本語 🎉\r\n\r\n".encode("utf-8")
k = 0
def line(k):
    return ("line %05d the quick brown fox jumps over\r\n" % k).encode("ascii")
assert len(line(0)) == 43
for B in (32768, 65536):
    while len(out) + 43 <= B - 2:
        out += line(k); k += 1
    out += b"x" * (B - 2 - len(out)) + "🎉\r\n".encode("utf-8")
    assert out[B - 2:B + 2].decode("utf-8") == "🎉", "emoji must straddle %d" % B
while len(out) < 100000:
    out += line(k); k += 1
with open(os.path.join(root, "utf8.md"), "wb") as f:
    f.write(out)
lat = ("# latin1 1227\r\n\r\n" + "caf\xe9 na\xefve r\xe9sum\xe9 \xa9 2026\r\n" * 40).encode("latin-1")
with open(os.path.join(root, "latin1.md"), "wb") as f:
    f.write(lat)
print("utf8.md bytes=%d latin1.md bytes=%d" % (len(out), len(lat)))
' "$WORK/stage"

echo "> local checksums"
(cd "$WORK/stage" && sha256sum ./*)

echo "> seeding /home/testuser/edit_1227 on ${HOST}"
tar -C "$WORK/stage" -cf - . | ssh -i "$KEY" -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null "testuser@${HOST}" '
rm -rf /home/testuser/edit_1227
mkdir -p /home/testuser/edit_1227
tar -C /home/testuser/edit_1227 -xf -
cd /home/testuser/edit_1227
echo "remote checksums:"
sha256sum ./*
ls -la .
'
echo "+ edit_1227 seeded on ${HOST}"
