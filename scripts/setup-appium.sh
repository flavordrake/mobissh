#!/usr/bin/env bash
# Appium v2 + UiAutomator2 setup for MobiSSH emulator testing
# Run with: ./scripts/setup-appium.sh   (NOT sudo — script calls sudo internally)
# Idempotent: safe to re-run
# Log: /tmp/setup-appium.log

set -euo pipefail

MOBISSH_TMPDIR="${MOBISSH_TMPDIR:-/tmp/mobissh}"
MOBISSH_LOGDIR="${MOBISSH_LOGDIR:-/tmp/mobissh/logs}"
mkdir -p "$MOBISSH_TMPDIR" "$MOBISSH_LOGDIR"

if [ "$(id -u)" -eq 0 ]; then
  echo "! Do not run this script as root or with sudo."
  echo "  It calls sudo internally for the few commands that need it."
  echo "  Run as your normal user: ./scripts/setup-appium.sh"
  exit 1
fi

LOGFILE="${MOBISSH_LOGDIR}/setup-appium.log"
# Ensure the log file is writable by the current user.
# Previous sudo runs may have left it owned by root.
if [ -f "$LOGFILE" ] && [ ! -w "$LOGFILE" ]; then
  echo "  Log file $LOGFILE not writable (owned by $(stat -c '%U' "$LOGFILE")), resetting"
  sudo rm -f "$LOGFILE"
fi
exec > >(tee -a "$LOGFILE") 2>&1
echo "$(date '+%Y-%m-%d %H:%M:%S') setup-appium.sh started (user=$(whoami))"

# Step 0: System packages (the only things that need root)
echo "Step 0: System packages (sudo required)"

if ! java -version 2>&1 | grep -q '17\.'; then
  echo "  Installing openjdk-17-jdk..."
  sudo apt install -y openjdk-17-jdk
  echo "  Installed: $(java -version 2>&1 | head -1)"
else
  echo "  openjdk-17: $(java -version 2>&1 | head -1)"
fi

if ! git lfs version &>/dev/null; then
  echo "  Installing git-lfs..."
  sudo apt install -y git-lfs
  git lfs install
  echo "  Installed: $(git lfs version)"
else
  echo "  git-lfs: $(git lfs version)"
fi

if ! command -v ffprobe &>/dev/null; then
  echo "  Installing ffmpeg..."
  sudo apt install -y ffmpeg
  echo "  Installed: $(ffprobe -version 2>&1 | head -1)"
else
  echo "  ffprobe: $(ffprobe -version 2>&1 | head -1)"
fi

echo "  System packages OK (no more sudo needed)"

# Step 1: Node.js via nvm
echo "Step 1: Ensure Node.js >= 20 (Appium requires it)"
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
# nvm.sh returns non-zero exit codes during normal operation,
# which kills the script under set -e. Disable temporarily.
set +e
if [ -s "$NVM_DIR/nvm.sh" ]; then
  . "$NVM_DIR/nvm.sh"
else
  echo "  nvm not found, installing..."
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
  . "$NVM_DIR/nvm.sh"
fi
nvm use 20 >/dev/null 2>&1
NVM_RC=$?
set -e
if [ $NVM_RC -ne 0 ]; then
  echo "  Node 20 not available, installing..."
  set +e; nvm install 20; nvm use 20; set -e
fi
if ! node --version &>/dev/null; then
  echo "! Node.js not available after nvm setup. Check nvm installation."
  exit 1
fi
echo "  Using Node $(node --version) from $(which node)"

# Step 2: Environment variables
echo "Step 2: Set environment variables"
ENVFILE="$HOME/.bashrc"
LINES_TO_ADD=(
  'export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64'
  'export ANDROID_HOME=$HOME/Android/Sdk'
  'export PATH=$PATH:$ANDROID_HOME/platform-tools:$ANDROID_HOME/cmdline-tools/latest/bin'
)
for LINE in "${LINES_TO_ADD[@]}"; do
  grep -qxF "$LINE" "$ENVFILE" 2>/dev/null || echo "$LINE" >> "$ENVFILE"
done
echo "  Environment variables in $ENVFILE"

export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
export ANDROID_HOME="$HOME/Android/Sdk"
export PATH=$PATH:$ANDROID_HOME/platform-tools:$ANDROID_HOME/cmdline-tools/latest/bin
echo "  JAVA_HOME=$JAVA_HOME"
echo "  ANDROID_HOME=$ANDROID_HOME"

# Step 3: Appium server
echo "Step 3: Install Appium server (under nvm Node 20)"
if appium --version &>/dev/null; then
  echo "  Already installed: appium $(appium --version) at $(which appium)"
else
  npm install -g appium
  echo "  Installed: appium $(appium --version) at $(which appium)"
fi

# Step 4: UiAutomator2 driver
echo "Step 4: Install UiAutomator2 driver"
if appium driver list --installed 2>&1 | grep -q uiautomator2; then
  echo "  Already installed"
  appium driver list --installed 2>&1 | grep uiautomator2
else
  appium driver install uiautomator2
fi

# Step 5: WebDriverIO client
echo "Step 5: Install WebDriverIO client in project"
cd "$(dirname "$0")/../server"
if grep -q webdriverio package.json 2>/dev/null; then
  echo "  Already in package.json"
else
  npm install --save-dev webdriverio
fi
cd - >/dev/null

# Step 6: Git LFS tracking
echo "Step 6: Configure git-lfs tracking"
if ! git lfs track "test-history/**/*.webm" "test-history/**/*.mp4" 2>&1; then
  echo "  git lfs track failed (may already be configured in .gitattributes)"
fi

# Step 7: Validate
echo "Step 7: Validate (appium driver doctor)"
echo "  Running appium driver doctor uiautomator2..."
DOCTOR_EXIT=0
appium driver doctor uiautomator2 2>&1 || DOCTOR_EXIT=$?
if [ "$DOCTOR_EXIT" -ne 0 ]; then
  echo "  WARNING: doctor exited with code $DOCTOR_EXIT (see issues above)"
  echo "  Some issues may be informational, review the output to decide if action is needed"
fi

echo ""
echo "$(date '+%Y-%m-%d %H:%M:%S') setup-appium.sh finished"
echo "Log saved to: $LOGFILE"
echo ""
echo "To start Appium server:"
echo "  ./scripts/start-appium.sh"
