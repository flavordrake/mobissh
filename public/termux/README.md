# MobiSSH crash capture from Termux

When the native APK crashes too early for its in-app reporter to run, these
Termux scripts pull the crash from `logcat` via wireless ADB and upload to
the mobissh bridge at `POST /api/native-crash`.

## One-time setup

1. **Phone Settings → System → Developer Options → Wireless debugging → ON**

2. In the **Wireless debugging** screen:
   - Tap **Pair device with pairing code**
   - Note the **IP:PORT** and the **6-digit code** (a pairing-only port, different from the regular connect port)

3. **In Termux:**
   ```
   pkg update -y
   pkg install -y android-tools curl
   adb pair <pair-ip>:<pair-port>
   # paste the 6-digit code when prompted
   ```

4. Back on the Wireless debugging screen, note the **second IP:PORT** (the
   non-pairing one — usually a different port). In Termux:
   ```
   adb connect <connect-ip>:<connect-port>
   adb devices       # should show your phone with state "device"
   ```

That's the setup. ADB lives on after Termux is killed; if the connection
drops just run `adb connect` again.

## Capture a crash (one-shot)

After installing/launching the APK and seeing the crash dialog:

```
curl -fsSLO https://mobissh.tailbe5094.ts.net/termux/mobissh-logcat.sh
chmod +x mobissh-logcat.sh
./mobissh-logcat.sh
```

The script grabs the last 5000 lines from logcat across the main/crash/system
buffers, bundles device metadata, POSTs the bundle to the bridge, and saves
a local copy to `~/mobissh-crash/<timestamp>-logcat.txt`.

## Monitor mode (auto-upload every crash)

Background watcher that detects FATAL exceptions and auto-uploads each:

```
./mobissh-logcat.sh --watch
```

Ctrl-C to stop, or run with `nohup` to keep it going in the background.

## What to do if ADB pairing fails

Some Pixels show the pairing code only briefly. If you missed it, tap
**Pair device with pairing code** again — a new code is generated.

If `adb pair` reports "failed to authenticate", your local Termux ADB version
may be older than the phone's adbd. Workaround: `pkg upgrade android-tools`.

## What gets uploaded

- Last N lines of merged `logcat -d -b main -b crash -b system`
- `getprop` device model, Android version, SDK level, ABI
- A short header (timestamp, trigger reason in --watch mode)

No credentials, no PWA vault data — purely device/system logs.
