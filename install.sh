#!/bin/bash
# omarchy-subsystem-for-windows install script. Run once after cloning, or
# re-run to update:
#
#   ./install.sh                     install / update the CLI
#   ./install.sh --uninstall         remove what this script installed
#   PREFIX=/somewhere ./install.sh   install under another prefix (tests)
#
# The engine is COPIED, not symlinked, into $PREFIX/bin. That is deliberate: the
# command re-executes itself through pkexec for every privileged action, and the
# elevated path refuses a symlink or a file a non-root user could have written.
# Re-run this script after `git pull` to pick up changes.
set -uo pipefail

PLUGIN_DIR=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")" && pwd -P)
PREFIX="${PREFIX:-/usr/local}"
BIN_SRC="$PLUGIN_DIR/bin/omarchy-subsystem-for-windows"
BIN_DEST="$PREFIX/bin/omarchy-subsystem-for-windows"
COMMAND_NAME=omarchy-subsystem-for-windows

die() {
  echo "omarchy-subsystem-for-windows: $*" >&2
  exit 1
}

# Run a command as root when the current user cannot do it directly. Tests point
# PREFIX at a directory they own, so this never prompts there.
as_root() {
  if ((EUID == 0)); then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    return 1
  fi
}

uninstall() {
  if [[ ! -e $BIN_DEST ]]; then
    echo "  Nothing installed at $BIN_DEST."
    return 0
  fi
  if ! cmp -s -- "$BIN_SRC" "$BIN_DEST"; then
    echo "  NOTE: $BIN_DEST differs from this checkout; leaving it in place."
    echo "        Remove it yourself if you are sure:  sudo rm -f $BIN_DEST"
    return 0
  fi
  if rm -f -- "$BIN_DEST" 2>/dev/null || as_root rm -f -- "$BIN_DEST"; then
    echo "  Removed $BIN_DEST."
  else
    die "could not remove $BIN_DEST"
  fi
}

if [[ ${1:-} == --uninstall ]]; then
  uninstall
  exit 0
fi

[[ -f $BIN_SRC ]] || die "engine not found at $BIN_SRC"
[[ -x $BIN_SRC ]] || die "engine is not executable: $BIN_SRC"

echo "omarchy-subsystem-for-windows: installing from $PLUGIN_DIR"

# ── 1. Validate the plugin ────────────────────────────────────────────────────
if command -v omarchy >/dev/null 2>&1; then
  omarchy plugin validate "$PLUGIN_DIR" || die "plugin validation failed"
  echo "  manifest OK."
fi

# ── 2. Copy the engine onto PATH ──────────────────────────────────────────────
# A copy, not a symlink: priv_target() refuses to elevate a symlink or anything
# a non-root user could have written. The destination directory must be
# root-owned all the way up for elevation to work.
if ! mkdir -p -- "$(dirname -- "$BIN_DEST")" 2>/dev/null; then
  as_root mkdir -p -- "$(dirname -- "$BIN_DEST")" || die "could not create $(dirname -- "$BIN_DEST")"
fi
if ! install -m 0755 -- "$BIN_SRC" "$BIN_DEST" 2>/dev/null; then
  as_root install -m 0755 -- "$BIN_SRC" "$BIN_DEST" || die "could not install $BIN_DEST"
fi
echo "  Installed $BIN_DEST."

# ── 3. Report the elevation path this install gives you ───────────────────────
if [[ $(stat -Lc '%u' -- "$BIN_DEST" 2>/dev/null) == 0 ]]; then
  echo "  Privileged actions re-exec $BIN_DEST through pkexec."
else
  echo "  NOTE: $BIN_DEST is not root-owned, so privileged actions will refuse to"
  echo "        elevate it. Install with PREFIX=/usr/local as root for a real install."
fi

echo ""
echo "Done. Try:  $COMMAND_NAME status   /   $COMMAND_NAME instances"
echo "Re-run this script after 'git pull' to update the copied engine."
