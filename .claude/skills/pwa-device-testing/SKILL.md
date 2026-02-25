---
name: pwa-device-testing
description: This skill should be used when the user asks to "test on device", "test on emulator", "run emulator", "launch AVD", "test PWA", "test on Android", "test on mobile", "verify on real device", "check on phone", or discusses testing a feature on an actual device or emulator rather than headless Playwright. Also use when validating features that headless browsers cannot cover (biometric, PWA install, Chrome autofill, touch gestures, password managers).
version: 0.1.0
---

# PWA Device Testing

Headless Playwright tests cover logic and layout but cannot validate:
- Chrome password manager / autofill behavior
- WebAuthn biometric (fingerprint, face)
- PWA install-to-homescreen and standalone mode
- Real touch gestures, virtual keyboard, IME
- Service worker update UX on actual Chrome
- CSS safe-area-inset rendering on notched devices

This skill provides the correct setup and workflow for real-device testing using an Android emulator.

## Prerequisites

The setup script lives at `scripts/setup-avd.sh` in the project root. It handles everything:

```bash
bash scripts/setup-avd.sh
```

What it installs (idempotent, safe to re-run):
- Android SDK cmdline-tools (uses JDK bundled in android-studio snap)
- platform-tools, emulator, Android 35 system image with Google Play
- Creates `MobiSSH_Pixel7` AVD (Pixel 7 profile, 4GB RAM, KVM-accelerated)
- Writes a launch helper at `~/Android/Sdk/launch-mobissh-avd.sh`
- Adds `ANDROID_HOME` to `.bashrc`

Requires: `android-studio` snap, KVM enabled (`/dev/kvm` must exist).

## Launch Workflow

### 1. Start the MobiSSH server

```bash
cd server && npm start
# or for background:
nohup bash -c 'PORT=8080 node server/index.js' > /tmp/mobissh-server.log 2>&1 &
```

Verify it's running: `curl -s http://localhost:8080/ | head -5`

### 2. Launch the emulator

```bash
bash ~/Android/Sdk/launch-mobissh-avd.sh
```

This boots the AVD, waits for boot completion, and runs `adb reverse tcp:8080 tcp:8080` so the emulator's `localhost:8080` reaches the host's server.

### 3. Open Chrome on the emulator

Navigate to `http://localhost:8080`. First boot may need a Chrome update via Play Store.

## Testing Checklists

### Vault / Credential Testing
- [ ] First-run: master password modal appears on first profile save
- [ ] Password strength meter updates as you type
- [ ] Vault creation completes, modal dismisses, toast shows
- [ ] Chrome autofill does NOT interfere with vault password fields
  (fields have `data-lpignore`, `data-1p-ignore`, `data-form-type="other"`)
- [ ] Profile save encrypts credentials (check via Chrome DevTools > Application > localStorage)
- [ ] Profile load decrypts and populates form fields
- [ ] Lock vault from settings, verify status changes to "Locked"
- [ ] Unlock via inline password bar
- [ ] Change master password, verify old password rejected after change
- [ ] Biometric enrollment (see fingerprint simulation below)

### Biometric / WebAuthn Testing
```bash
# Simulate fingerprint touch (finger ID 1) after WebAuthn prompt appears
adb emu finger touch 1
```
- [ ] "Enable fingerprint unlock" toggle appears during vault setup
- [ ] Fingerprint enrollment completes with simulated touch
- [ ] After lock, biometric prompt appears and fingerprint unlocks vault
- [ ] Disabling biometric in settings removes the biometric path

### PWA Install Testing
- [ ] Chrome shows "Add to Home Screen" in menu (or install banner)
- [ ] Installed PWA opens in standalone mode (no browser chrome)
- [ ] Service worker caches assets for offline fallback
- [ ] SW update prompts or applies transparently on next load

### Touch / IME Testing
- [ ] Virtual keyboard appears when tapping terminal or IME area
- [ ] Swipe typing produces correct characters
- [ ] Key bar buttons (Ctrl, Esc, Tab, arrows) send correct sequences
- [ ] Long-press on terminal doesn't trigger unwanted selection
- [ ] Ctrl sticky modifier works (tap Ctrl, then tap letter)

### Layout / Visual Testing
- [ ] Tab bar renders correctly, auto-hides after connect
- [ ] Terminal fills available space (no overflow, no gap)
- [ ] Settings panel scrolls properly
- [ ] Font size slider updates terminal in real-time
- [ ] Theme changes apply immediately

## Useful ADB Commands

```bash
# Device status
adb devices
adb shell getprop ro.build.version.release   # Android version

# Port forwarding (already done by launch script)
adb reverse tcp:8080 tcp:8080

# Simulate fingerprint
adb emu finger touch 1

# Type text into focused field
adb shell input text 'hello'

# Take screenshot
adb exec-out screencap -p > /tmp/emulator-screenshot.png

# Chrome logs
adb logcat -s chromium

# Open Chrome DevTools on desktop
# Navigate to chrome://inspect/#devices in desktop Chrome

# Open a URL in emulator Chrome
adb shell am start -a android.intent.action.VIEW -d 'http://localhost:8080'

# Kill emulator
adb emu kill
```

## Troubleshooting

**Emulator won't start**: Check `emulator -list-avds` shows `MobiSSH_Pixel7`. If KVM permission denied: `sudo chmod 666 /dev/kvm` or add user to kvm group.

**Port forwarding not working**: Run `adb reverse --list` to verify. If empty, re-run `adb reverse tcp:8080 tcp:8080`.

**Chrome not installed or outdated**: Open Play Store on emulator, update Chrome. Google Play system images include Play Store access.

**WebAuthn not prompting for fingerprint**: Ensure Chrome is version 120+ (`chrome://version`). The emulator must have a fingerprint enrolled in Settings > Security > Fingerprint. Enroll via: `adb emu finger touch 1` while in the fingerprint setup flow.

**Slow emulator**: Verify KVM is active (`emulator -accel-check`). The AVD config sets `hw.gpu.mode=auto` for GPU acceleration. Close other heavy apps.

## When to Use This vs Playwright

| Scenario | Tool |
|---|---|
| Logic, state, DOM structure | Playwright |
| CSS layout on specific viewports | Playwright |
| Chrome autofill / password manager | Emulator |
| WebAuthn / biometric | Emulator |
| PWA install + standalone mode | Emulator |
| Real touch/swipe/IME | Emulator |
| Service worker update flow | Emulator |
| Visual regression on notched devices | Emulator |

Rule of thumb: if the feature involves browser-native UI that Playwright's headless Chromium doesn't have (password manager, biometric prompt, install banner), use the emulator.
