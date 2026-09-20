# #589 integration suite — baseline + cause triage (#1101)

**Run:** 2026-09-20T15:52Z–17:40Z, clean `origin/main` @ `e368d5d` (0.1.12-rc.4+189)
**Device:** fleet emulator CT113 `android-emulator` — 1080x2400 @ 420dpi (411 x 914 dp), Android 15
**Suite:** `scripts/native-integration-suite.sh` — **86** discovered tests (#1101 was written against 82)
**Result: 67 passed / 19 failed / 0 not run.**
Environment + fixture preparation: `environment.md` beside this file.
Per-test evidence logs: `/tmp/mobissh/logs/baseline-1101/per-test/`.

> **Headline.** The red baseline is not one problem. It is **seven named causes**, and
> only three of them are about the product. Four are the suite's own wiring: a fixture
> image that predates the feature it serves, an ambiguous Docker DNS identity, a
> hand-maintained bridge list that has drifted from the tests that declare their own
> requirements, and a `find`-based discovery loop that runs a desktop-only test plus six
> tests whose setup scripts it never calls. Neutralising the fixture hazards alone moved
> `port_forward_1047` and `sftp_browse_smoke` from FAIL to PASS before a line of test code
> was touched; supplying one missing bridge port moved `reconnect_da_writeback_leak_1072`
> from FAIL to PASS in the same session.

---

## 1. Read this before comparing against #1101's roster

Two fixture hazards from #1187 were neutralised BEFORE the lease was taken, because
either one silently changes *which sshd* a test talks to, and therefore what the roster
means:

1. **Stale bastion.** Cached `mobissh-test-sshd:latest` (image `e4f62193b3ff`) has
   `AllowTcpForwarding no` at `/etc/ssh/sshd_config:90` — it predates #1047. The
   canonical `mobissh-test-sshd-1` container, **up 6 weeks**, runs it. Anything opening a
   `direct-tcpip` channel dies `SSHChannelOpenError(1) administratively prohibited`, deep
   inside a test, reading exactly like a product bug.
2. **Ambiguous identity.** Three containers currently answer to the `test-sshd` network
   alias. Docker DNS round-robins, so which fixture a run reaches is not determined by
   anything the run controls — the previous baseline was not reproducible.

Applied for the whole run:

```
docker tag f3a1f51b48e7 agent-a2eb9df1d494b709b-test-sshd:latest     # AllowTcpForwarding local
docker tag f3a1f51b48e7 agent-a2eb9df1d494b709b-jump-target:latest
scripts/test-sshd-up.sh
SSHD_HOST=agent-a2eb9df1d494b709b-test-sshd-1
```

**This change alone moved `port_forward_1047` and `sftp_browse_smoke` from FAIL (#1101)
to PASS.** Call this **G0 — FIXTURE (HARNESS)**.

Four of #1101's 22 are green here, and each has its own reason — none is "it just
passed this time":

| Recovered | Why |
|---|---|
| `port_forward_1047` | G0 — the pinned fixture has `AllowTcpForwarding local` |
| `sftp_browse_smoke` | G0 — a CURRENT, unambiguous fixture |
| `attention_host_suppression` | G3's `needs_second_bridge()` entry, added earlier today |
| `keyboard_resize_sizing_922` | **undetermined.** Nothing in this run explains it. Its own header warns the assertion only holds "as long as the emulator keyboard changes the viewInsets"; this device does animate an inset (`ghostty-kbgrid` drops `box=762` → `box=450`), so it passed. Treat it as device-variance-sensitive, not reliably fixed |

Any comparison with #1101's roster that does not account for G0 is comparing two
different systems under test.

## 2. Run shape — three leases

| Phase | Tests | Outcome |
|---|---|---|
| 1 | first 60 in `find … \| sort` order (`active_session_reconnect` → `reconnect_cycle`) | 46 passed / 14 failed |
| 2 | remaining 26 (`reconnect_da_writeback_leak_1072` → `wrap_join_copy`), same wiring via `scripts/integration-subset.sh` | 21 passed / 5 failed |
| 3 | discriminator: the two `reconnect_*` tests re-run with `BRIDGE_PORT2=2223` | see G3 |

Phase 1 did not stop because the suite failed: the agent harness killed the background
task at ~16:57Z, taking the lease-holding ssh with it. Phase 2 re-ran the untouched
remainder under a fresh lease with identical wiring (`SSHD_HOST` pinned, shared
`MOBISSH_LOGDIR`); `integration-subset.sh`'s `needs_second_bridge()` /
`needs_jump_target()` mirror the suite's, so phase 2 is suite-equivalent. Every one of
the 86 ran.

---

## 3. Failure table (19)

| Test | Verbatim failure | Group |
|---|---|---|
| `attention_notification_post` | `suppressed (reconnect-replay 1297ms < 1500ms)` … `no attention-notification post was logged for the session after an OSC 9` (:128) | G7 (#1188) |
| `cc_attach_existing` | `control mode did not attach the PRE-EXISTING 'main' session … Saw:` (:151) | G1 |
| `cc_capture_attach` | `the attached pane did NOT render via capture-pane … Ensure scripts/cc-capture-setup.sh ran. Saw: …1c28f38ea1e5:~$` (:114) | G1 |
| `cc_capture_scroll` | `the live tail (LINE_200) did not render on attach. Ensure scripts/cc-scroll-setup.sh ran.` (:116) | G1 |
| `cc_exec_switch` | `the pre-existing ACTIVE window never rendered — attach capture failed.` (:119) | G1 |
| `cc_nested_exec` | `the pre-existing NESTED session never rendered — '-CC attach' did not attach + capture the existing session` (:126) | G1 |
| `cc_nested_fallback` | `control mode ON in a NESTED tmux BRICKED the connection — the marker never rendered` (:127) | G1 |
| `desktop_smoke` | `never reached the terminal screen` (:95) | G2 |
| `reconnect_da_writeback_leak_1072` | `session B never reached the terminal` (:109) | G3 |
| `reconnect_mouse_mode_1014` | `session B never reached the terminal` (:106) | G3 |
| `detection_lab_1031` | `Expected: not null Actual: <null>` — `no styled wash range for the URL` (:223) | G4 |
| `detection_lab_custom_1031` | `custom span anchors must bake the capsule wash` (:199) | G4 |
| `url_bubble_wrap_988` | `Expected: <4> Actual: <0>` — `every wrapped row must carry a styled wash range` (:164) | G4 |
| `import_upsert_diversity` | `KEY field not shown — editor opened in password mode (stale authType not refreshed on upsert — the #547 follow-up bug, #595)` (:278) | G5 |
| `mermaid_markdown_render` | `markdown seed never completed on test-sshd` (:95, `_seedMarkdown`) | G6 |
| `profile_color_picker_1030` | `picker sheet never opened` (:103) | G6b |
| `wrap_join_copy` | `the soft-wrapped line was not joined into one logical line — a '\n' (or truncation) sits inside the marker. copied="BBBBBBBBBBBBBBBBBBBBBBBB_END\n1c28f38ea1e5:~$…"` (:155) | G6b |
| `sftp_favorites` | `#948: second open (cwd IS the favorite) showed favorites-empty` (:226) | G7 (#948) |
| `golden_flow_tui` | `GOLDEN copied="null"` … `gutter copy wrote nothing` (:284) | G7 (new) |

---

## 4. Cause groups

### G1 — six `cc_*` tests need a setup script the suite never runs (6) — **HARNESS**

The suite discovers tests with `find … -name '*_test.dart'`. Six control-mode tests
declare, in their own headers, an out-of-band prerequisite the runner knows nothing about:

| Test | Declared prerequisite |
|---|---|
| `cc_attach_existing` | `scripts/cc-attach-setup.sh` |
| `cc_capture_attach` | `scripts/cc-capture-setup.sh` |
| `cc_capture_scroll` | `scripts/cc-scroll-setup.sh` |
| `cc_exec_switch` | `scripts/cc-exec-switch-setup.sh` |
| `cc_nested_exec` | `scripts/cc-nested-setup.sh` (+ `cc-nested-teardown.sh`) |
| `cc_nested_fallback` | `scripts/cc-nested-setup.sh` (+ `cc-nested-teardown.sh`) |

The match is exact: the four `cc_*` tests with **no** prerequisite —
`cc_churn_bounded`, `cc_gestures`, `cc_render`, `cc_setting` — all PASSED. In every
failure the "Saw:" payload is a bare shell prompt: there is no tmux session to attach to
because nothing created one.

**This is NOT the "stale test for a default-off feature" hypothesis in #1101.** These
tests force control mode ON via `setTmuxControlModeForTest`, so the shipped default is
irrelevant to them. They are unrunnable-as-discovered, not stale, and tagging/skipping
them would throw away real coverage of a feature that still works when set up
(`cc_render`, `cc_gestures`, `cc_churn_bounded`, `cc_setting` prove the path is alive).

**To join the expected-pass set:** the runner must bracket these six with setup **and**
teardown — the `needs_jump_target()` hook added for #1183 is the precedent for the
shape. Teardown is not optional: `cc-nested-setup.sh` installs a `~/.bash_profile` that
`exec tmux attach -t main` on every interactive login, which would break every later test
in the suite. A naive "just call the setup script" fix is therefore actively dangerous.
Also note the setup scripts hard-code `testuser@test-sshd` and ignore `SSHD_HOST`, so
they inherit the G0 round-robin hazard and must be fixed in the same change.

### G2 — `desktop_smoke` is a Linux-desktop test the Android runner scoops up (1) — **HARNESS**

`integration_test/desktop_smoke_test.dart` has its own runner,
`scripts/desktop-smoke.sh` (`flutter test … -d linux` under Xvfb). Its header is
explicit: *"Runs ON THE HOST, no emulator/adb… The host process reaches test-sshd
DIRECTLY over the docker network (test-sshd:22) — no socat bridge, no adb reverse."* It
defaults to `SMOKE_HOST=test-sshd`, a Docker DNS name the Android guest cannot resolve,
and it deliberately skips `FlutterForegroundTask.initCommunicationPort()`. The suite runs
it on the device anyway.

**To join the expected-pass set:** it cannot — not on this device. Exclude it from the
Android suite (tag or explicit skip list) and let `scripts/desktop-smoke.sh` gate it. The
discovery loop's "no hand-maintained list to drift" rationale is right about *additions*
and wrong about *platform*.

### G3 — `needs_second_bridge()` has drifted from the tests that declare the requirement (2) — **HARNESS** (proved red→green)

Six integration tests open a second session on `127.0.0.1:2223`. `needs_second_bridge()`
— duplicated in `native-integration-suite.sh` and `integration-subset.sh` — lists three:

| Test | declares 2223 | in `needs_second_bridge()` |
|---|---|---|
| `multi_session_lifecycle` | yes | yes |
| `sftp_browse_smoke` | yes | yes |
| `attention_host_suppression` | yes | yes (added earlier today) |
| `reconnect_mouse_mode_1014` | header: *"Bridge: BRIDGE_PORT2=2223 scripts/native-connect-test.sh …"*, `port: '2223'` | **NO** |
| `reconnect_da_writeback_leak_1072` | header: *"Bridge: BRIDGE_PORT2=2223 …"*, `port: '2223'` | **NO** |
| `service_outlives_ui_reconnect` | `port: 2223` in code, no header note | **NO** (passes anyway — it never asserts B reaches a terminal) |

Both missing tests failed with the exact symptom `needs_second_bridge()`'s own comment
predicts — *"the 2nd session has nowhere to connect and the test fails for a HARNESS
reason that looks exactly like a product regression"*:

```
reconnect_da_writeback_leak_1072 : "session B never reached the terminal"   (:109)
reconnect_mouse_mode_1014        : "session B never reached the terminal"   (:106)
```

**Proof (phase 3, same device, same fixture, only `BRIDGE_PORT2=2223` added):**

```
phase 2 (suite wiring)  : FAIL integration_test/reconnect_da_writeback_leak_1072_test.dart
phase 3 (with 2223)     : PASS integration_test/reconnect_da_writeback_leak_1072_test.dart
phase 2 (suite wiring)  : FAIL integration_test/reconnect_mouse_mode_1014_test.dart
phase 3 (with 2223)     : PASS integration_test/reconnect_mouse_mode_1014_test.dart
```

`attention_host_suppression` — the entry added earlier today — PASSED in this run, which
is the control.

**To join the expected-pass set:** add the two missing entries (in **both** copies). The
durable fix is to stop hand-maintaining the predicate: derive it from the test sources
(they already declare `2223` in a greppable form), or simply arm the second bridge
unconditionally — it is one `socat` and one `adb reverse`, with no cost when unused. Two
hand-maintained copies of the same predicate is drift waiting to happen; today it had
already happened twice.

### G4 — three tests assert a wash that #1074 deliberately removed (3) — **STALE-TEST**

```
detection_lab_1031       : Expected: not null  Actual: <null>  "no styled wash range for the URL"
detection_lab_custom_1031: Expected: true  Actual: <false>  "custom span anchors must bake the capsule wash"
url_bubble_wrap_988      : Expected: <4>  Actual: <0>  "every wrapped row must carry a styled wash range"
```

All three assert that `controller.highlights` carries ranges with a non-null
`background` — the fork's *baked* styled-highlight output. The product stopped producing
that on purpose at +146 (#1074, the wash-underlay keystone).
`native/lib/ui/ghostty_terminal_view.dart:2895`:

```
// #1074: the detection WASH is a LIVE widget LAYER ([GhosttyWashLayer])
// painted UNDER the transparent terminal — NOT the fork's highlight pass.
// So the app installs NO `detectionHighlightStyleOf` resolver: the fork's
// HighlightPainter draws nothing for detection (registration is colourless
// below), and the wash tracks live off the controller's anchor set every
// build instead of only when the render box repaints …
```

With no `detectionHighlightStyleOf` resolver installed, `_styledHighlights()` in
`native/third_party/flterm/lib/src/widgets/terminal_controller_impl.dart:386` returns the
unstyled ranges, so `background` is null **by construction**. These tests pin the
pre-#1074 design, and their own error text ("must bake the capsule wash") names the
mechanism the keystone removed.

Corroboration that the *behaviour* is fine: `wash_underlay_1074_shot`,
`gutter_mark_restyle_shot`, `path_verified_shade`, `detection_exception_995`,
`detection_toggle`, `detection_repaint_921`, `link_highlight_gutter_geometry` all PASSED
— the wash and its restyling work; only the observation point moved.

**To join the expected-pass set:** re-point the three assertions at the live wash layer
(`GhosttyWashLayer` / the `DetectionStyleResolver` output it is built from). The
behaviour under test (provider → resolver → live recolour; per-row capsule coverage
across a wrap) is unchanged.

### G5 — `import_upsert_diversity` pins the pre-#1121 key surface (1) — **STALE-TEST**

```
Expected: true  Actual: <false>
KEY field not shown — editor opened in password mode (stale authType not refreshed on
upsert — the #547 follow-up bug, #595)          at import_upsert_diversity_test.dart:278
```

The message is wrong about its own cause, which is why this one needs spelling out. The
test asserts `find.byKey(Key('profile-editor-key'))` — the PEM paste `TextField`.
`profile_editor.dart:1146` only renders that field when `_keySource == _KeySource.pasted`.
Since #1121 (with #1088's key library) the editor pre-selects the profile's OWN attached
key (`profile_editor.dart:258`):

```dart
// Preselect the profile's OWN attached key (#1121). Before this the key
// source always opened on "Paste a new key…" with a blank PEM box …
if (_authKind == _AuthKind.key && p.keyVaultId != null && p.keyVaultId!.isNotEmpty) {
  _keySource = _KeySource.stored;
  _selectedStoredKeyVaultId = p.keyVaultId;
}
```

so the editor renders `profile-editor-stored-key-note` instead. **The editor IS in key
mode.** As written, the failure text sends a reader to chase #595 — a bug that is not
happening.

**To join the expected-pass set:** assert key mode on a surface that survives both
variants — the auth `SegmentedButton`, or `profile-editor-key` **or**
`profile-editor-stored-key-note` — and keep the `findsNothing` check on
`profile-editor-password`, which is the assertion that actually carries the #547/#595
meaning.

This test is **not** in #1101's 22: it went red between that baseline and today. That is
precisely the drift a snapshotted expected-pass set exists to catch, and an argument for
deliverable 2 of #1101.

### G6 — `mermaid_markdown_render` seeds its fixture before the shell is ready (1) — **HARNESS (timing)**

```
Expected: true  Actual: <false>
markdown seed never completed on test-sshd      at mermaid_markdown_render_test.dart:95
```

The discriminator is gateway-log ordering. `markdown_media_fill` and `html_render_sftp`
use a byte-identical seed helper with identical `_slice`/`maxSlices` and both PASSED:

```
markdown_media_fill (PASS)     : line 149  recv shellReady
                                 line 154  send input        ← seed lands in a ready shell
mermaid_markdown_render (FAIL) : line 153  send input        ← seed lands FIRST
                                 line 154  recv shellReady
                                 then      heartbeat … lastActivityAgeMs=11962
```

Twelve seconds of dead air after the write: the seed bytes went out before the shell
channel existed and were dropped, so `MOBISSH_SEED_DONE_942` never echoed. All three
tests gate on the same thing — `_reachTerminal()` waits for the `session-menu-button`
widget, which mounts *before* `shellReady`. Which side of the race a run lands on is
chance. This is the `feedback_ready_signal_before_consumer` pattern.

**To join the expected-pass set:** the seed helper must wait for `shellReady` (or a
prompt byte) before writing — in all three tests, not just re-pump longer.

There is a real product question underneath: input written to a connected-but-not-shell-
ready session is silently discarded, while *commands* at the same seam are buffered
(`send connect BUFFERED (not ready, n=1)`). That asymmetry is noted in the filed issue but
is not what makes this test red.

### G6b — two tests carry emulator-geometry assumptions that no longer hold (2) — **DEVICE**

**`profile_color_picker_1030` — `picker sheet never opened` (:103).** Sequence:
`enterText(password)` → `pump(300ms)` → `ensureVisible(custom swatch)` → `pump(200ms)` →
`tap(custom, warnIfMissed: false)`. The text entry raises the soft keyboard;
`ensureVisible` computes its scroll against a viewport that is still animating, and
`warnIfMissed: false` swallows the miss, so the failure surfaces 20 pumps later as "sheet
never opened" instead of "the tap hit nothing". #1101's own evidence says this one is
**intermittent** (PASSED on plain main in its 6-test sample, failed under #976; failed
here). *Fix:* unfocus before `ensureVisible`, and set `warnIfMissed: true` so a missed
tap fails at the tap and names itself.

**`wrap_join_copy` — truncated copy (:155).** The copy DID happen (`copied != null`), so
the gutter mechanism works; the band just started one row too low:

```
copied="BBBBBBBBBBBBBBBBBBBBBBBB_END\n1c28f38ea1e5:~$\n\n…"
```

The marker is `M_A(30) + "_MID_" + M_B(30)` = 65 chars, which at this device's **50
columns** wraps to row 0 (head) + row 1 (tail). The test anchors the long-press at
`rect.top + rect.height * 0.05`; with the keyboard up (`box=450`, `rows=25`,
cell ≈ 17.7 px, `padding` 4) `_rowFromY` resolves that to **viewport row 1** — so the
head row is outside the band and only the tail is copied. Its own comment ("The clear
puts it near the top, safely inside the gutter band below") states an assumption that is
false at this geometry. *Fix:* anchor the band at row 0 explicitly rather than at a
percentage of the box height. Note `tui_wrap_join_copy` — the same wrap-join contract via
the fake-TUI painter — **PASSED**, so the product's wrap-join is not in question.

### G7 — REAL BUGS (3)

**`attention_notification_post` → already filed as #1188.** Confirmed present,
deterministic, same mechanism and margin band:

```
[attention] osc9 (text len=24) (session 127.0.0.1:2222:testuser:…)
[attention] suppressed (reconnect-replay 1297ms < 1500ms) session …
Expected: true  Actual: <false>
no attention-notification post was logged for the session after an OSC 9 …   (:128)
```

(#1188 measured 1406 / 1385 / 1375 ms; this run 1297 ms.) Not re-diagnosed here per the
brief — #1188 states the decision that has to be made (move the test past the window, or
teach the window to tell replay from live).

**`sftp_favorites` → already filed as #948 (open).** The failure is the exact regression
#948 describes: reopening the favorites menu while the cwd IS the favorite renders
`favorites-empty`.

```
Expected: true  Actual: <false>
#948: second open (cwd IS the favorite) showed favorites-empty       (:226)
```

The test is a regression guard for an open, unfixed product bug. It is correctly red.

**`golden_flow_tui` → NEW, filed (see §6).** The canonical terminal-flow gate produces no
copy at all:

```
GOLDEN anchor: "https://docs.example.com/agent-hub/enrollment/getting-started#writer-jwt-mint"
GOLDEN   range rows=37..37 → gutterRow=13
GOLDEN layer inputs: isScrolling=false scrollbar(offset=0 visible=25 total=25) painted=0
GOLDEN copied="null"
Expected: not null  Actual: <null>   gutter copy wrote nothing        (:284)
```

Detection is fine — the test only reaches line 284 after the `#958` gutter-mark render
assertion passes. The long-press-drag at `rect.right - 14` (dead centre of the 28 px
`kGutterStripWidth`; right/overlay is still the shipped default after #1155) produced **no
`Clipboard.setData` call at all** and no gesture log line.

Discriminators already ruled out, which is what makes this worth filing rather than
guessing:

- `gutter_copy_scrollback` — the other half of `terminal-flow-gate.sh` — **PASSED** in the
  same run, with tmux, mouse reporting ON, the alternate screen, the same
  `rect.right - 14` anchor, the same 700 ms hold and the same `box=450 / rows=25`
  geometry. So it is not tmux, not mouse-mode routing, not the keyboard inset, not the
  strip width, and not the long-press contract.
- The two differ in the drag: golden flow anchors at 25 % and steps 10 × 22.5 px
  (225 px total); the passing test anchors at 40 % and steps 6 × 8 px (48 px total).
  That, and the preceding 8 swipe gestures, are the remaining leads.

Mechanism **undetermined** — stated as open in the issue rather than guessed at here.

---

## 5. Full roster (86)

| Test | Result |
|---|---|
| `active_session_reconnect_test.dart` | PASS |
| `attention_host_suppression_test.dart` | PASS |
| `attention_notification_post_test.dart` | **FAIL** |
| `attention_signal_measurement_test.dart` | PASS |
| `background_snapshot_gate_test.dart` | PASS |
| `browser_targets_1196_test.dart` | PASS |
| `cc_attach_existing_test.dart` | **FAIL** |
| `cc_capture_attach_test.dart` | **FAIL** |
| `cc_capture_scroll_test.dart` | **FAIL** |
| `cc_churn_bounded_test.dart` | PASS |
| `cc_exec_switch_test.dart` | **FAIL** |
| `cc_gestures_test.dart` | PASS |
| `cc_nested_exec_test.dart` | **FAIL** |
| `cc_nested_fallback_test.dart` | **FAIL** |
| `cc_render_test.dart` | PASS |
| `cc_setting_test.dart` | PASS |
| `command_chip_998_test.dart` | PASS |
| `command_incomplete_1042_test.dart` | PASS |
| `connect_key_smoke_test.dart` | PASS |
| `connect_smoke_test.dart` | PASS |
| `connect_view_active_session_test.dart` | PASS |
| `deep_link_1117_test.dart` | PASS |
| `desktop_smoke_test.dart` | **FAIL** |
| `detect_paint_freeze_test.dart` | PASS |
| `detection_exception_995_test.dart` | PASS |
| `detection_lab_1031_test.dart` | **FAIL** |
| `detection_lab_custom_1031_test.dart` | **FAIL** |
| `detection_repaint_921_test.dart` | PASS |
| `detection_toggle_test.dart` | PASS |
| `disconnect_telemetry_test.dart` | PASS |
| `disconnected_scroll_test.dart` | PASS |
| `file_url_actions_994_test.dart` | PASS |
| `force_repaint_robustness_918_test.dart` | PASS |
| `ghostty_osc8_hyperlink_test.dart` | PASS |
| `ghostty_url_detection_test.dart` | PASS |
| `golden_flow_tui_test.dart` | **FAIL** |
| `gutter_copy_scrollback_test.dart` | PASS |
| `gutter_mark_restyle_shot_test.dart` | PASS |
| `gutter_track_scroll_993_test.dart` | PASS |
| `hostkey_persist_test.dart` | PASS |
| `html_render_sftp_test.dart` | PASS |
| `import_smoke_test.dart` | PASS |
| `import_upsert_diversity_test.dart` | **FAIL** |
| `initial_command_smoke_test.dart` | PASS |
| `jump_host_1183_test.dart` | PASS |
| `keyboard_resize_sizing_922_test.dart` | PASS |
| `link_highlight_gutter_geometry_test.dart` | PASS |
| `markdown_media_fill_test.dart` | PASS |
| `mermaid_markdown_render_test.dart` | **FAIL** |
| `multi_session_lifecycle_test.dart` | PASS |
| `osc8_through_tmux_test.dart` | PASS |
| `paint_replay_test.dart` | PASS |
| `path_tap_navigate_999_test.dart` | PASS |
| `path_verified_shade_test.dart` | PASS |
| `port_forward_1047_test.dart` | PASS |
| `port_forward_preview_1054_test.dart` | PASS |
| `profile_color_picker_1030_test.dart` | **FAIL** |
| `profile_default_path_test.dart` | PASS |
| `recent_session_reconnect_test.dart` | PASS |
| `reconnect_cycle_test.dart` | PASS |
| `reconnect_da_writeback_leak_1072_test.dart` | **FAIL** |
| `reconnect_mouse_mode_1014_test.dart` | **FAIL** |
| `relpath_cwd_1036_test.dart` | PASS |
| `resize_storm_bounded_test.dart` | PASS |
| `resume_liveness_test.dart` | PASS |
| `selection_copy_after_redraw_test.dart` | PASS |
| `service_outlives_ui_reconnect_test.dart` | PASS |
| `sftp_browse_smoke_test.dart` | PASS |
| `sftp_favorites_test.dart` | **FAIL** |
| `sftp_upload_roundtrip_test.dart` | PASS |
| `sftp_upload_test.dart` | PASS |
| `shell_bytes_smoke_test.dart` | PASS |
| `single_session_soft_drop_fgs_1018_test.dart` | PASS |
| `terminal_layout_fill_test.dart` | PASS |
| `tmux_scrollback_test.dart` | PASS |
| `tmux_status_tap_kbrace_test.dart` | PASS |
| `tmux_status_tap_sgr_test.dart` | PASS |
| `tmux_window_switch_detection_test.dart` | PASS |
| `tui_wrap_join_copy_test.dart` | PASS |
| `url_bubble_wrap_988_test.dart` | **FAIL** |
| `url_copy_navigate_test.dart` | PASS |
| `url_wrap_indent_925_test.dart` | PASS |
| `viewer_actions_1038_test.dart` | PASS |
| `wash_underlay_1074_shot_test.dart` | PASS |
| `window_switch_repaint_922_test.dart` | PASS |
| `wrap_join_copy_test.dart` | **FAIL** |

---

## 6. Issues

| Issue | State | Covers |
|---|---|---|
| #1188 | open, already diagnosed | `attention_notification_post` (G7) |
| #948 | open | `sftp_favorites` (G7) |
| #1200 | filed by this run | `golden_flow_tui` gutter copy produces nothing (G7) |
| #1201 | filed by this run | input written before `shellReady` is silently dropped while commands at the same seam buffer (G6, secondary) |
| #1187 | open | G0 fixture staleness + `test-sshd` alias ambiguity |

---

## 7. Proposed EXPECTED-PASS set

**Require all 67 tests marked PASS in §5.** That is the honest baseline today: every one
of them passed on a clean `origin/main` against the fleet device with a CURRENT, pinned
fixture. Any of them going red in a PR is signal.

The 19 currently-failing tests should be **excluded from the required set and tracked**,
not silently skipped — each with the named exit condition below. The gate should fail if
an excluded test is deleted or if a new test appears without a decision, so the list
cannot quietly grow.

| Currently failing | Why it is out | What must change to bring it in |
|---|---|---|
| `cc_attach_existing`, `cc_capture_attach`, `cc_capture_scroll`, `cc_exec_switch`, `cc_nested_exec`, `cc_nested_fallback` | G1 HARNESS — prerequisite never run | Runner brackets each with its setup **and** teardown script (`needs_jump_target()` is the precedent); setup scripts must honour `SSHD_HOST` |
| `desktop_smoke` | G2 HARNESS — wrong platform | Exclude from the Android suite; gate via `scripts/desktop-smoke.sh` |
| `reconnect_mouse_mode_1014`, `reconnect_da_writeback_leak_1072` | G3 HARNESS — missing bridge | Add to `needs_second_bridge()` in both scripts (or arm 2223 unconditionally). **Already proved green with the bridge** — these are the two cheapest returns on the list |
| `detection_lab_1031`, `detection_lab_custom_1031`, `url_bubble_wrap_988` | G4 STALE — pre-#1074 observation point | Re-point assertions at `GhosttyWashLayer` / `DetectionStyleResolver` |
| `import_upsert_diversity` | G5 STALE — pre-#1121 key surface | Assert key mode via the auth segment or `profile-editor-stored-key-note` |
| `mermaid_markdown_render` | G6 HARNESS timing | Seed helper waits for `shellReady` before writing (fix in all three seed-helper tests) |
| `profile_color_picker_1030` | G6b DEVICE | Unfocus before `ensureVisible`; `warnIfMissed: true` |
| `wrap_join_copy` | G6b DEVICE | Anchor the gutter band at row 0, not a percentage of box height |
| `attention_notification_post` | G7 REAL — #1188 | Decide the suppression-window question in #1188 |
| `sftp_favorites` | G7 REAL — #948 | Fix #948 |
| `golden_flow_tui` | G7 REAL — new | Root-cause the missing `Clipboard.setData` on the gutter long-press-drag |

**Sequencing note for the orchestrator.** G1+G2+G3 are 9 of the 19 and are all runner
wiring — no test logic and no product code. Landing those takes the required set from 67
to 76 and makes the #589 gate meaningful again in one change. G4+G5 (4 more) are
mechanical test edits against documented product decisions. Only the last three need a
product judgement.

**Do not** reach for `--integration-verified` in the meantime: with 67 named expected
passes, a subset run over the touched area is now a defensible substitute, and a full
run costs ~100 minutes of one lease.

---

## 8. Suite hygiene observations (not failures)

- The POST_NOTIFICATIONS grant-watcher emits `Failure [package not found]` once per
  second for the whole run — tens of thousands of lines in the suite log, and it is the
  single largest obstacle to reading that log. It should quiesce once the package is
  installed, or write to its own file.
- `needs_second_bridge()` and `needs_jump_target()` are duplicated verbatim in two
  scripts. Both drifted. They belong in `scripts/lib/`.
- The canonical `mobissh-test-sshd-1` container has been up **6 weeks** and carries test
  residue (`mobissh_itest_892_tilde.txt`, a 26 KB `.bash_history`). A fixture that
  outlives the code it tests is a silent variable; #1187's "build once, reuse by stable
  tag" fix should also bound its lifetime.
