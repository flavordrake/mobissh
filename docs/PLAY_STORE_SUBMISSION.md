# MobiSSH — Play Store Submission Guide

Step-by-step for a Google Play submission, with copy-paste answers and every URL we've provisioned.

- **Package:** `com.flavordrake.mobissh`
- **Version:** 0.1.10 (versionCode 103) · **Target API:** 35
- **Prepared:** 2026-07-02

Legend: **[ready]** already provisioned · **[paste]** copy the value · **[you]** needs your input or an asset.

## Provisioned URLs (the ones you'll paste)

| What | URL | Where it goes |
|---|---|---|
| **App bundle (.aab)** `[ready]` | `https://mobissh.tailbe5094.ts.net/mobissh-release.aab` | Upload to a release |
| **Privacy policy** `[ready]` | `https://mobissh-bug-report.flavordrake.workers.dev/privacy` | Store listing + App content |
| **Bug-report endpoint** `[ready]` | `https://mobissh-bug-report.flavordrake.workers.dev` | Already baked into the build — nothing to enter |

> Your private **report viewer** (`/`, Basic-auth) and the R2 bucket are for you only — never entered into Play.

## 0. Before you start

- **Play Console account** — one-time US$25, identity verified (play.google.com/console).
- **Signed AAB** — built with your upload key (CN=MobiSSH), targetSdk 35. Already at the URL above; rebuild anytime with `scripts/build-release-aab.sh`.
- **Play App Signing** — accept enrollment on first upload. Play holds the app-signing key; your keystore stays the *upload* key.

## 1. Create the app

1. Play Console → **All apps → Create app**.
2. App name `[paste]` `MobiSSH` · Default language `English (US)`.
3. App or game → **App**. Free or paid → **Free**.
4. Accept declarations → **Create app**.

## 2. App content (Policy) — declarations

**Privacy policy** — App content → Privacy policy → paste → Save:

```
https://mobissh-bug-report.flavordrake.workers.dev/privacy
```

**App access** `[you]` — reviewers need to see the app work, but MobiSSH needs an SSH server to connect to. Choose **"All or some functionality is restricted"** and add instructions with a throwaway login:

```
MobiSSH is an SSH/SFTP client; it connects to a server the user provides.
To review: open the app, tap Add/Connect, and enter this temporary test host:
  Host: test.example.net   Port: 22
  Username: playreview      Password: <set one>
A shell prompt and the file browser confirm core functionality.
```

> **Action:** stand up a disposable SSH account (any VPS / locked-down container) for the review window, or the reviewer can't exercise the app. Delete it after approval.

**Ads / audience / rating:**
- Ads → **No, my app does not contain ads.**
- Content rating → start IARC questionnaire; category **Utility/Productivity**; **No** to violence, sexual, profanity, gambling, drugs, user-to-user messaging → result **Everyone**.
- Target audience → **18+** (developer tool, not directed to children — avoids Families policy).
- Government / financial / health → **No** to each.

## 3. Data safety — full answers

The honest core: the app collects **nothing automatically**; the only data that reaches you is a bug report the user explicitly sends, after the in-app Review & Send screen.

**Overview questions:**

| Question | Answer |
|---|---|
| Does your app collect or share any of the required user data types? | **Yes** |
| Is all user data collected by your app encrypted in transit? | **Yes** (HTTPS/TLS) |
| Do you provide a way for users to request that their data be deleted? | **Yes** (email; 30-day retention) |

**Data types to declare** — for each: Collected = **Yes**, Shared = **No**, Processing is **optional** (user chooses to send), Purpose = **App functionality**. None for ads/analytics/tracking.

