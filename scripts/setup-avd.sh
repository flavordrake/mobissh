#!/usr/bin/env bash
# scripts/setup-avd.sh — Set up Android emulator for MobiSSH testing
#
# Installs SDK cmdline-tools, platform-tools, emulator, and creates
# a Pixel 7 AVD with Google Play (for real Chrome + WebAuthn testing).
#
# Prerequisites: android-studio snap, KVM enabled
# Usage: bash scripts/setup-avd.sh

set -euo pipefail

ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
CMDLINE_TOOLS_URL="https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
JAVA_HOME="/snap/android-studio/current/jbr"
AVD_NAME="MobiSSH_Pixel7"
SYSTEM_IMAGE="system-images;android-35;google_apis_playstore;x86_64"
DEVICE_PROFILE="pixel_7"

export ANDROID_HOME JAVA_HOME
export PATH="$JAVA_HOME/bin:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"

log() { printf '\033[36m> %s\033[0m\n' "$*"; }
err() { printf '\033[31m! %s\033[0m\n' "$*" >&2; exit 1; }

# Sanity checks
[[ -f "$JAVA_HOME/bin/java" ]] || err "Java not found at $JAVA_HOME/bin/java (is android-studio snap installed?)"
[[ -e /dev/kvm ]] || err "KVM not available. Enable hardware virtualization in BIOS."

# 1. Install cmdline-tools if missing
if ! command -v sdkmanager &>/dev/null; then
  log "Downloading Android SDK cmdline-tools..."
  mkdir -p "$ANDROID_HOME/cmdline-tools"
  tmp=$(mktemp -d)
  curl -fsSL "$CMDLINE_TOOLS_URL" -o "$tmp/cmdline-tools.zip"
  unzip -q "$tmp/cmdline-tools.zip" -d "$tmp"
  mv "$tmp/cmdline-tools" "$ANDROID_HOME/cmdline-tools/latest"
  rm -rf "$tmp"
  log "cmdline-tools installed to $ANDROID_HOME/cmdline-tools/latest"
fi

# Re-export PATH after install
export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"

# 2. Accept licenses
log "Accepting SDK licenses..."
yes | sdkmanager --licenses >/dev/null 2>&1 || true

# 3. Install SDK components
log "Installing SDK components (emulator, platform-tools, system image)..."
sdkmanager --install \
  "platform-tools" \
  "emulator" \
  "platforms;android-35" \
  "$SYSTEM_IMAGE"

# 4. Create AVD if it doesn't exist
if ! avdmanager list avd -c 2>/dev/null | grep -q "^${AVD_NAME}$"; then
  log "Creating AVD: $AVD_NAME ($DEVICE_PROFILE, API 35, Google Play)..."
  echo "no" | avdmanager create avd \
    --name "$AVD_NAME" \
    --package "$SYSTEM_IMAGE" \
    --device "$DEVICE_PROFILE" \
    --force
  log "AVD created."
else
  log "AVD $AVD_NAME already exists, skipping creation."
fi

# 5. Patch AVD config for better performance
# AVD config uses " = " (with spaces) as separator. Match both formats.
AVD_INI="$HOME/.android/avd/${AVD_NAME}.avd/config.ini"
set_avd_prop() {
  local key="$1" val="$2"
  if grep -q "^${key}" "$AVD_INI" 2>/dev/null; then
    sed -i "s|^${key}.*|${key} = ${val}|" "$AVD_INI"
  else
    echo "${key} = ${val}" >> "$AVD_INI"
  fi
}
if [[ -f "$AVD_INI" ]]; then
  log "Tuning AVD config..."
  set_avd_prop hw.ramSize 4096
  set_avd_prop vm.heapSize 576
  set_avd_prop hw.gpu.enabled yes
  set_avd_prop hw.gpu.mode auto
  set_avd_prop hw.keyboard yes
fi

# 6. Write helper scripts
LAUNCH_SCRIPT="$ANDROID_HOME/launch-mobissh-avd.sh"
cat > "$LAUNCH_SCRIPT" <<'LAUNCH'
#!/usr/bin/env bash
# Launch the MobiSSH test emulator and set up port forwarding.
# Usage: bash ~/Android/Sdk/launch-mobissh-avd.sh

set -euo pipefail

ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
export PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"

AVD_NAME="MobiSSH_Pixel7"
MOBISSH_PORT="${MOBISSH_PORT:-8080}"

echo "> Starting emulator ($AVD_NAME)..."
emulator -avd "$AVD_NAME" -no-snapshot-save -gpu auto &
EMU_PID=$!

echo "> Waiting for device to boot..."
adb wait-for-device
adb shell 'while [[ "$(getprop sys.boot_completed)" != "1" ]]; do sleep 1; done'
echo "> Device booted."

# Port-forward so emulator's localhost:8080 -> host's localhost:8080
adb reverse tcp:$MOBISSH_PORT tcp:$MOBISSH_PORT
echo "> Port forwarded: emulator localhost:$MOBISSH_PORT -> host localhost:$MOBISSH_PORT"
echo "> Open Chrome on emulator and navigate to http://localhost:$MOBISSH_PORT"
echo ""
echo "Useful commands:"
echo "  adb emu finger touch 1     # simulate fingerprint (for WebAuthn biometric)"
echo "  adb shell input text 'url' # type text"
echo "  adb logcat -s chromium     # Chrome logs"
echo "  kill $EMU_PID              # stop emulator"
echo ""

wait $EMU_PID
LAUNCH
chmod +x "$LAUNCH_SCRIPT"

# 7. Add env vars to shell profile if not already there
SHELL_RC="$HOME/.bashrc"
if ! grep -q 'ANDROID_HOME' "$SHELL_RC" 2>/dev/null; then
  log "Adding ANDROID_HOME to $SHELL_RC..."
  cat >> "$SHELL_RC" <<PROFILE

# Android SDK (added by mobissh setup-avd.sh)
export ANDROID_HOME="$ANDROID_HOME"
export PATH="\$ANDROID_HOME/cmdline-tools/latest/bin:\$ANDROID_HOME/platform-tools:\$ANDROID_HOME/emulator:\$PATH"
PROFILE
fi

log "Setup complete."
echo ""
echo "To launch the emulator:"
echo "  bash $LAUNCH_SCRIPT"
echo ""
echo "Or manually:"
echo "  source ~/.bashrc"
echo "  emulator -avd $AVD_NAME &"
echo "  adb reverse tcp:8080 tcp:8080"
echo "  # Then open http://localhost:8080 in Chrome on emulator"
