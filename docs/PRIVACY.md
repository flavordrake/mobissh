# MobiSSH — Privacy Policy

**Effective date:** 2026-10-04
**App:** MobiSSH (`com.flavordrake.mobissh`)
**Contact:** flavordrake@gmail.com

## The short version

MobiSSH is an SSH/SFTP client. **Your data is yours.** Your credentials and
your terminal sessions stay on your device and flow directly between your device
and the servers *you* connect to. The developer's systems are **not** in that
path and never receive your session content — **except** the one time you
explicitly tap **Send bug report**, which uploads a diagnostic bundle you can
review first. We show no ads, run no third-party analytics or trackers, and
never sell or share your data.

---

## 1. Data that stays on your device (never sent to us)

- **Connection credentials** — SSH passwords, private keys, and key passphrases
  you save are stored **encrypted on the device** (AES-GCM, key held in the
  platform's hardware-backed credential store). They are transmitted only to the
  SSH server *you* are connecting to, over the encrypted SSH channel. They are
  never sent to the developer.
- **Connection profiles & app settings** — hostnames, ports, usernames,
  favorites, font size, and preferences are stored locally on the device. A bug
  report you send includes a short list of settings, described in section 3.

## 2. Data that flows only between you and your servers

MobiSSH connects **directly** from your device to the SSH/SFTP servers you
choose. Everything in a session — commands you type, terminal output, and files
you browse, download, or upload — travels over that direct, encrypted SSH
connection between your device and your server. **The developer operates no
proxy or relay in this path and cannot see this content.**

## 3. The one exception: bug reports you choose to send

If — and only if — you tap **Send bug report** (or **Share feedback**), the app
assembles a diagnostic bundle and uploads it to the developer's diagnostics
endpoint (or, for **Share feedback**, hands it to your device's share sheet so
*you* choose where it goes). This is always an explicit, per-report action.

**Crash reports are the exception to the exception.** If the app crashes, it
saves a crash report (the error message, stack trace, device model, OS and app
version; it does not collect terminal output or credentials, though an error
message can quote what the app was handling, such as a file name) and uploads it to the same diagnostics
endpoint on the next launch or the next successful connection, without asking.

**Update checks.** A sideloaded copy of the app reads a small version file
(`android-latest.json`) from the developer's distribution host on start, on
resume and from Settings → About & updates, to offer newer builds. When a newer
build is offered and the device is on an unmetered network (Wi-Fi), the app also
downloads that APK from the same host in the background and keeps it in its
private cache until you install it. These requests carry nothing about you or
your sessions. The Play Store build does not include this.

**A bug report may contain:**
- a **screenshot** of the app at the moment you report, and short recent frames;
- recent **terminal I/O traces** (the bytes rendered on screen, scroll and
  gesture logs, the terminal's automatic replies) — used to reproduce
  display/input bugs;
- **connection, app-lifecycle, tmux control-mode and diagnostic logs**,
  link-detection layout data, and any pending **crash report**;
- a **settings snapshot**: only these settings, picked by name — text size,
  default font, default terminal theme, whether the compose bar is shown, the
  terminal renderer, whether sessions are kept alive in the background, whether
  the battery-optimization prompt was shown, tmux control mode, the link
  detection settings (which types are on, intensity, gutter side and mode, and
  the package name of the browser you chose for links), whether experimental
  settings are shown. No hostnames, ports, usernames, passwords, keys or
  passphrases are included, and no other profile details;
- your **device model, OS version, and the app version**.

**Because those traces and the screenshot capture what was on your screen, they
may include content from your session.** So before anything is sent, the app
shows you a **Review & Send** screen: you see the screenshot (or step through
every frame of a screen recording), you can **exclude the screen images** and/or
**the diagnostic traces** with a toggle, and you can view the exact diagnostic
text that would be uploaded. Nothing leaves your device until you tap **Send**;
**Cancel** discards it. As defense-in-depth, an automated pass also redacts
password-, token-, and key-looking strings from the text logs — but this is
**best-effort, not a guarantee**, which is why *you* review the images yourself.

**Reports waiting to send are stored on your device.** When you tap **Send**,
the report (including its screenshot, frames, terminal traces and logs) is first
written to the app's private storage, then uploaded. On Android that storage is
excluded from cloud backup and device-to-device transfer. If the upload fails,
for example because you are offline, the report stays there and the app sends it
automatically on a later launch, connection or return to the app. Limits and
clean-up:
- at most **10 reports or 50 MB**; when a new report would exceed that, the
  oldest saved reports are deleted;
- a saved report older than **30 days** is deleted without being sent, and the
  app tells you;
- a report is deleted from the device as soon as it is delivered;
- a report the server refuses is kept, marked as refused, and never retried;
  one interrupted mid-upload is kept and never resent automatically;
- **Settings → Advanced → Diagnostics** shows how many reports are waiting,
  refused or interrupted, and lets you send them now or **Discard** all of them.

- **Purpose:** solely to diagnose and fix the reported bug.
- **Recipients:** the developer. Not shared with, sold to, or used by any third
  party or advertiser.
- **What the server keeps:** the screenshot and frames, your note, the logs and
  traces listed above, the settings snapshot, which part of the app sent the
  report, and the device and app version.
- **Retention:** there is **no automatic deletion**. The developer's server has
  a retention setting that deletes reports older than a set number of days, but
  it is off by default, so reports are kept until the developer deletes them.
  Reports from the Play Store build go to a separate developer-owned storage
  bucket, which also has no automatic expiry configured in this project.
- **Deletion on request:** email flavordrake@gmail.com to have any report you sent
  deleted.

## 4. Permissions and why the app asks

- **Foreground service (data sync) + notifications** — to keep your SSH session
  connected while the app is in the background and to show its status. Also used
  to surface build/connection events you opt into.
- **Ignore battery optimizations (optional)** — so Android doesn't freeze the
  connection while the screen is off. You can decline; sessions may then drop
  during sleep.
- **Storage (save to Downloads)** — only to write files you explicitly download
  over SFTP into your device's Downloads folder.
- **Internet** — to make SSH/SFTP connections to your servers (and to send a
  bug report if you choose to).

## 5. What we do NOT do

- No advertising, ad IDs, or ad networks.
- No third-party analytics, tracking, or profiling SDKs.
- No selling, renting, or sharing of your data.
- No background collection or transmission of your session content, credentials,
  or usage. The only automatic uploads are the crash report described in
  section 3 and the resending of bug reports you already chose to send.

## 6. Children

MobiSSH is a developer tool and is not directed to children under 13.

## 7. Changes to this policy

If this policy changes, the updated version will be posted at this URL with a new
effective date.

## 8. Contact

Questions or data-deletion requests: **flavordrake@gmail.com**
