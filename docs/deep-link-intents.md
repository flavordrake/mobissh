# Deep-link intents: `mobissh://` requirements

Issue #1117. Supersedes the assessment captured in that issue on 2026-08-21; the confirmed scope there still holds and is restated here so this document is the single reference. Requirements are numbered `R<n>` so tests, issues and PRs can cite them.

## 1. Purpose

Another app on the same phone (first caller: opsurface, the effort board) fires a `mobissh://` link and mobissh switches to the foreground with the right session connected, or focused if it already is. The caller never learns a credential and never hands one over. The user gets one tap from "this effort" to "its terminal".

Callers today: opsurface cards (`tmux_over_ssh` surface, `packages/opsurface_core/lib/src/deep_link.dart` there), a hub-room message, a notification, a QR code, a web page. The last two are why the trust model below is destination-based.

## 2. Scope

In v1:
- `connect` to an existing profile, idempotent, with destination pre-authorization.
- `create` a new profile via the pre-filled form, always confirmed.
- Android and macOS custom-scheme registration; cold start and warm delivery.

In v1.1, each behind an explicit owner go:
- `tmux=<name>` attach-or-create on top of `connect`.
- `claude=<id>` resume a Claude Code session on top of `connect`.

Out of scope, permanently or until its own document:
- `ssh://` (other terminals claim it and its `user:pass@host` form carries credentials).
- Any credential, key, passphrase or token in a link.
- A free-text command parameter. Every command mobissh runs from a link is a locked template with an allowlisted argument.
- Remote path / file navigation (`fd`), which touches the hardened viewer surface and needs its own security pass.
- App Links / Universal Links (verified https). Anti-squatting upgrade later; macOS Universal Links need a signed app.

## 3. Grammar

Verb first, everything in the query, strict decoding.

```
mobissh://connect?host=<fqdn>[&port=<n>][&user=<u>]
mobissh://connect?name=<alias>
mobissh://create?host=<fqdn>[&port=<n>][&user=<u>][&name=<label>]
```

v1.1 extensions on `connect` only, mutually exclusive:

```
&tmux=<name>
&claude=<id>
```

- R1 Scheme is exactly `mobissh`; the authority is the verb; unknown verbs are rejected with the generic error (§8).
- R2 Parameters are percent-decoded once. A value with leading or trailing whitespace, a control character, or a second occurrence of the same key is a malformed link, not a normalized one.
- R3 `host` is a hostname or IP literal (RFC 1123 labels, or bracketed IPv6). No userinfo, no path, no port inside `host`. Lower-cased for matching.
- R4 `port` is 1–65535, default 22. `user` is `^[A-Za-z0-9._-]{1,64}$`.
- R5 `name` on `connect` is a per-profile link alias (§4), `^[A-Za-z0-9_-]{1,32}$`. It is a new profile field, never the display title.
- R6 `tmux` is `^[A-Za-z0-9_][A-Za-z0-9_-]{0,31}$` (no leading hyphen: the token is always the argument of `-s`, but a leading `-` would complicate every probe and future target command for no benefit — codex review 2026-09-12). `claude` is a UUID, `^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`.
- R7 Unknown parameters are ignored so the grammar can grow; a known parameter that fails its rule rejects the whole link. A parameter that names an action mobissh does not implement yet (`claude=` until R24 ships) rejects the whole link rather than degrading into a plain `connect` — a caller asking for a command must never silently get less than it asked for.

## 4. Profile matching

- R8 `connect` binds a stored credential only through an exact profile identity: `host:port:username` (`SavedProfile.identityKey`, `native/lib/storage/profiles_store.dart`). No title match, no prefix match, no "closest host". This is #1106's rule applied to inbound links: a link naming a host the user never saved matches nothing and touches no vault entry. Matching is field-wise (host through one canonical lower-casing function applied to both the stored and the link value, port as an int, username byte-exact); the concatenated `identityKey` string is never parsed or partially compared. The connection itself always uses the selected profile's stored fields, never the link's.
- R9 A link without `user` matches on `host:port`. Exactly one profile: proceed. More than one: show a picker listing those profiles, nothing else. Zero: fall through to `create` behaviour with the form pre-filled (R14), never to a vault lookup.
- R10 `connect?name=<alias>` resolves through the alias field only. Aliases are unique across profiles (the editor refuses a duplicate; an import drops a colliding alias). If the store nevertheless holds the same alias twice (corrupt or hand-edited data), the link is rejected as ambiguous — it never resolves to the first hit. An unknown alias is the generic error.
- R11 `create` never resolves or binds an existing vault entry, even if a profile with the same identity exists; in that case it shows the existing profile's connect confirmation instead of a duplicate form.

