# Jump host (ProxyJump) — spec

Status: draft, 2026-09-18. Owner-requested. Umbrella issue: see `## Slices`.

## Goal

Connect to a target host *through* one or more intermediate SSH hosts, the way
OpenSSH's `ProxyJump` (`ssh -J`) does, and round-trip that relationship through
`~/.ssh/config` text.

## What the standard actually is

`ProxyJump` superseded `ProxyCommand ssh -W %h:%p`. It is a per-host directive
naming a comma-separated chain of hops:

```
Host prod
  HostName 10.0.0.5
  User deploy
  ProxyJump bastion            # alias of another Host stanza
  # or literal: ProxyJump jumpuser@bastion.example.com:2222,second-hop
```

Mechanically the client authenticates to the bastion, opens a `direct-tcpip`
channel to the target, and runs the *target's* SSH handshake inside that
channel. No local port is bound; the bastion never sees the target's session
key. Both hops are real SSH connections with their own host keys and their own
credentials.

## Why this is cheap here

- `dartssh2`'s `SSHForwardChannel implements SSHSocket`, so
  `SSHClient(await jump.forwardLocal(host, port), username: …)` IS the mechanism.
- `ssh_session.dart:126` already defines the seam it plugs into:
  `SshSocketOpener = Future<SSHSocket> Function(String host, int port, {Duration? timeout})`.
  A jump connection is an opener that dials the bastion first and returns the
  forwarded channel. The session state machine, reconnect policy, keepalive and
  SFTP paths do not change.

## Requirements

### Model

- **R1** A profile MAY reference exactly one other profile as its jump host.
  Reference by `identityKey` (`host:port:username`) in a new nullable field
  `jumpIdentityKey`; absent/unknown/corrupt → treated as "no jump host"
  (corrupt-resilience per `.claude/rules/code-style.md`, no key bump).
- **R2** The reference is a REFERENCE, never an embedded copy of the hop's
  connection details. An embedded copy goes stale the moment the bastion's port,
  user or key changes.
- **R3** Chains form by following R1 transitively. Depth is capped at 3 hops;
  a longer chain fails closed with a named error.
- **R4** A cycle (including self-reference) is rejected at SAVE time in the
  editor, not discovered at connect time.
- **R5** When a referenced profile's `identityKey` changes, every referrer is
  rebound in the same write (`upsert` already carries `previousIdentityKey`).
- **R6** Deleting a profile that others reference warns and names the referrers;
  confirming clears their `jumpIdentityKey` rather than leaving a dangling id.

### Connect

- **R7** Hops dial outermost-first: bastion, then the channel to the target.
  The target session's identity, telemetry and UI state remain the TARGET's —
  a jump is transport, not a separate session tab.
- **R8** Each hop authenticates with ITS OWN profile's stored credentials
  (`vaultId` / `keyVaultId`). No new secret storage, no credential reuse across
  hops, and a hop whose secret is missing fails closed with a named error.
