# docker/emulator/Dockerfile — dedicated Android-emulator sibling container.
#
# WHY: the emulator used to run as a PROCESS inside fd-dev (the coding-agent
# container). When swiftshader (software GPU) crashed under Gradle render/CPU
# load it left hundreds of zombie processes in fd-dev (PID 1 doesn't reap them)
# and could only be reset by restarting fd-dev — which kills the coding session.
# Moving it to its own container isolates the crashes/zombies: recovery is just
# `docker restart mobissh-emulator`, no session loss.
#
# The image bakes a FRESH AVD (MobiSSH_Pixel7, android-35) so it does NOT depend
# on fd-dev's /opt/android-sdk (5.9G, not host-mountable). The build is large and
# slow — the system image alone is ~1.5G.
FROM ubuntu:24.04

# Non-interactive apt for the image build.
ENV DEBIAN_FRONTEND=noninteractive

# Runtime libs the qemu emulator + swiftshader need even headless (-no-window),
# plus the toolchain (jre, wget/unzip for the SDK, socat for the test-sshd bridge).
# libasound2t64 is Ubuntu 24.04 (noble)'s renamed libasound2.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      openjdk-17-jre-headless \
      wget \
      unzip \
      ca-certificates \
      socat \
      libpulse0 \
      libnss3 \
      libxcb1 \
      libx11-6 \
      libxcursor1 \
      libxdamage1 \
      libxext6 \
      libxfixes3 \
      libxi6 \
      libxtst6 \
      libxrender1 \
      libxrandr2 \
      libxcomposite1 \
      libgl1 \
      libglx-mesa0 \
      libegl1 \
      libgles2 \
      libgl1-mesa-dri \
      libgbm1 \
      mesa-vulkan-drivers \
      libvulkan1 \
      vulkan-tools \
      libasound2t64 \
      libpulse-mainloop-glib0 \
      libnspr4 \
      libdbus-1-3 \
      procps \
 && rm -rf /var/lib/apt/lists/*

# Android SDK layout matches fd-dev (/opt/android-sdk) so paths are familiar.
ENV ANDROID_SDK_ROOT=/opt/android-sdk
ENV ANDROID_HOME=/opt/android-sdk
ENV ANDROID_AVD_HOME=/root/.android/avd
ENV PATH=${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin:${ANDROID_SDK_ROOT}/platform-tools:${ANDROID_SDK_ROOT}/emulator:${PATH}

# cmdline-tools (12.0, matches fd-dev's Pkg.Revision). Google ships them under a
# top-level `cmdline-tools/` dir; sdkmanager expects them at
# cmdline-tools/latest/, so relocate after unzip.
ARG CMDLINE_TOOLS_ZIP=commandlinetools-linux-11076708_latest.zip
RUN mkdir -p ${ANDROID_SDK_ROOT}/cmdline-tools \
 && wget -q "https://dl.google.com/android/repository/${CMDLINE_TOOLS_ZIP}" -O /tmp/cmdline-tools.zip \
 && unzip -q /tmp/cmdline-tools.zip -d ${ANDROID_SDK_ROOT}/cmdline-tools \
 && mv ${ANDROID_SDK_ROOT}/cmdline-tools/cmdline-tools ${ANDROID_SDK_ROOT}/cmdline-tools/latest \
 && rm -f /tmp/cmdline-tools.zip

# Accept licenses, then install platform-tools (adb), the emulator, the platform,
# and the x86_64 google_apis system image (~1.5G — the slow part of the build).
RUN yes | sdkmanager --licenses > /dev/null \
 && sdkmanager \
      "platform-tools" \
      "emulator" \
      "platforms;android-35" \
      "system-images;android-35;google_apis;x86_64"

# Create the AVD fresh in the image (device pixel_7, matching the fd-dev AVD).
# `echo no` declines the "custom hardware profile" prompt.
RUN echo "no" | avdmanager create avd \
      -n MobiSSH_Pixel7 \
      -k "system-images;android-35;google_apis;x86_64" \
      -d pixel_7 \
      --force

# Headless Xorg for the `-gpu host` path (the emulator's host GL renderer is
# GLX/X11 and needs a DISPLAY). Separate late layer so it does NOT invalidate
# the cached ~1.5G system-image download above. modesetting (built into
# xserver-xorg-core) drives modern Intel; mesa-utils gives glxinfo for the probe.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      xserver-xorg-core \
      xserver-xorg-legacy \
      xinit \
      x11-xserver-utils \
      xauth \
      mesa-utils \
 && rm -rf /var/lib/apt/lists/*

# Headless-Xorg configs for the -gpu host path (see entrypoint start_xorg).
COPY xorg-headless.conf /etc/X11/xorg-headless.conf
COPY Xwrapper.config /etc/X11/Xwrapper.config

COPY entrypoint.sh /usr/local/bin/emulator-entrypoint.sh
RUN chmod +x /usr/local/bin/emulator-entrypoint.sh

# adb server (5037), exposed guest adbd (5556 → guest 5555), and the in-emulator
# test-sshd bridge port (2222) are reached over the mobissh Docker network by DNS
# name (no host -p mapping in this env). 5554/5555 are the emulator's own
# console/adbd (internal); 5556 is the network-exposed adbd for `adb connect`.
EXPOSE 5037 2222 5554 5555 5556

# Tunables (override in docker-compose.emulator.yml or `docker run -e`):
#   EMU_MEMORY_MB  guest RAM (default 6144)
#   EMU_GPU        swiftshader_indirect (default, software) | host (needs /dev/dri)
#   EMU_CORES      optional taskset core pin (e.g. "0-3"); empty = no pin
ENV EMU_MEMORY_MB=6144
ENV EMU_GPU=swiftshader_indirect
ENV EMU_CORES=

ENTRYPOINT ["/usr/local/bin/emulator-entrypoint.sh"]