## 5. Trust model: destination, not source

The referrer of a `VIEW` intent (`Activity.getReferrer()`, `EXTRA_REFERRER`) is caller-supplied and spoofable on Android; iOS and macOS are no better. A "don't ask again for links from opsurface" option would therefore be a boundary any app can walk through. The link carries no credential and `connect` is idempotent, so the worst an untrusted caller can do to a pre-authorized destination is bring one of the user's own trusted hosts to the foreground. That is acceptable; a free command would not be, which is why §7 locks templates.

- R12 First `connect` to a given profile from a link shows a confirmation naming the profile (title, host, user) with two actions: `Connect once` and `Always allow links to open <title>`. The choice is stored per profile (`linkAutoConnect`, default false).
- R13 With `linkAutoConnect` set, `connect` proceeds with no prompt. The setting is visible and revocable in the profile editor and is not included in backups by default (same posture as `initialCommand` import, `native/lib/storage/backup_restore.dart`). The flag is destination trust, so it is bound to the identity it was granted for: it resets to false whenever host, port or username is edited; a plain (metadata) profile import never sets it; an encrypted backup restores it only through the existing explicit "also restore auto-run" opt-in. A trust bit that travelled with a JSON file would be #1106's portable-handle mistake again.
- R13a Auto-connect supplies only authentication material already stored for that profile (password, key, stored passphrase). It never accepts a host key, answers a keyboard-interactive challenge, or dismisses any lower-layer prompt; when the stored material is incomplete the link falls back to the confirmation path, it does not fail silently.
- R14 `create`, an unmatched host, and a picker result (R9) always confirm. `create` never auto-connects.
- R15 The host-key policy is unchanged: an unknown host key blocks on the existing TOFU dialog; a mismatch fails closed. A link never pre-trusts a key, and `linkAutoConnect` does not skip the dialog. Today the TOFU listener lives in `ConnectForm`'s State (`native/lib/ui/connect_form.dart`), which is unmounted while a terminal is showing; a link connect must guarantee the prompt is reachable from wherever it starts (a warm link with another session live is the case A9 must cover), or a session for an unknown host would sit at `awaitingHostKey` forever.
- R16 The v1.1 verbs require `linkAutoConnect` OR the per-link confirmation, and the confirmation names the command that will run (`tmux new-session -A -s foo`).

Owner decision recorded 2026-08-21 as pending: destination-based trust as above versus a caller capability token. This document assumes destination-based; a token scheme would need key management in every caller and is not pursued.

## 6. Session behaviour

- R17 `connect` is idempotent. A live session for the matched profile is focused (`setActive`), no second connection is opened. A session for that profile that is disconnected or in an error state is reconnected through the existing headless path (`_reconnectHostFromProfile`, `native/lib/state/attention_providers.dart`), which already loads vault credentials with no prompt. That helper takes a bare host and picks the first profile with that host (port and username ignored), so it is not called as-is: it is split so the link path hands in the exact `SavedProfile` matched under R8, and credential load, session lookup and focus all run against that one profile. Before focusing, the router asserts the session's profile key equals the authorised identity.
- R18 mobissh always comes to the foreground on a link, including from a cold start before the first frame is drawn; the pending link survives process death the same way a pending attention focus does (`AttentionFocusRouter`, `native/lib/services/attention_focus_router.dart`).
- R19 A link received while mobissh is already in the foreground is handled the same way as one that launches it (`onNewIntent` path; `MainActivity` is `singleTop`).
- R20 Back from the terminal returns to the caller through the normal Android task stack. No return URI in v1; whether `taskAffinity=""` puts the terminal in mobissh's own task and breaks that expectation is verified on hardware before v1 ships, and a `return=<uri>` parameter is added only if it does.
- R21 The result of a link is reported on the terminal screen, not in a toast the user can miss: connected, focused, or which error (§8).