- **R9** Host-key verification runs for EVERY hop against the existing
  `HostKeyStore`, keyed by that hop's host:port. A bastion with an unknown or
  CHANGED key gets the same prompt and the same fail-closed treatment as a
  target (#1108). Skipping this makes the bastion the weak link.
- **R10** The `awaitingHostKey` prompt NAMES which host it is asking about.
  Without it the user approves a fingerprint without knowing whose it is.
- **R11** Errors identify the failing hop ("bastion.example.com: auth failed"),
  never a bare message that reads as if the target refused.
- **R12** The jump client's lifecycle is owned by the target session: torn down
  on disconnect, re-dialled on reconnect. No leaked jump clients across a
  reconnect storm (assert this with a test, not by inspection).
- **R13** Reconnect re-dials the WHOLE chain. A half-open chain (bastion alive,
  target dead) must not present as connected.

### Editor

- **R14** The profile editor's Details tab gains a "Jump host" picker listing
  other saved profiles (plus "None"). Monochrome glyph, no emoji.
- **R15** The picker excludes the profile itself and any profile that would
  close a cycle (R4).
- **R16** A profile with a jump host shows it in the profile list row and in the
  session menu, so a chained connection is never invisible.

### Import (`~/.ssh/config`)

- **R17** The parser (`ssh_config_parser.dart`, which today ignores
  `ProxyJump`) parses `ProxyJump` into a list of hop specs, each either a bare
  alias or a literal `[user@]host[:port]`.
- **R18** On import, an alias hop resolves against existing profiles by alias /
  identity; an unresolved hop is offered as a profile to create first, and the
  link is written once it exists.
- **R19** `ProxyCommand ssh -W %h:%p <hop>` is recognised as the legacy spelling
  of the same thing and mapped to a hop. Any other `ProxyCommand` is ignored
  with a named, visible reason — silently dropping it would produce a profile
  that connects differently from the config it came from.
- **R20** Multi-hop `ProxyJump a,b` imports as a chain (R3 cap applies).

### Export (`~/.ssh/config`)

- **R21** A profile exports to a `Host` stanza: `Host <alias>`, `HostName`,
  `Port`, `User`, `ProxyJump <hop alias>` when set.
- **R22** Secrets are NEVER written. Key-based auth exports an `IdentityFile`
  hint only when the profile records a path-like hint; otherwise the directive
  is omitted and the export notes which profiles need a key configured manually.
- **R23** Export is a shareable text artifact: the UI hands it to the existing
  share/save path, and the preview states plainly that it contains no secrets.
- **R24** Round-trip: exporting profiles then importing the result yields the
  same set of profiles and the same jump links (test-asserted).

## Decisions

- **D1** Reference by `identityKey`, not `linkAlias`. `linkAlias` (#1140) is
  optional, so it cannot express a link for the majority of profiles that have
  none. Rejected alternative: minting a UUID per profile — that is a storage
  migration touching every consumer of `identityKey`, for no gain here.
- **D2** One `jumpIdentityKey` per profile rather than an inline chain list.
  Chains compose from single links (R3), which keeps the model, the editor and
  the ssh_config mapping one-to-one.
- **D3** Jump is transport, not a session. No second tab, no second entry in the
  session menu. Rejected: modelling the bastion as a child session — it would
  double every lifecycle path (keepalive, attention, reconnect) for no user
  benefit.
- **D4** Export is its own slice. It is the only part that must decide what to
  do about auth that cannot be expressed in config text (R22), and that question
  should not block the connect path.

## Slices

1. **Slice 1 — jump by profile reference + per-hop host key.** R1-R16.
   `device` (a real two-hop connection is the acceptance test).
2. **Slice 2 — `ProxyJump` import.** R17-R20. Depends on slice 1's model.
3. **Slice 3 — ssh_config export.** R21-R24. Depends on slice 1's model.

## Tests

- **A1** Unit: chain resolution — none / one hop / three hops / depth-4 rejected
  / cycle rejected / dangling reference treated as none.
- **A2** Unit: `SshSocketOpener` composition returns the forwarded channel and
  dials hops outermost-first (fake `SSHClient`, assert call order).
- **A3** Widget: editor picker excludes self + cycle-closing profiles; saving
  writes `jumpIdentityKey`; clearing writes null.
- **A4** Widget: renaming a referenced profile's host rebinds referrers (R5);
  deleting warns and clears (R6).
- **A5** Unit/widget: an unknown hop host key prompts, names the hop, and a
  rejection fails the whole connect closed; a CHANGED hop key fails closed
  without prompting (#1108 parity).
- **A6** Unit: hop failure surfaces an error naming the hop (R11); a missing hop
  secret fails closed (R8).
- **A7** Unit: disconnect tears down the jump client; reconnect re-dials the
  chain; no client leaks across 10 reconnects (R12, R13).
- **A8** Emulator (slice 1 acceptance): connect to `test-sshd` THROUGH a second
  sshd container, assert real shell bytes from the target and that the target's
  prompt — not the bastion's — is what the terminal shows.
- **A9** Unit (slice 2): `ProxyJump` alias / literal / multi-hop / legacy
  `ProxyCommand -W` parse; unknown `ProxyCommand` reports a reason.
- **A10** Unit (slice 3): stanza generation; no secret ever appears in output
  (assert over a profile WITH a stored password and key); R24 round-trip.
