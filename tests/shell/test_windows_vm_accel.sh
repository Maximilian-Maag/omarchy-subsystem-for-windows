#!/bin/bash
# Regression coverage for hardware acceleration plumbing and the --install
# command: CPU acceleration is KVM host passthrough and always on, GPU and audio
# are opt-in toggles that must reach the compose, and installing a Windows
# program must stage the file where the guest can reach it and drive the guest
# through RDP.

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# Bind mounts need CAP_SYS_ADMIN in a private mount namespace. Keep the caller's
# uid so the non-root development path is exercised.
if [[ ${OMARCHY_WINDOWS_TEST_NAMESPACE:-0} != 1 ]]; then
  if unshare --user --map-current-user --keep-caps --mount true 2>/dev/null; then
    exec env OMARCHY_WINDOWS_TEST_NAMESPACE=1 \
      unshare --user --map-current-user --keep-caps --mount --propagation private bash "$0"
  fi
  skip "unprivileged mount namespaces unavailable; skipping acceleration tests"
  exit 0
fi

TMPDIR=$(mktemp -d)
export OMARCHY_WINDOWS_DIR="$TMPDIR/win"
export HOME="$TMPDIR/home"
mkdir -p "$HOME"

STUB_BIN="$TMPDIR/bin"
mkdir -p "$STUB_BIN"
printf '#!/bin/bash\nexit 0\n' >"$STUB_BIN/omarchy-hw-x86"
printf '#!/bin/bash\nexit 0\n' >"$STUB_BIN/ss"
chmod +x "$STUB_BIN/omarchy-hw-x86" "$STUB_BIN/ss"
PATH="$STUB_BIN:$PATH"

set -- help
source "$ROOT/bin/omarchy-subsystem-for-windows" >/dev/null 2>&1

unmount_all() {
  local path
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

# Drive the privileged actions in-process: the installed copy is root-owned and
# would otherwise route through pkexec. Bring-up and shutdown are stubbed to
# succeed: a real up_wait polls Docker for two minutes and there is no VM here.
priv() {
  local action=$1
  shift
  case $action in
  up_wait | up | down) return 0 ;;
  esac
  "__priv_$action" "$@"
}
available_storage_gb() { echo 500; }
printf '#!/bin/bash\nprintf "%%s\\n" "$@"\n' >"$STUB_BIN/gum"
chmod +x "$STUB_BIN/gum"

# --- the toggles validate strictly -----------------------------------------

for value in on off; do
  valid_toggle "$value" || fail "valid toggle rejected: $value"
done
for value in ON yes true 1 '' off-on; do
  valid_toggle "$value" && fail "invalid toggle accepted: [$value]"
done
pass "acceleration toggles accept only on and off"

# --- acceleration reaches the compose --------------------------------------

select_instance accel
create_windows accel --version 11 --ram 4G --cores 2 --disk 64G --gpu --audio >/dev/null ||
  fail "create with --gpu --audio failed"
conf="$OMARCHY_WINDOWS_DIR/instances/accel/instance.conf"
compose="$OMARCHY_WINDOWS_DIR/instances/accel/docker-compose.yml"
grep -q '^GPU=on$' "$conf" || fail "metadata does not record GPU acceleration"
grep -q '^AUDIO=on$' "$conf" || fail "metadata does not record audio acceleration"
grep -q '^      GPU: "Y"$' "$compose" || fail "compose does not enable GPU acceleration"
grep -q '^      AUDIO: "Y"$' "$compose" || fail "compose does not enable audio"
grep -q '^      - /dev/dri$' "$compose" || fail "compose does not hand over the render node"
# CPU acceleration is not a toggle: KVM is always passed through.
grep -q '^      - /dev/kvm$' "$compose" || fail "compose does not pass /dev/kvm"
pass "GPU and audio acceleration reach the compose"

# --- a VM without the toggles stays unaccelerated --------------------------

select_instance plain
create_windows plain --version 11 --ram 4G --cores 2 --disk 64G >/dev/null ||
  fail "create without acceleration flags failed"
