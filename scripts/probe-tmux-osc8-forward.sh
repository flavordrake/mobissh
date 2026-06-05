#!/usr/bin/env bash
# End-to-end proof: with the `hyperlinks` feature enabled (via DA2='T'), a
# tmux pane that emits an OSC-8 hyperlink has that hyperlink FORWARDED to the
# client (not stripped). We compare the bytes tmux draws to two clients:
#   - baseline (no DA2 reply)  -> OSC-8 stripped (no "\e]8;" in client stream)
#   - DA2='T' (tmux)           -> OSC-8 present in client stream
set -euo pipefail

PROBE_OUT_DIR="${PROBE_OUT_DIR:-/tmp/mobissh/tmux-probe}"
mkdir -p "$PROBE_OUT_DIR"
LOGFILE="$PROBE_OUT_DIR/osc8.log"
exec > >(tee -a "$LOGFILE") 2>&1

SOCK="osc8probe$$"
cleanup() { tmux -L "$SOCK" kill-server 2>/dev/null || true; }
trap cleanup EXIT

probe() {
  # $1 label, $2 mode(none|tmux)
  tmux -L "$SOCK" kill-server 2>/dev/null || true
  tmux -L "$SOCK" -f /dev/null new-session -d -s s -x 80 -y 24
  local dump="$PROBE_OUT_DIR/osc8-client-$2.bin"
  rm -f "$dump"
  TERM="xterm-256color" SOCK="$SOCK" MODE="$2" DUMP="$dump" python3 - <<'PY'
import os, pty, time, select

sock=os.environ["SOCK"]; mode=os.environ["MODE"]; dump=os.environ["DUMP"]
reply = b"\x1b[>84;0;0c" if mode=="tmux" else None

pid, fd = pty.fork()
if pid==0:
    os.execvp("tmux", ["tmux","-L",sock,"-f","/dev/null","attach","-t","s"])
    os._exit(127)

f=open(dump,"wb"); buf=b""; answered=False; emitted=False
deadline=time.time()+5.0
while time.time()<deadline:
    r,_,_=select.select([fd],[],[],0.1)
    if fd in r:
        try: data=os.read(fd,8192)
        except OSError: break
        if not data: break
        f.write(data); f.flush(); buf+=data
        if reply and not answered and b"\x1b[>c" in buf:
            os.write(fd, reply); answered=True
    # After features are negotiated, emit an OSC-8 link in the pane.
    if not emitted and time.time()>deadline-3.0:
        import subprocess
        subprocess.run(["tmux","-L",sock,"send-keys","-t","s",
            r"printf '\e]8;;https://example.com/x\e\\LINKTEXT\e]8;;\e\\\n'", "Enter"])
        emitted=True
f.close()
PY
  # Did the OSC-8 introducer reach the client?
  local n
  n="$(grep -c $'\x1b]8;' "$dump" 2>/dev/null || true)"
  # grep -c counts lines; use a byte search instead.
  if LC_ALL=C grep -q $'\x1b]8;' "$dump"; then
    printf '%-22s OSC8-forwarded=YES\n' "$1"
  else
    printf '%-22s OSC8-forwarded=NO\n' "$1"
  fi
  tmux -L "$SOCK" kill-server 2>/dev/null || true
}

echo "tmux version: $(tmux -V)"
echo "osc8 forward probe $(date +%Y%m%dT%H%M%S%z)"
probe "baseline(no-DA2)" "none"
probe "DA2=tmux(T)"       "tmux"
echo "osc8 forward done"
