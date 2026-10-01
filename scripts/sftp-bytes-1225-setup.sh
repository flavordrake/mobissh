#!/usr/bin/env bash
# scripts/sftp-bytes-1225-setup.sh — seed /home/testuser/bytes_1225/ on test-sshd
# with content the sftp_bytes_roundtrip_1225 emulator test knows INDEPENDENTLY
# (#1225: downloads over 32 KiB silently truncated).
#
#   bin/bin_<size>.bin  byte i = (i * 31 + i // 251) & 0xff, for the sizes below
#   md/doc.md           ~100 KB UTF-8 markdown, line k =
#                       "line %05d ascii café ✓ 日本語 🎉 the quick brown fox\n"
#                       after a "# bytes 1225\n\n" heading
#   up/                 empty; the test's uploads land here
#   up_hole.bin.part    65,536 formula bytes with 32,768..49,151 zeroed
#   up_hole2.bin.part   65,536 formula bytes with 16,384..32,767 zeroed
#                       (interrupted-upload leftovers the resume must not trust)
#
# The test recomputes the same formulas, so a download is compared against
# bytes that never went through the reader under test. Any previous run's
# leftovers are removed first. Honours SSHD_HOST (the runner pins it).
#
# It then switches that container's sftp subsystem to the READ-capping relay
# (docker/test-sshd/sftp-cap-proxy.py: every READ asks for at most 32 KiB, so
# the server replies short the way the owner's server did — stock
# internal-sftp never does, which is why #1225 hid from test-sshd), and
# self-checks it: the stock sftp client, which handles short reads, must fetch
# bin_94915.bin byte-exact THROUGH the relay while the relay reports capped
# READs. sftp-bytes-1225-teardown.sh switches back to internal-sftp.
#
# Runs as the test's declared Setup (scripts/lib/integration-fixtures.sh).
set -euo pipefail

MOBISSH_TMPDIR="${MOBISSH_TMPDIR:-/tmp/mobissh}"
WORK="${MOBISSH_TMPDIR}/sftp-bytes-1225"
rm -rf "$WORK"
mkdir -p "$WORK/stage/bin" "$WORK/stage/md" "$WORK/stage/up"
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
for n in (1, 32767, 32768, 32769, 65535, 65536, 65537, 94915, 1048589):
    data = bytes(((i * 31 + i // 251) & 0xff) for i in range(n))
    with open(os.path.join(root, "bin", "bin_%d.bin" % n), "wb") as f:
        f.write(data)
lines = ["# bytes 1225\n\n"]
for k in range(1650):
    lines.append("line %05d ascii café ✓ 日本語 🎉 the quick brown fox\n" % k)
with open(os.path.join(root, "md", "doc.md"), "wb") as f:
    f.write("".join(lines).encode("utf-8"))
# Interrupted-upload leftovers with a HOLE: dartssh2 writeBytes sends a 64 KiB
# chunk as four 16 KiB writes concurrently, so a cut connection can leave a
# 65,536-byte .part missing one of them. up_hole: the third write lost (the
# state named in #1225); up_hole2: the second write lost.
for name, lo in (("up_hole.bin.part", 32768), ("up_hole2.bin.part", 16384)):
    part = bytearray(((i * 31 + i // 251) & 0xff) for i in range(65536))
    part[lo:lo + 16384] = bytes(16384)
    with open(os.path.join(root, name), "wb") as f:
        f.write(part)
' "$WORK/stage"

echo "> local checksums"
(cd "$WORK/stage" && sha256sum bin/* md/* ./*.part)

echo "> seeding /home/testuser/bytes_1225 on ${HOST}"
tar -C "$WORK/stage" -cf - . | ssh -i "$KEY" -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null "testuser@${HOST}" '
rm -rf /home/testuser/bytes_1225
mkdir -p /home/testuser/bytes_1225
tar -C /home/testuser/bytes_1225 -xf -
cd /home/testuser/bytes_1225
echo "remote checksums:"
sha256sum bin/* md/* ./*.part
ls -la . bin md up
'
echo "+ bytes_1225 seeded on ${HOST}"

source "${REPO_ROOT}/scripts/lib/sftp-cap-proxy.sh"
CONTAINER="$(sftpcap_container)"
echo "> enabling the READ-capping sftp relay in ${CONTAINER}"
docker exec "$CONTAINER" test -x /usr/local/bin/sftp-cap-proxy.py
docker exec "$CONTAINER" test -x /usr/lib/ssh/sftp-server
docker exec "$CONTAINER" sh -c 'rm -rf /tmp/sftp-cap-proxy; mkdir -m 1777 /tmp/sftp-cap-proxy'
# A failed self-check must not leave the relay in place for later tests.
restore_on_fail() {
  [[ "${SELFCHECK_OK:-0}" == 1 ]] && return 0
  echo "! setup failed — restoring ${SFTPCAP_STOCK_SUBSYSTEM}" >&2
  sftpcap_set_subsystem "$CONTAINER" "$SFTPCAP_STOCK_SUBSYSTEM" || true
}
trap restore_on_fail EXIT
sftpcap_set_subsystem "$CONTAINER" "$SFTPCAP_PROXY_SUBSYSTEM"

echo "> self-check: stock sftp client (64 KiB requests) through the relay"
printf 'get %s %s\n' /home/testuser/bytes_1225/bin/bin_94915.bin "$WORK/selfcheck.bin" \
  > "$WORK/selfcheck.batch"
fetched=0
for attempt in 1 2 3 4 5; do
  # sshd re-execs on HUP; the first connect can race the listener coming back.
  if sftp -B 65536 -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -b "$WORK/selfcheck.batch" "testuser@${HOST}"; then
    fetched=1
    break
  fi
  echo "  sftp attempt ${attempt} failed; retrying"
  sleep 1
done
[[ "$fetched" == 1 ]] || { echo "! self-check: sftp through the relay never succeeded" >&2; exit 1; }
want="$(sha256sum "$WORK/stage/bin/bin_94915.bin" | awk '{print $1}')"
got="$(sha256sum "$WORK/selfcheck.bin" | awk '{print $1}')"
echo "  sha256 want=${want} got=${got}"
[[ "$want" == "$got" ]] || { echo "! self-check: relay is NOT transparent (sha256 mismatch)" >&2; exit 1; }
if ! sftpcap_report "$CONTAINER"; then
  echo "! self-check: the relay capped no READs — the cap is not engaged" >&2
  exit 1
fi
docker exec "$CONTAINER" sh -c 'rm -f /tmp/sftp-cap-proxy/*.log'
SELFCHECK_OK=1
echo "+ READ-capping relay engaged and transparent; counters reset for the test"
