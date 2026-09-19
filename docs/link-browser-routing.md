# Per-profile browser for extracted links — spec

Status: draft, 2026-09-19. Owner-requested: *"add a setting to control default browser to open extracted links per profile (eg open work nvdev links in prisma and other links in Chrome)"*.

## Goal

A link detected in a terminal session opens in the browser chosen for THAT session's profile — work hosts in a work browser, everything else in the normal one — instead of always going to the system default.

## What exists today

Every in-app link open funnels through `url_launcher`'s `launchUrl(uri, mode: LaunchMode.externalApplication)`, which hands the URL to **whatever the OS picked as default**. There is no way to name a target app through that API. Call sites:

- `url_action_overlay.dart:34` — `openDetectedUrl()`, the shared path for the terminal long-press menu AND the gutter list-sheet (`ghostty_gutter_layer.dart:465`). This is the "extracted links" the request is about.
- `markdown_file_viewer.dart:54`, `html_file_viewer.dart:52` — links inside a viewed remote file.
- `attention_providers.dart:108` — the attention-notification tap target. Out of scope (not an extracted link).

Two facts that make this cheap:

- `AndroidManifest.xml:114-131` ALREADY declares `<queries>` for `ACTION_VIEW` on `http` and `https` (added for #570). That is exactly the package-visibility declaration `queryIntentActivities` needs to ENUMERATE installed browsers on API 30+, so no manifest change is required to list them.
- `MainActivity.kt` already hosts several `MethodChannel`s (#529 file picker and others), so a new channel is the house idiom, not new machinery.

## Why a platform channel and not a package

`url_launcher` cannot target a named app. `android_intent_plus` could (`setPackage`), but it cannot ENUMERATE the installed browsers, which this feature needs in order to offer a picker at all. One channel does both jobs, so a new dependency would be added and still leave half the problem. **Decision: a MethodChannel, no new dependency.**

## Requirements

### Platform seam (slice 1)

- **R1** New channel `mobissh/browser` with `listBrowsers()` → a list of `{package, label, isDefault}` for activities resolving `ACTION_VIEW https://`, and `open(url, package?)` → bool. `package == null` means today's behaviour (system default).
- **R2** `open` with a named package sets that package on the VIEW intent. If the package is not installed or the start fails, it **falls back to the system default and reports that it fell back** — the caller must be able to tell "opened where you asked" from "opened somewhere else".
- **R3** The Dart side is an injectable service (`BrowserTargets`) with a provider, so every test runs against a fake and no test touches a real browser. Mirrors the existing fetcher/writer seam style.
- **R4** On a platform with no channel (desktop, tests), `listBrowsers()` returns empty and `open` degrades to today's `launchUrl` path. An empty list means the UI offers no choice at all rather than an empty dropdown.
- **R5** Browser labels come from the OS (`loadLabel`), never a hardcoded list — a browser this app has never heard of must be selectable.

### Routing + settings (slice 2)

- **R6** A global default browser setting (Settings → the existing appearance/behaviour area): "System default" plus every enumerated browser. Stored in the existing settings JSON, additive, no key bump, corrupt value → System default.
- **R7** A per-profile override on `SavedProfile` (`linkBrowserPackage`, nullable): "Use the global default" (null) plus every enumerated browser. Additive to the profile JSON, unknown/corrupt → null, no key bump.
- **R8** Resolution order at open time: profile override → global default → system default.
- **R9** A link extracted from a session resolves against THAT session's profile. `openDetectedUrl()` takes an optional profile/session key; when absent it resolves against the ACTIVE session, because the overlay and gutter sheet belong to the visible terminal.
- **R10** File-viewer links (markdown, HTML) resolve against the session the file was opened over — same rule, same seam.
- **R11** When R2 reports a fallback, tell the user which browser was missing, once, where the action was — a link that opens in the wrong browser silently is the failure this feature is meant to remove.
- **R12** A profile whose chosen browser is uninstalled keeps the setting (the app may be reinstalled); the fallback is a runtime behaviour, not a silent config edit.
- **R13** Surfacing: the profile editor's browser picker sits with the other per-profile behaviour fields, monochrome glyph, no emoji. A profile using the global default shows no extra chrome.

## Decisions

- **D1** Per-profile, not per-URL-pattern. The example ("work nvdev links in prisma") is a property of the host you are working on, and a URL-pattern rule engine is a second feature with its own UI, precedence and debugging story. A pattern layer can be added later ON TOP of this without changing the model.
- **D2** Store the package name, not a display label. Labels change with app updates and locale; the package is the identity.
- **D3** No new dependency (see above).
- **D4** Attention-notification taps keep the system default — they are not extracted links, and a notification tap is not scoped to a visible session.

## Slices

1. **Slice 1 — platform seam.** R1-R5. Channel + Kotlin enumeration/launch + `BrowserTargets` service, provider and fake. No UI, no settings. `device` (enumeration and package-targeted launch cannot be proven headless).
2. **Slice 2 — routing + settings.** R6-R13. Depends on slice 1.

## Tests

- **A1** (slice 1) Dart unit against a fake channel: `listBrowsers` maps the platform payload; `open` passes the package through; a platform error surfaces as a fallback result, not a throw.
- **A2** (slice 1) `MethodChannel` contract test: method names and argument keys pinned, so a Kotlin-side rename fails a Dart test.
- **A3** (slice 1) No channel (desktop/test host) → empty list, `open` still opens via the existing path.
- **A4** (slice 1, emulator) `listBrowsers()` returns at least one real activity on the emulator image, and `open(url, package)` with that package starts it. This is the only proof the `<queries>` declaration actually covers enumeration.
- **A5** (slice 2) Resolution order: profile override wins over global; global wins over system; a profile with no override and no global uses system.
- **A6** (slice 2) A link opened from session A uses A's profile browser while B is connected with a different one (assert isolation, per the project's per-session scoping rule).
- **A7** (slice 2) Missing package → opens anyway via fallback AND the user is told which browser was missing.
- **A8** (slice 2) Settings and profile-editor pickers list enumerated browsers plus the right "default" option; an empty enumeration hides the control entirely (no dead affordance).
- **A9** (slice 2) Round-trip: both new fields persist, survive a reload, and a corrupt value reads back as the default.