## 7. v1.1 verbs: locked templates

- R22 `tmux=<name>` sends, on shell-ready, exactly `tmux new-session -A -s <name>` with `<name>` already validated by R6. The string is composed from a constant template and the validated token; the raw link value is never interpolated into a shell line.
- R23 If the matched session is already live, the command is still sent (a `sendNow` path beside `InitialCommandRunner.arm`, which today returns early on a live session). If the live session's foreground process is already the tmux client attached to `<name>`, nothing is sent. Detection is by the session's tmux control-mode state where available, otherwise by a shell-ready probe; a false negative sends a harmless `tmux new-session -A`, which attaches.
- R24 `claude=<id>` sends exactly `claude --resume <id>` under the same rules. It is reserved in the grammar for v1 and implemented only after the tmux verb ships and the owner gives a separate go.
- R25 A verb never combines with a profile `initialCommand`: when a link carries a verb, the profile's own initial command is not run for that connect. One command per link, and the user saw which. `InitialCommandRunner` keeps a shell-ready arm alive until it fires, so a connect that never reached shell-ready leaves a stale profile-command arm behind; arming a verb first cancels every outstanding arm for that session (a `cancel(sessionId)` beside `arm`), otherwise a reconnect could run both.

## 8. Errors

- R26 Every rejection shows one neutral message, `Link not recognized`, on mobissh's home screen, and logs the structured reason locally (malformed, unknown verb, no profile, ambiguous, host-key blocked). No result and no profile-existence signal is ever returned to the caller. The person holding the phone does learn whether a host is saved (a saved host confirms, an unsaved one opens the create form, R9/R14) — that is the device owner looking at their own profile list, not an oracle for the caller, and the confirmation after a picker still names host, port and user so nothing connects by confusion.
- R27 A rejected link may do exactly three things: bring mobissh to the foreground, consume its own pending-link record, and append a redacted local diagnostic line. Nothing else — no `ProfilesStore.upsert`, no `SecretsStore.write`, no key import or library adoption, no `HostKeyStore.trust`/`forget`, no session creation or activation, no network connect, no PTY input, no port forward, no recents entry, no command arm, no `linkAutoConnect` change, no telemetry upload. Opening the create editor (an accepted `create`, not a rejection) may adopt keys on init and, on Save, upsert a profile and write credentials, because both follow an explicit user action.

## 9. Platform mechanics

- R28 Android: `intent-filter` with `VIEW`, `DEFAULT`, `BROWSABLE` and `<data android:scheme="mobissh"/>` on `.MainActivity` (`native/android/app/src/main/AndroidManifest.xml`). Delivery through the `app_links` package (cold + warm) or a `mobissh/links` MethodChannel from `onNewIntent`/`getIntent`; the package is preferred unless it drags a dependency the gate rejects.
- R29 macOS: `CFBundleURLTypes` for `mobissh` in `Info.plist`; works unsigned. iOS: same key, lands when the signing gate lifts.
- R30 Callers on Android 11+ must declare package visibility for the scheme; the caller contract (§11) says so. mobissh itself needs no `<queries>` change.

## 10. Data model changes

- `SavedProfile.linkAlias: String?` (R5, R10), unique, validated on save, absent on old profiles (no key bump, `_coerce*` migration style).
- `SavedProfile.linkAutoConnect: bool` (R12), default false, excluded from backup export unless the user opts in.
- Both edited in the profile editor under a `Links` section, with the profile's own `mobissh://connect?name=<alias>` shown as copyable text so the user can paste it into opsurface or anywhere else.

## 11. Caller contract

Published with the feature so opsurface and others build to the same rules:

