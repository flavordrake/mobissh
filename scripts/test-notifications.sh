#!/usr/bin/env bash
# scripts/test-notifications.sh -- Send terminal events that trigger notifications
#
# Usage: Run this on a remote host while connected via MobiSSH.
#   ssh host 'bash -s' < scripts/test-notifications.sh
#
# Or paste individual commands into a connected terminal session.
#
# Prerequisites (in MobiSSH settings):
#   1. Enable "Terminal notifications" toggle
#   2. Grant browser notification permission when prompted
#   3. Set "Background only" to OFF if testing while the app is visible
#      (default is ON -- notifications only fire when tab is hidden)

echo "=== MobiSSH Notification Test ==="
echo ""
echo "Sending test events in 3 seconds..."
echo "Switch away from the app NOW if 'background only' is on."
sleep 3

echo ""
echo "1/4: Bell character (\\x07)"
printf '\x07'
sleep 2

echo ""
echo "2/4: OSC 9 -- iTerm2/ConEmu notification"
printf '\x1b]9;OSC9 test: build complete\x07'
sleep 2

echo ""
echo "3/4: OSC 777 -- rxvt-unicode notification"
printf '\x1b]777;notify;Build Server;Compilation finished successfully\x07'
sleep 2

echo ""
echo "4/4: Bell after visible output (tests context line)"
echo "$ make install -- SUCCESS"
printf '\x07'
sleep 1

echo ""
echo "Done. You should have seen 4 notifications."
echo "(If not: check Settings > Terminal notifications is ON,"
echo " Notification permission is granted, and background-only"
echo " is OFF if you stayed on the app.)"