plain_conf="$OMARCHY_WINDOWS_DIR/instances/plain/instance.conf"
plain_compose="$OMARCHY_WINDOWS_DIR/instances/plain/docker-compose.yml"
grep -q '^GPU=off$' "$plain_conf" || fail "GPU should default to off"
grep -q '^AUDIO=off$' "$plain_conf" || fail "audio should default to off"
grep -q 'GPU:' "$plain_compose" && fail "compose enables GPU without being asked"
grep -q 'AUDIO:' "$plain_compose" && fail "compose enables audio without being asked"
grep -q '/dev/dri' "$plain_compose" && fail "compose passes the render node without being asked"
pass "acceleration stays off unless requested"

# --- config can flip acceleration afterwards -------------------------------

select_instance accel
config_windows gpu=off >/dev/null || fail "config gpu=off failed"
grep -q '^GPU=off$' "$conf" || fail "config did not record the GPU change"
grep -q 'GPU:' "$compose" && fail "compose still enables GPU after gpu=off"
pass "config can turn acceleration off"

# --- the installer is validated before it is staged ------------------------

not_pe="$TMPDIR/notes.txt"
printf 'this is not an installer\n' >"$not_pe"
valid_installer "$not_pe" && fail "a text file was accepted as an installer"
valid_installer "$TMPDIR/missing.exe" && fail "a missing file was accepted as an installer"
pe="$TMPDIR/setup.exe"
printf 'MZ\x90\x00' >"$pe"
dd if=/dev/zero bs=1 count=64 >>"$pe" 2>/dev/null
valid_installer "$pe" || fail "a PE executable was rejected"
msi="$TMPDIR/setup.msi"
printf '\xd0\xcf\x11\xe0' >"$msi"
dd if=/dev/zero bs=1 count=64 >>"$msi" 2>/dev/null
valid_installer "$msi" || fail "an MSI database was rejected"
pass "installer magic is checked, not the file extension"

# --- install stages the file and drives the guest over RDP -----------------

# Capture what the client would send to the guest, then exit as a closed window
# would. The client takes its arguments on stdin (/args-from:stdin).
printf '#!/bin/bash\ncat >"%s/xfreerdp-args"\nexit 0\n' "$TMPDIR" >"$STUB_BIN/xfreerdp3"
chmod +x "$STUB_BIN/xfreerdp3"

select_instance plain
install_out=$(install_exe "$pe" "" false false 2>&1) ||
  fail "install_exe failed for a PE executable: [$install_out]"
shared="$HOME/Windows-plain"
[[ -f $shared/setup.exe ]] || fail "installer was not staged in the shared folder"
cmp -s "$pe" "$shared/setup.exe" || fail "staged installer differs from the source"
grep -qxF '/shell:"\\host.lan\Data\setup.exe"' "$TMPDIR/xfreerdp-args" ||
  fail "the guest was not told to run the staged installer: [$(tr '\n' ' ' <"$TMPDIR/xfreerdp-args")]"
grep -q '^/v:127\.0\.0\.1:' "$TMPDIR/xfreerdp-args" || fail "the client was not pointed at the VM"
pass "install stages the file and runs it through the guest's RDP session"

# An MSI goes through msiexec, and --args is appended verbatim.
select_instance plain
install_exe "$msi" "/qn" false false >/dev/null 2>&1 ||
  fail "install_exe failed for an MSI"
grep -qxF '/shell:msiexec /i "\\host.lan\Data\setup.msi" /qn' "$TMPDIR/xfreerdp-args" ||
  fail "MSI install did not build a msiexec command: [$(tr '\n' ' ' <"$TMPDIR/xfreerdp-args")]"
pass "an MSI installs through msiexec with the caller's arguments"

# --- install refuses what it cannot do -------------------------------------

select_instance plain
install_exe "$not_pe" "" false false >/dev/null 2>&1 &&
  fail "install accepted a non-installer file"
select_instance ghost
install_exe "$pe" "" false false >/dev/null 2>&1 &&
  fail "install accepted an instance that does not exist"
select_instance plain
install_exe "" "" false false >/dev/null 2>&1 &&
  fail "install accepted a missing file argument"
pass "install refuses a bad file and an unknown instance"

rm -f "$STUB_BIN/xfreerdp3" "$STUB_BIN/gum"