- Fire `mobissh://connect?host=<fqdn>&user=<u>` with `LaunchMode.externalApplication`; declare `<queries><intent><action android:name="android.intent.action.VIEW"/><data android:scheme="mobissh"/></intent></queries>` or the launch throws on Android 11+.
- Expect no result. Expect the first tap per profile to confirm. A `connect` naming a host the user has not saved opens mobissh's create form pre-filled from the link (R9/R14) — the user still confirms; nothing connects on its own. A `connect?name=` with an unknown alias shows `Link not recognized`; fall back to the host form in that case.
- `tmux=` names match `^[A-Za-z0-9_][A-Za-z0-9_-]{0,31}$` (no leading hyphen). `claude=` is reserved and rejects the whole link until it ships.
- Do not put a command, a path or a credential in the link; it is rejected.

## 12. Acceptance

Unit (`native/test/services/connect_intent_test.dart`, no Flutter imports):
- A1 Each grammar row in §3 parses to the expected `ConnectRequest`; each R2–R7 violation rejects with its reason; a duplicated key rejects; a value with a trailing space rejects.
- A2 `ssh://`, `mobissh://open`, `mobissh://connect?host=user:pw@h` reject.
- A3 R8–R11 matching against a fixture profile list: exact match, host-only single, host-only ambiguous, alias hit, alias miss, unknown host → create.

Widget / state (`native/test/state/`):
- A4 First-time connect shows the R12 confirmation; `Always allow` persists `linkAutoConnect`; the next link skips the prompt; revoking in the editor restores it.
- A5 `create` shows the form pre-filled and never calls `addOrActivate` without the user pressing connect.
- A6 A rejected link writes nothing to profiles, secrets or host keys (stores asserted byte-identical).

Integration (`native/integration_test/deep_link_1117_test.dart`, emulator, `adb shell am start -a android.intent.action.VIEW -d '<link>'`):
- A7 Cold start with a link to a saved, auto-allowed profile lands on a connected terminal with no prompt.
- A8 Warm delivery while another session is active focuses the matched session; the session count does not grow.
- A9 A link to a host with an unknown key stops at the TOFU dialog.
- A10 Back from the linked terminal returns to the launching activity (a stub caller app or `am start` from the launcher) — the R20 check.
- A11 v1.1: `tmux=<name>` on a fresh session results in a tmux client attached to `<name>` (asserted through `tmux display-message -p '#S'` over the same session); the same link again sends nothing.

## 13. Phasing

1. Owner confirms §5 (destination trust) and §3 (grammar). Codex review of §4–§7 against #1106. Done 2026-09-12: owner took the three §14 items as recommended; codex returned BLOCK with 11 findings, 9 folded into R6, R7, R8, R10, R13, R13a, R15, R17, R25, R26, R27 and §11 above, one (R23 sendNow into a live PTY) held for the owner, one (credential handles survive an identity edit in the profile editor, pre-existing and not reachable from a link) filed as #1138. Review text is a comment on #1117.
2. v1: R1–R21, R26–R30, data model §10, tests A1–A10. Sliced into PRs A (parser + matcher), B (data model + editor + backup), C (delivery + routing), D (integration tests), each a child issue of #1117, device-labeled.
3. Publish §11 to opsurface (its `<queries>` entry and DeepLink params are an opsurface issue).
4. v1.1 tmux verb (R22, R23, R25, A11) — owner go given 2026-09-12, PR E. `claude` verb (R24) after that, separately.

## 14. Open decisions

- Destination trust (§5) versus a caller capability token. Decided 2026-09-12: destination.
- Whether R9's host-only match is allowed at all or `user` is mandatory. Decided 2026-09-12: allowed, picker on ambiguity.
- Whether `linkAutoConnect` travels in encrypted backups. Decided 2026-09-12: not by default, same as `initialCommand`.
- R23 on a LIVE session (codex finding 7): `sendInput` is indistinguishable from typing, and shell-ready only proves a shell existed once — the bytes could land in an editor, a password prompt, a nested ssh. Options: (a) keep R23 as written; (b) on a live session always show an in-terminal confirmation naming the command, regardless of `linkAutoConnect`, and send only on that tap (fresh connects still arm on shell-ready with no prompt); (c) send unprompted only when tmux control mode confirms the foreground is a shell, else (b). Recommendation: (b) for v1.1 — one tap, no probe race, no new channel; (c) once control mode is on by default.
