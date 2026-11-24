#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command python3

test_dir=$(mktemp -d)
server_pids=()
cleanup() {
  (( ${#server_pids[@]} > 0 )) && kill "${server_pids[@]}" 2>/dev/null
  rm -rf "$test_dir"
}
trap cleanup EXIT

source "$ROOT/bin/omarchy-subsystem-for-windows" help >/dev/null 2>&1

# Answers the probe the way each real counterparty does. docker-proxy accepts
# the connection and says nothing, which is the case a bare TCP connect got
# wrong; a live guest sends an X.224 Connection Confirm, and a guest refusing
# negotiation answers with the error code 0x7f in that byte.
cat >"$test_dir/server.py" <<'PY'
import os, socket, sys, time

mode, portfile, requestfile = sys.argv[1:4]
server = socket.socket()
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", 0))
server.listen(1)
tmp = portfile + ".tmp"
with open(tmp, "w") as f:
  f.write(str(server.getsockname()[1]))
os.replace(tmp, portfile)

conn, _ = server.accept()
conn.settimeout(2)
data = b""
deadline = time.time() + 2
while len(data) < 19 and time.time() < deadline:
  try:
    chunk = conn.recv(19 - len(data))
  except socket.timeout:
    break
  if not chunk:
    break
  data += chunk
with open(requestfile, "w") as f:
  f.write(data.hex())

if mode == "confirm":
  # TPKT 03 00 00 13, X.224 CC 0e d0 …, then the RDP negotiation response.
  conn.sendall(bytes([3, 0, 0, 19, 0x0e, 0xd0, 0, 0, 0x12, 0x34, 0, 8, 0, 3, 0, 0, 0, 0, 0]))
elif mode == "refuse":
  conn.sendall(bytes([3, 0, 0, 19, 0x0e, 0x7f, 0, 0, 0x12, 0x34, 0, 8, 0, 0, 0, 0, 0, 0, 0]))
else:
  time.sleep(5)
conn.close()
server.close()
PY

# start_server <mode>: sets portfile/pid for the case that follows.
start_server() {
  local mode="$1" name="$2"
  portfile="$test_dir/$name.port"
  requestfile="$test_dir/$name.request"
  python3 "$test_dir/server.py" "$mode" "$portfile" "$requestfile" &
  server_pids+=("$!")
  for _ in {1..100}; do
    [[ -s $portfile ]] && return 0
    sleep 0.05
  done
  fail "the $name RDP counterparty started listening"
}

# The exact Connection Request the probe must send: TPKT, X.224 CR, and the RDP
# negotiation request offering TLS, CredSSP and RDP security.
expected_request="030000130ee000000000000100080003000000"

start_server confirm confirmed
if ! rdp_confirm "$(<"$portfile")"; then
  fail "a guest that answers with a Connection Confirm counts as ready"
fi
pass "a guest that answers with a Connection Confirm counts as ready"
[[ $(<"$requestfile") == "$expected_request" ]] ||
  fail "the probe sends a well-formed X.224 Connection Request" "sent: $(<"$requestfile")"
pass "the probe sends a well-formed X.224 Connection Request"

start_server silent proxied
if rdp_confirm "$(<"$portfile")"; then
  fail "a listener that accepts but never answers is not ready" "docker-proxy alone must not count as a ready guest"
fi
pass "a listener that accepts but never answers is not ready"

start_server refuse refusing
if rdp_confirm "$(<"$portfile")"; then
  fail "a guest that refuses RDP negotiation is not ready"
fi
pass "a guest that refuses RDP negotiation is not ready"

closed_port=$(python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()')
if rdp_confirm "$closed_port"; then
  fail "a closed port is not ready"
fi
pass "a closed port is not ready"
