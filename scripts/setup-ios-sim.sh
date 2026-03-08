#!/usr/bin/env bash
# scripts/setup-ios-sim.sh -- Set up iOS Simulator for MobiSSH testing
#
# DRAFT: Key commands and TODOs for iOS Simulator testing on macOS.
# This script is the iOS parallel to scripts/setup-avd.sh (Android).
#
# Prerequisites: macOS, Xcode installed (full, not just CLI tools)
# Usage: ./scripts/setup-ios-sim.sh
# Log: $MOBISSH_LOGDIR/setup-ios-sim.log
#
# NOTE: iOS Simulator CANNOT run on Linux. This script is macOS-only.

set -euo pipefail

MOBISSH_TMPDIR="${MOBISSH_TMPDIR:-/tmp/mobissh}"
MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$MOBISSH_TMPDIR" "$MOBISSH_LOGDIR"
SETUP_LOG="${MOBISSH_LOGDIR}/setup-ios-sim.log"
exec > >(tee -a "$SETUP_LOG") 2>&1
echo "$(date '+%Y-%m-%d %H:%M:%S') setup-ios-sim.sh started"

SIM_NAME="MobiSSH_iPhone15"
# TODO: Update these when targeting newer iOS versions
IOS_RUNTIME="com.apple.CoreSimulator.SimRuntime.iOS-17-4"
DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-15"
MOBISSH_PORT="${MOBISSH_PORT:-8081}"
APPIUM_PORT="${APPIUM_PORT:-4723}"

log() { echo "> $*"; }
ok()  { echo "+ $*"; }
err() { echo "! $*" >&2; exit 1; }

# Step 0: Platform check
if [[ "$(uname -s)" != "Darwin" ]]; then
  err "iOS Simulator requires macOS. This script cannot run on $(uname -s)."
fi

# Step 1: Verify Xcode installation
log "Step 1: Verify Xcode"
if ! xcode-select -p &>/dev/null; then
  err "Xcode not installed. Install from the Mac App Store, then run: sudo xcode-select -s /Applications/Xcode.app"
fi

XCODE_PATH=$(xcode-select -p)
log "Xcode developer path: $XCODE_PATH"

# Verify xcrun simctl is available
if ! xcrun simctl help &>/dev/null; then
  err "xcrun simctl not available. Ensure Xcode (not just CLI tools) is installed."
fi
ok "xcrun simctl available"

# Step 2: Check for iOS runtime
log "Step 2: Check iOS runtime"
if ! xcrun simctl list runtimes | grep -q "iOS 17"; then
  log "iOS 17 runtime not found. Attempting to download..."
  # TODO: This requires Xcode 15+. Adjust runtime version as needed.
  xcodebuild -downloadPlatform iOS
  log "Download complete. Verify with: xcrun simctl list runtimes"
fi

# List available runtimes for reference
xcrun simctl list runtimes

# Step 3: Create simulator if it doesn't exist
log "Step 3: Create simulator"
if xcrun simctl list devices | grep -q "$SIM_NAME"; then
  ok "Simulator '$SIM_NAME' already exists"
else
  log "Creating simulator: $SIM_NAME ($DEVICE_TYPE, $IOS_RUNTIME)..."
  SIM_UUID=$(xcrun simctl create "$SIM_NAME" "$DEVICE_TYPE" "$IOS_RUNTIME")
  ok "Simulator created: $SIM_NAME (UUID: $SIM_UUID)"
fi

# Step 4: Boot simulator (headless, no Simulator.app window)
log "Step 4: Boot simulator"
SIM_STATE=$(xcrun simctl list devices | grep "$SIM_NAME" | head -1)
if echo "$SIM_STATE" | grep -q "Booted"; then
  ok "Simulator already booted"
else
  xcrun simctl boot "$SIM_NAME"
  ok "Simulator booted (headless)"
fi

# Step 5: Verify network access
# iOS Simulator shares the host network. No port forwarding needed.
log "Step 5: Verify network (no port forwarding needed)"
log "iOS Simulator shares host network stack."
log "localhost:$MOBISSH_PORT on host is directly accessible from Simulator Safari."
# TODO: Add a curl check here once MobiSSH server is running