| Category → type | Why (it's in a bug report) |
|---|---|
| App info & performance → **Crash logs** | Pending crash report attached to a bug report. |
| App info & performance → **Diagnostics** | Terminal I/O traces, connection/gesture logs, device model, OS, app version. |
| App activity → **Other user-generated content** | The typed comment + the screenshot / recording frames the user chooses to attach. |

**Explicitly NOT collected:**

| Type | Why it's "No" |
|---|---|
| SSH passwords / keys / passphrases | Stored **encrypted on-device only** (AES-GCM). Never transmitted to the developer → not "collection" per Play's definition. |
| Terminal session content | Flows directly device ↔ your own server; developer runs no relay and never receives it. |
| Location · Contacts · Financial · Personal info · Web history · Device/Ad IDs | Not collected, not accessed, no ads SDK, no analytics. |

> **Deletion method:** choose "users can request deletion" and give email `flavordrake@gmail.com`. Retention: reports deleted within 30 days (matches the privacy policy).

## 4. Foreground service permission declaration

App content → "Foreground service permissions" (Play flags `FOREGROUND_SERVICE_DATA_SYNC` in the AAB). Use case → **dataSync**. Justification `[paste]`:

```
MobiSSH is an SSH/SFTP client. When the user connects to a server, a foreground
service (type dataSync) keeps that session and any in-progress file transfers
alive while the app is backgrounded or the screen is off, so long-running remote
commands and uploads/downloads are not terminated by the system. The service
starts only from an explicit user action (connecting) and shows an ongoing
notification for its entire lifetime. Without it, active sessions and transfers
would be killed when the app leaves the foreground.
```

> **You may need:** Play often asks for a short **screen recording** demonstrating the service (connect → background the app → session/notification persists). Record a ~20s device clip and upload if prompted.

## 5. Store listing

**App name** (30 max) `[paste]`:

```
MobiSSH
```

**Short description** (80 max) `[paste]`:

```
A fast, mobile-first SSH & SFTP client with a real terminal and file browser.
```

**Full description** `[paste]`:

```
MobiSSH is a mobile-first SSH and SFTP client built for people who actually work from their phone.

• Real terminal — a native, fast terminal with drag-to-select and one-tap copy, tmux-aware scrolling, and detection of links and file paths in output.
• SFTP file browser — browse, sort, download and upload files, with per-server path favorites.
• Stays connected — a foreground service keeps your session and transfers alive in the background; optional keep-alive across sleep.
• Private by design — your SSH credentials are stored encrypted on your device and are sent only to the servers you connect to. Sessions go directly between your device and your server; nothing routes through us.
• You control diagnostics — bug reports are never sent automatically. A Review & Send screen lets you preview and exclude the screenshot and diagnostic data before anything leaves your device.

No ads. No third-party analytics or trackers. No selling your data.
```

**Graphics** `[you]` — the only real blockers left:
- **App icon** — 512×512 PNG, 32-bit (monochrome MobiSSH glyph on a solid ground).
- **Feature graphic** — 1024×500 PNG/JPG (required even for the internal-testing listing).
- **Phone screenshots** — 2–8, PNG/JPG. Suggested: Connect screen · terminal in a tmux session with gutter marks · file browser · the Review & Send screen · Settings.

**Categorization & contact:**
- App category → **Tools**
- Store listing contact email → `flavordrake@gmail.com`
- External marketing/website → not required.

## 6. Create the Internal testing release

1. Testing → **Internal testing → Create new release**.
2. Accept **App Signing** enrollment (first time) → Continue.
3. **Upload** the AAB (download it first from the URL below, then drag it in).
4. Release name auto-fills `103 (0.1.10)`. Paste release notes.
5. Testers tab → create an email list with your address (and others) → save.
6. **Review release → Start rollout to Internal testing.**

AAB to upload:

```
https://mobissh.tailbe5094.ts.net/mobissh-release.aab
```

Release notes `[paste]`:

```
First internal test build. Real terminal with copy, SFTP file browser, background keep-alive, encrypted on-device credentials, and a Review & Send consent screen for bug reports.
```

> **Why internal first:** no review wait, up to 100 testers; validates the whole signing + upload pipeline and installs via Play on your device. Promote the same build to Closed/Production once graphics + the review SSH account are ready.

## 7. Submit & promote

1. Confirm every **App content** item shows a green check (privacy policy, data safety, ads, rating, target audience, FGS declaration).
2. Internal rollout is instant — install via the tester opt-in link Play gives you.
3. When graphics + the reviewer SSH account are ready → **Promote release → Production** (or Closed testing) → submit for review.
4. Next build: bump `pubspec +N` before re-running `build-release-aab.sh` — Play requires a higher versionCode each upload.

## What's left, at a glance

- **Reviewer SSH access** `[you]` — disposable host + creds for App access.
- **Icon · feature graphic · screenshots** `[you]` — the store's only hard asset blockers.
- **Optional FGS demo video** `[you]` — only if Play asks.
- **Everything else** `[ready]` — AAB, signing, privacy policy, data-safety answers, FGS text, listing copy (all above).
