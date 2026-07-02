#!/usr/bin/env bash
# Shared helpers for the demo scripts.

NAMESPACE="${NAMESPACE:-observability}"

# Colours (disabled when not a TTY).
if [[ -t 1 ]]; then
  RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; BLU=$'\033[36m'; RST=$'\033[0m'
else
  RED=""; GRN=""; YLW=""; BLU=""; RST=""
fi

info()  { echo "${BLU}==>${RST} $*"; }
pass()  { echo "${GRN}  ok${RST}  $*"; }
warn()  { echo "${YLW}  !!${RST}  $*"; }
fail()  { echo "${RED} fail${RST} $*"; }

# Track failures across a script.
FAILS=0
check() { # check "<description>" <command...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; FAILS=$((FAILS+1)); fi
}

# Print a free TCP port on the loopback interface.
free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}

# Run a command against a temporary port-forward on a dynamically chosen local
# port (so concurrent runs / lingering forwards never collide on a fixed port).
# The command reads the chosen local port from $PF_PORT.
#   with_port_forward svc/grafana 80 -- curl -s "localhost:$PF_PORT/api/health"
with_port_forward() {
  local target="$1" remote_port="$2"; shift 2
  [[ "$1" == "--" ]] && shift
  local local_port log pf_pid up=0 rc=0
  local_port="$(free_port)"
  log="$(mktemp)"
  kubectl port-forward -n "$NAMESPACE" "$target" "${local_port}:${remote_port}" >"$log" 2>&1 &
  pf_pid=$!
  # Wait until kubectl reports the tunnel is up (or the process dies).
  for _ in {1..60}; do
    kill -0 "$pf_pid" 2>/dev/null || break
    grep -q "Forwarding from" "$log" 2>/dev/null && { up=1; break; }
    sleep 0.25
  done
  if [[ "$up" -ne 1 ]]; then
    fail "port-forward to $target failed: $(tail -n1 "$log" 2>/dev/null)"
    rc=1
  else
    PF_PORT="$local_port" "$@" || rc=$?
  fi
  kill "$pf_pid" >/dev/null 2>&1 || true
  wait "$pf_pid" 2>/dev/null || true
  rm -f "$log"
  return $rc
}
