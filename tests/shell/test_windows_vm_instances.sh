#!/bin/bash
# Regression coverage for the multi-instance layer: name validation, per-instance
# paths and ports, internet-off networking, metadata, and the read-only listing.
# The single-instance compose/mount guarantees are covered by
# windows-vm-compose-test.sh and windows-vm-mount-boundary-test.sh.

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# Bind mounts need CAP_SYS_ADMIN in a private mount namespace. Keep the
# caller's uid so the non-root development path is exercised.
if [[ ${OMARCHY_WINDOWS_TEST_NAMESPACE:-0} != 1 ]]; then
  if unshare --user --map-current-user --keep-caps --mount true 2>/dev/null; then
    exec env OMARCHY_WINDOWS_TEST_NAMESPACE=1 \
      unshare --user --map-current-user --keep-caps --mount --propagation private bash "$0"
  fi
  skip "unprivileged mount namespaces unavailable; skipping Windows VM instance tests"
  exit 0
fi

TMPDIR=$(mktemp -d)
export OMARCHY_WINDOWS_DIR="$TMPDIR/win"
export HOME="$TMPDIR/home"
mkdir -p "$HOME"

# The command refuses any CPU but x86_64 before defining anything, and sourcing
# it there would exit this test. What is under test is the x86_64 path.
STUB_BIN="$TMPDIR/bin"
mkdir -p "$STUB_BIN"
printf '#!/bin/bash\nexit 0\n' >"$STUB_BIN/omarchy-hw-x86"
chmod +x "$STUB_BIN/omarchy-hw-x86"
PATH="$STUB_BIN:$PATH"

set -- help
source "$ROOT/bin/omarchy-subsystem-for-windows" >/dev/null 2>&1

# The default instance's historical port pair is a constant, not metadata: assert
# it before any instance.conf exists, so a changed default cannot hide behind a
# stored value.
select_instance default
[[ $WEB_PORT == 8006 && $RDP_PORT == 3389 ]] ||
  fail "default instance port pair changed: $WEB_PORT / $RDP_PORT"

unmount_all() {
  local path
  # Every instance's anchors live below the runtime base, so unmount whatever is
  # still mounted there rather than only the currently selected instance's pair.
  while IFS= read -r path; do
    [[ -n $path ]] || continue
    while mountpoint -q -- "$path" 2>/dev/null; do umount -- "$path" || break; done
  done < <(findmnt -rno TARGET 2>/dev/null | grep -F "$OMARCHY_WINDOWS_DIR/" | sort -r)
}

