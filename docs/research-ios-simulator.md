# iOS Simulator Testing Setup Research

Research spike for issue #9: iOS Simulator testing parallel to the Android emulator approach.

## 1. Tools Needed

| Tool | Purpose | Install method |
|------|---------|----------------|
| Xcode | Full IDE, includes Simulator.app and CLI tools | Mac App Store or `xcode-select --install` (CLI tools only) |
| `xcrun simctl` | CLI for creating, booting, managing simulators | Bundled with Xcode |
| `safaridriver` | WebDriver for Safari (desktop and Simulator) | Bundled with macOS (`/usr/bin/safaridriver`) |
| Appium + XCUITest driver | WebDriver automation for iOS Simulator Safari | `npm install -g appium && appium driver install xcuitest` |

## 2. Can iOS Simulator Run Without Full Xcode?

**No.** The iOS Simulator requires the full Xcode installation, not just Xcode Command Line Tools.

- `xcode-select --install` gives you compilers, `git`, `make`, etc., but NOT Simulator.app.
- Simulator.app lives inside `Xcode.app/Contents/Developer/Applications/Simulator.app`.
- Xcode is ~12-15 GB on disk. There is no lightweight alternative.
- Starting with Xcode 14, you can download additional simulator runtimes separately (`xcodebuild -downloadPlatform iOS`), but Xcode itself is still required.

**Android comparison:** Android SDK cmdline-tools can be installed standalone (~500 MB for emulator + system image). iOS has no equivalent lightweight path.

## 3. Creating, Booting, and Managing Simulators via CLI

All management is done through `xcrun simctl`:

```bash
# List available runtimes and device types
xcrun simctl list runtimes
xcrun simctl list devicetypes

# Create a simulator (returns UUID)
xcrun simctl create "MobiSSH_iPhone15" \
  "com.apple.CoreSimulator.SimDeviceType.iPhone-15" \
  "com.apple.CoreSimulator.SimRuntime.iOS-17-4"

# Boot the simulator
xcrun simctl boot "MobiSSH_iPhone15"

# Check status
xcrun simctl list devices | grep "MobiSSH_iPhone15"

# Shutdown
xcrun simctl shutdown "MobiSSH_iPhone15"

# Delete
xcrun simctl delete "MobiSSH_iPhone15"

# Erase all content and settings (reset to clean state)
xcrun simctl erase "MobiSSH_iPhone15"
```

**Headless mode:** Starting with Xcode 15, simulators can run headless (no Simulator.app window):
```bash
# Boot headless — no GUI window opens
xcrun simctl boot "MobiSSH_iPhone15"
# vs. opening the GUI
open -a Simulator --args -CurrentDeviceUDID <UUID>
```

**Android comparison:** `avdmanager create avd` + `emulator -avd` maps to `xcrun simctl create` + `xcrun simctl boot`. The iOS CLI is simpler (single tool vs. sdkmanager + avdmanager + emulator).

## 4. Opening a URL in Simulator Safari

```bash
# Open URL in the booted simulator's Safari
xcrun simctl openurl booted "http://localhost:8081"

# Target a specific simulator by name or UUID
xcrun simctl openurl "MobiSSH_iPhone15" "http://localhost:8081"
```

**Network access:** The iOS Simulator shares the host's network stack. No port forwarding needed (unlike Android which requires `adb reverse`). `localhost:8081` on the host is directly accessible from Simulator Safari.

**Android comparison:** Android emulator requires `adb reverse tcp:8081 tcp:8081` for localhost access. iOS Simulator needs nothing, which simplifies the test setup.

## 5. WebDriver Options for Safari on Simulator

### Option A: safaridriver (built-in, limited)

`safaridriver` is bundled with macOS and supports Safari on Simulator.

```bash
# Enable safaridriver (one-time, requires admin)
safaridriver --enable

# Enable remote automation in Safari's Develop menu
# (Settings > Safari > Advanced > "Web Inspector" must be on in Simulator)

# Start safaridriver
safaridriver --port 4444
```

Limitations:
- Only supports Safari (not WKWebView in other apps)
- Limited gesture/touch simulation compared to Appium
- No access to native UI elements outside the browser
- Does support W3C WebDriver protocol

### Option B: Appium + XCUITest driver (recommended)

Appium's XCUITest driver provides full device automation including Safari.

```bash
# Install
npm install -g appium
appium driver install xcuitest

# Run Appium
appium --port 4723

# Capabilities for Safari on Simulator
# {
#   "platformName": "iOS",
#   "appium:automationName": "XCUITest",
#   "appium:deviceName": "MobiSSH_iPhone15",
#   "appium:platformVersion": "17.4",
#   "appium:browserName": "Safari",
#   "appium:noReset": true
# }
```

Advantages over safaridriver:
- Touch gesture support (swipe, pinch, long press)
- Access to native UI elements (keyboard, alerts)
- Screen recording via `mobile: startRecordingScreen`
- Consistent API with our Android Appium tests

**Android comparison:** Our Android setup uses Appium + UiAutomator2. The iOS equivalent is Appium + XCUITest. The Appium server is shared; only the driver changes. This means `scripts/start-appium.sh` could serve both platforms.

## 6. Playwright and Safari on iOS Simulator

### Playwright's WebKit vs. Real Mobile Safari

Playwright's WebKit browser is a desktop build of WebKit, NOT Safari on iOS. Key differences:

- **Playwright WebKit:** Desktop WebKit engine, runs on Linux/macOS/Windows. No iOS-specific behaviors (address bar, safe area insets, virtual keyboard, PWA install prompt).
- **Real Mobile Safari:** iOS WebKit with mobile viewport, touch events, virtual keyboard, `PasswordCredential` restrictions, PWA manifest handling.

For MobiSSH, the gap matters for:
- Virtual keyboard detection (`visualViewport.height`)
- IME input behavior (swipe typing, autocorrect)
- PWA install and home screen behavior
- `PasswordCredential` API absence (issue #14)
- Touch event handling and gesture recognition

### Can Playwright Connect to Safari on Simulator?

**Not directly.** Playwright does not support connecting to Safari on iOS Simulator via CDP or any other protocol. Options:

1. **Playwright WebKit (what we have today):** Tests run against desktop WebKit. Good for basic functional testing, misses iOS-specific behavior. Already runs in our `scripts/test-headless.sh`.

2. **Playwright as test runner + Appium for device control:** Use Playwright's test runner (assertions, fixtures, parallelism) while delegating browser interaction to Appium/WebDriverIO. This is exactly what our `playwright.appium.config.js` does for Android.

3. **WebDriverIO standalone:** Skip Playwright entirely, use WebDriverIO's test runner. Adds another test framework dependency.

**Recommendation:** Mirror the Android approach. Use Playwright as the test runner with Appium+XCUITest for device interaction. The `playwright.appium.config.js` pattern already proves this works.

## 7. Parallel with Android Approach

| Aspect | Android | iOS (proposed) |
|--------|---------|----------------|
| Setup script | `scripts/setup-avd.sh` | `scripts/setup-ios-sim.sh` |
| Emulator tool | `emulator` (Android SDK) | `xcrun simctl` (Xcode) |
| Device profile | Pixel 7, API 35 | iPhone 15, iOS 17.4 |
| Browser | Chrome (Play Store) | Safari (built-in) |
| Port forwarding | `adb reverse tcp:8081 tcp:8081` | Not needed (shared network) |
| Automation | Appium + UiAutomator2 | Appium + XCUITest |
| CDP/DevTools | `adb forward` + Chrome CDP | Safari Web Inspector (via `safaridriver` or Appium) |
| Run script | `scripts/run-appium-tests.sh` | `scripts/run-ios-tests.sh` (future) |
| Test config | `playwright.appium.config.js` | `playwright.ios.config.js` (future) |
| Screen recording | `adb emu screenrecord` | `xcrun simctl io booted recordVideo` |
| Debug overlays | `adb shell settings put system show_touches 1` | Not available natively; Appium logs touch events |
| Host platform | Linux (KVM), macOS | **macOS only** |

### Shared infrastructure
- Appium server (`scripts/start-appium.sh`) could serve both platforms
- Test fixtures could share base logic with platform-specific overrides
- `scripts/server-ctl.sh` and Docker test-sshd work identically

## 8. CI/CD Constraints

### macOS Runners Required

iOS Simulator requires macOS. This affects CI significantly:

| Provider | macOS runner | Cost | Notes |
|----------|-------------|------|-------|
| GitHub Actions | `macos-13`, `macos-14` (M1) | 10x Linux minutes | M1 runners are faster but more expensive |
| Self-hosted Mac | Mac Mini / Mac Studio | One-time hardware | Apple SLA requires macOS on Apple hardware |
| MacStadium / AWS EC2 Mac | Cloud Mac instances | $1-2/hr | Dedicated hardware, not shared |

**Cost comparison:** A typical Appium test run takes 3-5 minutes. On GitHub Actions:
- Linux (Android): 3-5 minutes = 3-5 minutes billed
- macOS (iOS): 3-5 minutes = 30-50 minutes billed (10x multiplier)

### Recommendations for CI
1. **Local-first:** Run iOS Simulator tests locally on macOS dev machines, not in CI initially.
2. **Gate selectively:** Only run iOS tests on PRs that touch iOS-specific code paths.
3. **Self-hosted runner:** If regular iOS CI is needed, a Mac Mini self-hosted runner is most cost-effective.
4. **BrowserStack/Sauce Labs:** Cloud device farms can run iOS Safari tests without local macOS. See `browserstack.yml` for existing config.

## 9. Can iOS Simulator Run on Linux?

**No. iOS Simulator cannot run on Linux.**

This is a hard constraint with no workarounds:
- iOS Simulator requires macOS and the Xcode toolchain
- Apple does not provide any Linux-compatible iOS simulation
- There are no open-source iOS simulators for Linux
- Running macOS in a VM on Linux violates Apple's EULA (and is unreliable for Simulator)

**Alternatives for Linux-based CI:**
- **Playwright WebKit:** Desktop WebKit on Linux covers basic functional testing (already in our CI)
- **BrowserStack/Sauce Labs:** Cloud-based real iOS devices, accessible from any CI platform
- **Corellium:** ARM-based iOS device virtualization (cloud service, expensive)

**This means:** Our current Linux development/CI environment cannot run iOS Simulator tests. iOS Simulator testing is macOS-only and supplements (not replaces) our existing Playwright WebKit tests.

## Summary and Next Steps

1. iOS Simulator testing is feasible but macOS-only, making it a complement to our Linux-based CI.
2. The Appium + XCUITest approach mirrors our Android setup closely, minimizing new code.
3. `scripts/setup-ios-sim.sh` (draft) captures the key CLI commands for macOS setup.
4. Priority: set up local macOS testing first, defer CI integration until test volume justifies the cost.
5. BrowserStack (already partially configured in `browserstack.yml`) is the pragmatic path for cross-platform CI.
