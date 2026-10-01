#!/usr/bin/env bash
# scripts/lib/sftp-cap-proxy.sh — switch a test-sshd container's sftp subsystem
# between the stock internal-sftp and the #1225 READ-capping relay
# (docker/test-sshd/sftp-cap-proxy.py). Sourced by sftp-bytes-1225-setup.sh and
# sftp-bytes-1225-teardown.sh.

SFTPCAP_PROXY_SUBSYSTEM="/usr/bin/python3 /usr/local/bin/sftp-cap-proxy.py"
SFTPCAP_STOCK_SUBSYSTEM="internal-sftp"

# The container behind SSHD_HOST. The runner pins SSHD_HOST to a container name;
# the bare `test-sshd` alias is resolved by IP (the alias may match several
# containers, so it must be the one the bridge actually reaches).
sftpcap_container() {
  local host="${SSHD_HOST:-test-sshd}"
  if docker inspect -f '{{.Id}}' "$host" >/dev/null 2>&1; then
    echo "$host"
    return 0
  fi
  local ip id
  ip="$(getent hosts "$host" | awk '{print $1; exit}')"
  if [[ -z "$ip" ]]; then
    echo "! sftp-cap: ${host} does not resolve" >&2
    return 1
  fi
  for id in $(docker ps -q); do
    if docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$id" \
        | tr ' ' '\n' | grep -qx "$ip"; then
      docker inspect -f '{{.Name}}' "$id" | sed 's|^/||'
      return 0
    fi
  done
  echo "! sftp-cap: no container owns ${host} (${ip})" >&2
  return 1
}

# Set the Subsystem sftp line to $2 in container $1, validate, and HUP sshd so
# NEW sessions use it (live sessions keep theirs).
sftpcap_set_subsystem() {
  local c="$1" value="$2"
  docker exec "$c" sed -i "s|^Subsystem[[:space:]]\{1,\}sftp[[:space:]].*|Subsystem\tsftp\t${value}|" \
    /etc/ssh/sshd_config
  docker exec "$c" grep -E '^Subsystem[[:space:]]+sftp' /etc/ssh/sshd_config
  docker exec "$c" /usr/sbin/sshd -t
  docker exec "$c" sh -c 'kill -HUP "$(pgrep -o sshd)"'
}

# Print every relay session's counters and the capped total; succeeds only when
# at least one READ was capped.
sftpcap_report() {
  local c="$1"
  docker exec "$c" sh -c '
total=0
for f in /tmp/sftp-cap-proxy/*.log; do
  [ -f "$f" ] || continue
  cat "$f"
  n=$(sed -n "s/.*capped=\([0-9]*\).*/\1/p" "$f")
  total=$((total + ${n:-0}))
done
echo "sftp-cap-proxy capped READs total=${total}"
[ "$total" -gt 0 ]
'
}
