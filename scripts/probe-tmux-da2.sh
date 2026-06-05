#!/usr/bin/env bash
# Prove that the tmux `hyperlinks` client feature is enabled via the DA2
# (Secondary Device Attributes) auto-detection path, NOT via TERM.
#
# tmux sends a DA2 query (ESC [ > c) to the client at attach. If the client
# replies "\e[>84;...c" (84='T'=tmux) tmux applies its built-in "tmux"
# default-features set, which includes `hyperlinks`. ('M'=77=mintty also does.)
#
# The pty client answers tmux's DA2 query with a chosen reply, polls
# client_termfeatures from inside the same process (so it reads while the
# client is attached), and writes the result to a file.
set -euo pipefail

PROBE_OUT_DIR="${PROBE_OUT_DIR:-/tmp/mobissh/tmux-probe}"
mkdir -p "$PROBE_OUT_DIR"
LOGFILE="$PROBE_OUT_DIR/da2.log"
exec > >(tee -a "$LOGFILE") 2>&1

SOCK="da2probe$$"
cleanup() { tmux -L "$SOCK" kill-server 2>/dev/null || true; }
trap cleanup EXIT

probe() {
  # $1 label, $2 TERM, $3 mode(none|tmux|mintty)
  tmux -L "$SOCK" kill-server 2>/dev/null || true
  tmux -L "$SOCK" -f /dev/null new-session -d -s s -x 80 -y 24
  local resfile="$PROBE_OUT_DIR/feat-$3.txt"
  rm -f "$resfile"
  TERM="$2" SOCK="$SOCK" MODE="$3" RESFILE="$resfile" python3 - <<'PY'
import os, pty, sys, time, select, subprocess

sock = os.environ["SOCK"]; mode = os.environ["MODE"]; resfile = os.environ["RESFILE"]
REPLIES = {"tmux": b"\x1b[>84;0;0c", "mintty": b"\x1b[>77;20000;0c"}
reply = REPLIES.get(mode)

pid, fd = pty.fork()
if pid == 0:
    os.execvp("tmux", ["tmux","-L",sock,"-f","/dev/null","attach","-t","s"])
    os._exit(127)

buf = b""; answered = False; queried = False
deadline = time.time() + 4.0
while time.time() < deadline:
    r,_,_ = select.select([fd], [], [], 0.1)
    if fd in r:
        try:
            data = os.read(fd, 8192)
        except OSError:
            break
        if not data:
            break
        buf += data
        if reply and not answered and b"\x1b[>c" in buf:
            os.write(fd, reply); answered = True
    # Once we've answered (or for none-mode, after 1.5s), read features.
    if not queried and (answered or (mode == "none" and time.time() > deadline-2.5)):
        time.sleep(0.4)  # let tmux process the reply
        out = subprocess.run(
            ["tmux","-L",sock,"list-clients","-F","#{client_termfeatures}"],
            capture_output=True, text=True)
        with open(resfile, "w") as f:
            f.write(out.stdout.strip())
        queried = True
        break
# detach
try:
    os.write(fd, b"\x1b")  # nudge
except OSError:
    pass
PY
  local feats
  feats="$(cat "$resfile" 2>/dev/null | tail -1 || true)"
  tmux -L "$SOCK" kill-server 2>/dev/null || true
  [ -z "$feats" ] && feats="(empty)"
  local has="NO"
  case ",$feats," in *,hyperlinks,*) has="YES" ;; esac
  printf '%-30s hyperlinks=%-3s  %s\n' "$1" "$has" "$feats"
}

echo "tmux version: $(tmux -V)"
echo "da2 probe started $(date +%Y%m%dT%H%M%S%z)"
probe "xterm256 no-DA2-reply" "xterm-256color" "none"
probe "xterm256 DA2=tmux(T)"  "xterm-256color" "tmux"
probe "xterm256 DA2=mintty(M)" "xterm-256color" "mintty"
echo "da2 probe done"