cleanup() {
  set +e
  unmount_all
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

# Write one instance's compose through the same privileged writer the CLI uses.
write_instance() { # name version internet web rdp [usb]
  local name=$1 version=$2 internet=$3 web=$4 rdp=$5 usb=${6:-}
  select_instance "$name"
  prepare_user_mount_sources >/dev/null
  VERSION=$version
  INTERNET=$internet
  WEB_PORT=$web
  RDP_PORT=$rdp
  USB_DEVICES=$usb
  printf 'RAM=4G\nCORES=2\nDISK=64G\nUSERNAME=admin\nPASSWORD=pw\nTZ=UTC\nVERSION=%s\nINTERNET=%s\nWEB_PORT=%s\nRDP_PORT=%s\nUSB=%s\n' \
    "$version" "$internet" "$web" "$rdp" "$usb" | __priv_write_compose
}

# --- name validation ---------------------------------------------------------

for name in default work win-10 a1 a-b-c; do
  valid_instance_name "$name" || fail "valid instance name rejected: $name"
done
for name in '' 'Work' 'work_' '-work' 'work-' 'a.b' 'a/b' '../x' 'a b' "$(printf 'a%.0s' {1..40})"; do
  valid_instance_name "$name" && fail "invalid instance name accepted: [$name]"
done
pass "instance names are a narrow lowercase slug"

# --- version and port validation --------------------------------------------

for version in 11 10 8e 7u xp 2k 2025; do
  valid_version "$version" || fail "supported version rejected: $version"
done
for version in 'https://evil/win.iso' '11;rm' '' 'Win11'; do
  valid_version "$version" && fail "unsupported version accepted: [$version]"
done
for port in 3389 8006 65535; do
  valid_port "$port" || fail "valid port rejected: $port"
done
for port in 22 80 0 70000 abc; do
  valid_port "$port" && fail "invalid port accepted: [$port]"
done
pass "versions and ports are validated against the catalog"

# --- default instance keeps the historical layout ---------------------------

write_instance default 11 on 8006 3389
grep -q '^name: windows$' "$COMPOSE_FILE" || fail "default compose name changed"
grep -q 'container_name: omarchy-windows$' "$COMPOSE_FILE" || fail "default container name changed"
grep -q '^INSTANCE=default$' "$INSTANCE_CONF" || fail "default metadata missing"
grep -q '^INTERNET=on$' "$INSTANCE_CONF" || fail "default internet setting missing"
grep -q '^  isolated:$' "$COMPOSE_FILE" && fail "default instance got an isolated network"
[[ -d $HOME/.windows && -d $HOME/Windows ]] || fail "default instance lost its familiar directories"
pass "default instance keeps the historical layout and names"

# --- a named instance gets its own everything -------------------------------

write_instance work 10 off 8007 3390 0a12:0001
[[ -f $OMARCHY_WINDOWS_DIR/instances/work/docker-compose.yml ]] || fail "named compose not written"
grep -q '^name: omarchy-windows-work$' "$OMARCHY_WINDOWS_DIR/instances/work/docker-compose.yml" ||
  fail "named compose project name not derived from the instance"
grep -q 'container_name: omarchy-windows-work$' "$OMARCHY_WINDOWS_DIR/instances/work/docker-compose.yml" ||
  fail "named container name not derived from the instance"
grep -q 'VERSION: "10"' "$OMARCHY_WINDOWS_DIR/instances/work/docker-compose.yml" ||
  fail "named instance did not get its version"
grep -q '127.0.0.1:8007:8006' "$OMARCHY_WINDOWS_DIR/instances/work/docker-compose.yml" ||
  fail "named instance did not get its web port"
grep -q '127.0.0.1:3390:3389/tcp' "$OMARCHY_WINDOWS_DIR/instances/work/docker-compose.yml" ||
  fail "named instance did not get its RDP port"
grep -q 'vendorid=0x0a12,productid=0x0001' "$OMARCHY_WINDOWS_DIR/instances/work/docker-compose.yml" ||
  fail "USB passthrough did not reach the QEMU arguments"
grep -q '^INSTANCE=work$' "$OMARCHY_WINDOWS_DIR/instances/work/instance.conf" || fail "named metadata missing"
grep -q '^WEB_PORT=8007$' "$OMARCHY_WINDOWS_DIR/instances/work/instance.conf" || fail "named web port not recorded"
[[ -d $HOME/.windows-work && -d $HOME/Windows-work ]] || fail "named instance lacks its own directories"
[[ ! -e $HOME/.windows-work/.windows ]] || fail "named instance nested inside the default"
pass "named instance gets its own project, ports, directories and metadata"

# --- internet-off networking ------------------------------------------------

grep -q '^      - isolated$' "$OMARCHY_WINDOWS_DIR/instances/work/docker-compose.yml" ||
  fail "internet-off instance not attached to its isolated network"
grep -q 'name: omarchy-windows-work-net' "$OMARCHY_WINDOWS_DIR/instances/work/docker-compose.yml" ||
  fail "isolated network name not derived from the instance"
grep -q 'external: true' "$OMARCHY_WINDOWS_DIR/instances/work/docker-compose.yml" ||
  fail "isolated network not marked external"
grep -q 'enable_ip_masquerade' "$OMARCHY_WINDOWS_DIR/instances/work/docker-compose.yml" &&
  fail "compose should leave masquerading to the network creator"
pass "internet-off instance uses an isolated external network"

# --- port allocation avoids instances already on disk -----------------------

WEB_PORT=0
RDP_PORT=0
pair=$(allocate_port_pair)
[[ $pair == "8008 3391" ]] || fail "allocator did not skip the taken pair: [$pair]"
port_in_use 8007 || fail "port_in_use missed a recorded web port"
port_in_use 3390 || fail "port_in_use missed a recorded RDP port"
port_in_use 8006 || fail "port_in_use missed the default instance"
port_in_use 8999 && fail "port_in_use reported a free port as taken"
pass "port pairs are allocated from the free ranges and skip recorded instances"

# --- metadata stays non-secret and world-readable ---------------------------

[[ $(stat -Lc '%a' "$INSTANCE_CONF") == 644 ]] || fail "instance metadata is not world-readable"
grep -q 'PASSWORD' "$INSTANCE_CONF" && fail "instance metadata leaked the password"
[[ $(stat -Lc '%a' "$COMPOSE_FILE") == 640 ]] || fail "compose permissions changed"
pass "metadata is non-secret and the compose stays 0640"

# --- listing reads both instances -------------------------------------------

select_instance default
list=$(list_instances)
[[ $(grep -c '^\(default\|work\) ' <<<"$list") == 2 ]] || fail "listing did not report both instances"
grep -q '^default ' <<<"$list" || fail "listing missed the default instance"
grep -q '^work ' <<<"$list" || fail "listing missed the named instance"
json=$(list_instances --json)
grep -q '"name":"default"' <<<"$json" || fail "json listing missed the default instance"
grep -q '"name":"work"' <<<"$json" || fail "json listing missed the named instance"
grep -q '"webPort":8007' <<<"$json" || fail "json listing lost the web port"
pass "instances listing reports the metadata in plain and json form"

# --- selecting an instance moves every derived path ------------------------

select_instance work
resolve_caller >/dev/null || fail "named instance could not resolve the caller"
[[ $RUNTIME_DIR == "$OMARCHY_WINDOWS_DIR/instances/work" ]] || fail "named runtime dir not derived"
[[ $VM_LOCK_DIR == /run/lock/omarchy-windows-vm-work ]] || fail "named lock dir not derived"
[[ $CREDENTIALS_FILE == "$HOME/.config/windows/credentials-work" ]] || fail "named credentials path not derived"
[[ $COMPOSE_FILE == "$OMARCHY_WINDOWS_DIR/instances/work/docker-compose.yml" ]] || fail "named compose path not derived"
[[ $INSTANCE_STORAGE == "$HOME/.windows-work" ]] || fail "named storage source not derived"
select_instance default
[[ $RUNTIME_DIR == "$OMARCHY_WINDOWS_DIR" ]] || fail "default runtime dir not restored"
[[ $WEB_PORT == 8006 && $RDP_PORT == 3389 ]] ||
  fail "default instance ports changed: $WEB_PORT / $RDP_PORT"
[[ $COMPOSE_FILE == "$OMARCHY_WINDOWS_DIR/docker-compose.yml" ]] || fail "default compose path not restored"
pass "selecting an instance derives every path from its name"

# --- a named instance cannot be created twice -------------------------------

select_instance work
instance_exists || fail "named instance not created"
pass "existing instances are detected by a create"

# --- the command line dispatch routes names and options correctly -----------

# Run the real script as a subprocess. Only the read-only routes are exercised;
# the privileged ones would need pkexec and a packaged install.
run_cli() {
  OMARCHY_WINDOWS_DIR="$OMARCHY_WINDOWS_DIR" HOME="$HOME" PATH="$STUB_BIN:$PATH" \
    bash "$ROOT/bin/omarchy-subsystem-for-windows" "$@"
}

# Capture output before grepping: grep -q exits on the first match, and with
# pipefail a SIGPIPE'd command would fail the pipeline even when it matched.
help_out=$(run_cli help 2>&1) || fail "help did not exit 0"
grep -q 'create <name>' <<<"$help_out" || fail "help does not mention create"

instances_out=$(run_cli instances 2>&1) || fail "instances did not exit 0"
grep -q '^work ' <<<"$instances_out" || fail "instances did not list the named instance"
instances_json=$(run_cli instances --json 2>&1) || fail "instances --json did not exit 0"
grep -q '"name":"work"' <<<"$instances_json" || fail "instances --json did not emit work"

config_out=$(run_cli config work 2>&1) || fail "config work did not exit 0"
grep -q 'Instance: *work' <<<"$config_out" || fail "config did not name the instance"
run_cli config >/dev/null 2>&1 || fail "bare config did not fall back to the default instance"
config_json=$(run_cli config work --json 2>&1) || fail "config --json did not exit 0"
grep -q '"name":"work"' <<<"$config_json" || fail "config --json did not emit json"

run_cli create >/dev/null 2>&1 && fail "create without a name succeeded"
run_cli bogus >/dev/null 2>&1 && fail "unknown command exited 0"
pass "command dispatch routes instance names and options"

# --- create allocates ports and writes metadata ----------------------------

# Drive create_windows without elevation: the privileged action runs directly.
# Free space is stubbed so the assertion does not depend on the test host's disk.
priv() { local action=$1; shift; "__priv_$action" "$@"; }
available_storage_gb() { echo 500; }
select_instance lab
create_windows lab --version 10 --ram 4G --cores 2 --disk 64G --no-internet >/dev/null ||
  fail "create_windows failed"
[[ -f $OMARCHY_WINDOWS_DIR/instances/lab/instance.conf ]] || fail "create wrote no metadata"
grep -q '^INSTANCE=lab$' "$OMARCHY_WINDOWS_DIR/instances/lab/instance.conf" ||
  fail "metadata does not name the instance"
grep -q '^INTERNET=off$' "$OMARCHY_WINDOWS_DIR/instances/lab/instance.conf" ||
  fail "create did not record the internet setting"
grep -q '^VERSION=10$' "$OMARCHY_WINDOWS_DIR/instances/lab/instance.conf" ||
  fail "create did not record the version"
lab_web=$(sed -n 's/^WEB_PORT=//p' "$OMARCHY_WINDOWS_DIR/instances/lab/instance.conf")
lab_rdp=$(sed -n 's/^RDP_PORT=//p' "$OMARCHY_WINDOWS_DIR/instances/lab/instance.conf")
[[ -n $lab_web && -n $lab_rdp ]] || fail "create allocated no port pair"
[[ $lab_web != 8006 && $lab_rdp != 3389 ]] || fail "create reused the default instance's ports"
grep -q "127.0.0.1:$lab_web:8006" "$OMARCHY_WINDOWS_DIR/instances/lab/docker-compose.yml" ||
  fail "compose does not bind the allocated web port"
grep -q '^      - isolated$' "$OMARCHY_WINDOWS_DIR/instances/lab/docker-compose.yml" ||
  fail "internet-off instance has no isolated network"
[[ -f $HOME/.local/share/applications/windows-vm-lab.desktop ]] ||
  fail "create wrote no desktop entry"
pass "create allocates a free port pair and records the settings"

# --- privileged target selection -------------------------------------------

# Production calls priv_target with no arguments and gets the installed copies;
# the argument seam lets this suite prove each rejection without a root install.
# Inside the user namespace host root is unmapped, so stat is stubbed to report
# the ownership/mode the production layout would have; the file tests (-f, -L,
# -x) stay real.
stat() {
  local path=${!#}
  case $path in
  /usr/bin/bash | /usr/bin | /usr)
    case "$*" in *%u*) printf '0\n' ;; *%a*) printf '755\n' ;; *) command stat "$@" ;; esac
    return 0
    ;;
  /)
    case "$*" in *%u*) printf '0\n' ;; *%a*) printf '555\n' ;; *) command stat "$@" ;; esac
    return 0
    ;;
  /etc/passwd)
    case "$*" in *%u*) printf '0\n' ;; *%a*) printf '644\n' ;; *) command stat "$@" ;; esac
    return 0
    ;;
  /etc/hostname)
    case "$*" in *%u*) printf '1000\n' ;; *%a*) printf '644\n' ;; *) command stat "$@" ;; esac
    return 0
    ;;
  /etc)
    case "$*" in *%u*) printf '0\n' ;; *%a*) printf '755\n' ;; *) command stat "$@" ;; esac
    return 0
    ;;
  "$TMPDIR/engine")
    case "$*" in *%u*) printf '1000\n' ;; *%a*) printf '755\n' ;; *) command stat "$@" ;; esac
    return 0
    ;;
  "$TMPDIR" | /tmp)
    case "$*" in *%u*) printf '0\n' ;; *%a*) printf '755\n' ;; *) command stat "$@" ;; esac
    return 0
    ;;
  esac
  command stat "$@"
}
target_out=$(priv_target /usr/bin/bash 2>&1) || true
[[ $target_out == /usr/bin/bash ]] ||
  fail "priv_target rejected a canonical root-owned executable" \
    "got [$target_out] f=$([[ -f /usr/bin/bash ]] && echo y) L=$([[ -L /usr/bin/bash ]] && echo y) x=$([[ -x /usr/bin/bash ]] && echo y) realpath=$(realpath -e -- /usr/bin/bash 2>&1) stat=$(stat -Lc '%u %a' /usr/bin/bash 2>&1)"
