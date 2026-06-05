#!/usr/bin/env bash
# Does injecting a tmux('T') DA2 reply work even when xterm's own generic
# reply (>0;0;0c) is ALSO sent? Tests reply ordering, because in MobiSSH the
# real terminal (xterm.dart) will still emit its own >0 reply alongside our
# injected >84 reply. We must know which one tmux honors.
set -euo pipefail

PROBE_OUT_DIR="${PROBE_OUT_DIR:-/tmp/mobissh/tmux-probe}"
mkdir -p "$PROBE_OUT_DIR"
exec > >(tee -a "$PROBE_OUT_DIR/order.log") 2>&1

SOCK="ordprobe$$"
cleanup() { tmux -L "$SOCK" kill-server 2>/dev/null || true; }
trap cleanup EXIT

probe() {
  # $1 label, $2 reply-bytes-hex (sent as a single write in response to >c)
  tmux -L "$SOCK" kill-server 2>/dev/null || true
  tmux -L "$SOCK" -f /dev/null new-session -d -s s -x 80 -y 24
  local resfile="$PROBE_OUT_DIR/ord-feat.txt"; rm -f "$resfile"
  SOCK="$SOCK" REPLYHEX="$2" RESFILE="$resfile" TERM="xterm-256color" python3 - <<'PY'
import os, pty, time, select, subprocess
sock=os.environ["SOCK"]; reply=bytes.fromhex(os.environ["REPLYHEX"]); resfile=os.environ["RESFILE"]
pid,fd=pty.fork()
if pid==0:
    os.execvp("tmux",["tmux","-L",sock,"-f","/dev/null","attach","-t","s"]); os._exit(127)
buf=b""; answered=False; queried=False; deadline=time.time()+4.0
while time.time()<deadline:
    r,_,_=select.select([fd],[],[],0.1)
    if fd in r:
        try: data=os.read(fd,8192)
        except OSError: break
        if not data: break
        buf+=data
        if not answered and b"\x1b[>c" in buf:
            os.write(fd, reply); answered=True
    if not queried and answered:
        time.sleep(0.4)
        out=subprocess.run(["tmux","-L",sock,"list-clients","-F","#{client_termfeatures}"],capture_output=True,text=True)
        open(resfile,"w").write(out.stdout.strip()); queried=True; break
PY
  local feats; feats="$(cat "$resfile" 2>/dev/null || true)"
  [ -z "$feats" ] && feats="(empty)"
  local has="NO"; case ",$feats," in *,hyperlinks,*) has="YES";; esac
  printf '%-34s hyperlinks=%-3s  %s\n' "$1" "$has" "$feats"
  tmux -L "$SOCK" kill-server 2>/dev/null || true
}

# >84 = ESC[>84;0;0c = 1b5b3e38343b303b3063 ; >0 = ESC[>0;0;0c = 1b5b3e303b303b3063
echo "tmux version: $(tmux -V)"
probe "ours-first: >84 then >0"  "1b5b3e38343b303b30631b5b3e303b303b3063"
probe "xterm-first: >0 then >84" "1b5b3e303b303b30631b5b3e38343b303b3063"
probe "only >84"                  "1b5b3e38343b303b3063"
probe "only >0 (xterm default)"   "1b5b3e303b303b3063"
