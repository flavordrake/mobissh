# Baseline run environment — #1101

| Field | Value |
|---|---|
| UTC start | 2026-09-20T15:52:54Z |
| Branch | `chore/integration-baseline` @ `origin/main` |
| Code | `e368d5d` — ship(native): 0.1.12-rc.4+189 |
| Suite | `scripts/native-integration-suite.sh` (auto-discovers `native/integration_test/*_test.dart`) |
| Discovered tests | **86** (issue #1101 was filed against 82) |
| Device | fleet emulator CT113 `android-emulator`, adb `android-emulator.tailbe5094.ts.net:5556` (`emulator-5554` guest) |
| Device geometry | `wm size` 1080x2400, `wm density` 420 → **411 x 914 logical dp**, Android **15** (API 35) |
| Lease | `scripts/with-fleet-emulator.sh`, `EMU_LEASE_MAXHOLD=14400`, granted 0s queued, booted in 54s |
| Logs | `/tmp/mobissh/logs/baseline-1101/{native-integration-suite,native-connect-test,fleet-emulator-lease}.log` |

## Fixture preparation (#1187) — done BEFORE the lease

This run deliberately did **not** use the default fixture wiring, because two
independent #1187 hazards would have poisoned the baseline:

1. **Stale bastion.** `mobissh-test-sshd:latest` = image `e4f62193b3ff`, whose
   `/etc/ssh/sshd_config:90` reads `AllowTcpForwarding no`. It predates #1047's
   `AllowTcpForwarding local`. The canonical long-lived container
   `mobissh-test-sshd-1` (up 6 weeks) runs that image, so any test opening a
   `direct-tcpip` channel dies with `SSHChannelOpenError(1) administratively
   prohibited` deep inside the test — reading exactly like a product bug.
2. **Ambiguous DNS identity.** Three containers currently answer to the
   `test-sshd` network alias, so Docker DNS round-robins and a test can silently
   land on a different (stale) sshd between runs — i.e. the previous baseline
   was not even reproducible.

Applied:

```
docker tag f3a1f51b48e7 agent-a2eb9df1d494b709b-test-sshd:latest
docker tag f3a1f51b48e7 agent-a2eb9df1d494b709b-jump-target:latest
scripts/test-sshd-up.sh
SSHD_HOST=agent-a2eb9df1d494b709b-test-sshd-1   # exported for the whole run
```

`f3a1f51b48e7` is the DERIVED current image left behind by the #1183 run — it
carries `AllowTcpForwarding local` and a `fake-tui` byte-identical (2526 bytes)
to the repo's `docker/test-sshd/fake-tui.sh`. The alpine CDN is unreachable from
inside the build container (#1187), so tagging is the only way to get a CURRENT
fixture on fd-dev today; `docker compose up` then reuses the tag instead of
building.

The `-jump-target-1` container was brought up in the same compose project so the
#1183 jump-host acceptance has its second hop.
