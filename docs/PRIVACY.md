# MobiSSH — Privacy Policy

**Effective date:** {{EFFECTIVE_DATE}}
**App:** MobiSSH (`com.flavordrake.mobissh`)
**Contact:** {{CONTACT_EMAIL}}

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
  favorites, font size, and preferences are stored locally on the device.

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
*you* choose where it goes). This is always an explicit, per-report action; the
app never uploads anything in the background.

**A bug report may contain:**
- a **screenshot** of the app at the moment you report, and short recent frames;
- recent **terminal I/O traces** (the bytes rendered on screen, scroll and
  gesture logs) — used to reproduce display/input bugs;
- **connection and diagnostic logs** and any pending **crash report**;
- your **device model, OS version, and the app version**.

**Because those traces and the screenshot capture what was on your screen, they
may include content from your session.** Before upload, the app runs an
automated pass that **redacts** password-, token-, and key-looking strings from
the logs. You should still glance at what you're sending — for the **Share
feedback** path you control the destination entirely.

- **Purpose:** solely to diagnose and fix the reported bug.
- **Recipients:** the developer. Not shared with, sold to, or used by any third
  party or advertiser.
- **Retention:** bug-report bundles are kept only as long as needed to resolve
  the issue and no longer than **{{RETENTION_DAYS}} days**, then deleted.
- **Deletion on request:** email {{CONTACT_EMAIL}} to have any report you sent
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
  or usage.

## 6. Children

MobiSSH is a developer tool and is not directed to children under 13.

## 7. Changes to this policy

If this policy changes, the updated version will be posted at this URL with a new
effective date.

## 8. Contact

Questions or data-deletion requests: **{{CONTACT_EMAIL}}**