# Step 6: Open MobiSSH in Safari
log "Step 6: Open URL in Simulator Safari"
xcrun simctl openurl booted "http://localhost:$MOBISSH_PORT"
ok "Opened http://localhost:$MOBISSH_PORT in Simulator Safari"

# Step 7: Enable Safari Web Inspector
log "Step 7: Safari Web Inspector setup"
log "To enable remote debugging:"
log "  1. On Simulator: Settings > Safari > Advanced > Web Inspector = ON"
log "  2. On host Mac: Safari > Settings > Advanced > 'Show features for web developers'"
log "  3. On host Mac: Safari > Develop menu > Simulator device > page"
# TODO: Automate this with defaults(1) if possible:
#   xcrun simctl spawn booted defaults write com.apple.Safari WebKitDeveloperExtrasEnabledPreferenceKey -bool true
#   xcrun simctl spawn booted defaults write com.apple.Safari IncludeInternalDebugMenu -bool true

# Step 8: Install Appium + XCUITest driver
log "Step 8: Appium + XCUITest"
if command -v appium &>/dev/null; then
  ok "Appium already installed: $(appium --version)"
else
  log "Installing Appium..."
  npm install -g appium
  ok "Appium installed: $(appium --version)"
fi

if appium driver list --installed 2>&1 | grep -q xcuitest; then
  ok "XCUITest driver already installed"
else
  log "Installing XCUITest driver..."
  appium driver install xcuitest
  ok "XCUITest driver installed"
fi

# TODO: Run appium driver doctor xcuitest to validate setup

# Step 9: Enable safaridriver (alternative to Appium for simple tests)
log "Step 9: safaridriver"
if [[ -x /usr/bin/safaridriver ]]; then
  log "safaridriver found at /usr/bin/safaridriver"
  log "Enable with: safaridriver --enable (requires admin password)"
  # TODO: Check if already enabled; safaridriver --enable is idempotent but prompts for password
else
  log "safaridriver not found (expected on macOS)"
fi

# Step 10: Screen recording setup
log "Step 10: Screen recording"
log "Record Simulator screen with:"
log "  xcrun simctl io booted recordVideo output.mp4"
log "  # Press Ctrl+C to stop recording"
log ""
log "Take screenshot with:"
log "  xcrun simctl io booted screenshot screenshot.png"

# Summary
echo ""
echo "$(date '+%Y-%m-%d %H:%M:%S') setup-ios-sim.sh finished"
echo "Log saved to: $SETUP_LOG"
echo ""
echo "Simulator: $SIM_NAME"
echo ""
echo "Useful commands:"
echo "  xcrun simctl boot '$SIM_NAME'              # Boot (headless)"
echo "  open -a Simulator                           # Open Simulator GUI"
echo "  xcrun simctl openurl booted 'http://localhost:$MOBISSH_PORT'  # Open in Safari"
echo "  xcrun simctl io booted recordVideo out.mp4  # Record screen"
echo "  xcrun simctl io booted screenshot shot.png  # Screenshot"
echo "  xcrun simctl shutdown '$SIM_NAME'           # Shutdown"
echo "  xcrun simctl erase '$SIM_NAME'              # Reset to clean state"
echo "  xcrun simctl delete '$SIM_NAME'             # Delete simulator"
echo ""
echo "Appium capabilities for Safari on this Simulator:"
echo '  {'
echo '    "platformName": "iOS",'
echo '    "appium:automationName": "XCUITest",'
echo "    \"appium:deviceName\": \"$SIM_NAME\","
echo '    "appium:platformVersion": "17.4",'
echo '    "appium:browserName": "Safari",'
echo '    "appium:noReset": true'
echo '  }'
echo ""
echo "TODO: Create scripts/run-ios-tests.sh (parallel to scripts/run-appium-tests.sh)"
echo "TODO: Create playwright.ios.config.js (parallel to playwright.appium.config.js)"