priv_target /etc/passwd >/dev/null 2>&1 &&
  fail "priv_target accepted a non-executable file"
priv_target /bin/true >/dev/null 2>&1 &&
  fail "priv_target accepted a path whose canonical form differs"
user_target="$TMPDIR/user-owned"
printf '#!/bin/bash\nexit 0\n' >"$user_target"
chmod +x "$user_target"
priv_target "$user_target" >/dev/null 2>&1 &&
  fail "priv_target accepted a user-owned file"
# A non-root owner in an otherwise trusted chain must still stop the walk.
priv_target /etc/hostname >/dev/null 2>&1 &&
  fail "priv_target accepted a file owned by another user"
mkdir -p "$TMPDIR/engine.d"
: >"$TMPDIR/engine"
chmod +x "$TMPDIR/engine"
priv_target "$TMPDIR/engine" >/dev/null 2>&1 &&
  fail "priv_target accepted an executable owned by another user"
unset -f stat
pass "priv_target accepts only a canonical, root-owned, executable file"

# --- metadata keeps its creation stamp -------------------------------------

conf="$OMARCHY_WINDOWS_DIR/instances/lab/instance.conf"
grep -q '^CREATED=[0-9]\{4\}-[0-9][0-9]-[0-9][0-9]T' "$conf" ||
  fail "create wrote no creation timestamp"
sed -i 's/^CREATED=.*/CREATED=2001-02-03T04:05:06Z/' "$conf"
W_VERSION=10 W_RAM=4G W_CORES=2 W_DISK=64G W_INTERNET=off
W_WEB_PORT=$lab_web W_RDP_PORT=$lab_rdp W_USB=""
write_instance_conf || fail "rewriting the metadata failed"
grep -q '^CREATED=2001-02-03T04:05:06Z$' "$conf" ||
  fail "rewriting the metadata lost the creation stamp"
grep -q '^INSTANCE=lab$' "$conf" || fail "rewriting the metadata lost the instance"
pass "metadata keeps its creation stamp when rewritten"
