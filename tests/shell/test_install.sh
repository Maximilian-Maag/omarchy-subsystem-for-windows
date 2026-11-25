#!/bin/bash
# install.sh: the engine lands as a real, executable copy under PREFIX, a second
# run is idempotent, and --uninstall removes only an unmodified copy.

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

export PREFIX="$work/prefix"
DEST="$PREFIX/bin/omarchy-subsystem-for-windows"

# --- install -------------------------------------------------------------------
bash "$ROOT/install.sh" >"$work/install.log" 2>&1 ||
  fail "install.sh exited non-zero" "$(cat "$work/install.log")"
[[ -f $DEST ]] || fail "install.sh did not copy the engine to $DEST"
[[ -x $DEST ]] || fail "the installed engine is not executable"
cmp -s "$ROOT/bin/omarchy-subsystem-for-windows" "$DEST" ||
  fail "the installed engine differs from the checkout"
[[ ! -L $DEST ]] || fail "the installed engine is a symlink; priv_target would refuse it"
pass "install.sh copies a real, executable engine under PREFIX"

# A second run must not fail and must keep the same content.
bash "$ROOT/install.sh" >"$work/install2.log" 2>&1 ||
  fail "install.sh is not idempotent" "$(cat "$work/install2.log")"
cmp -s "$ROOT/bin/omarchy-subsystem-for-windows" "$DEST" ||
  fail "the second install changed the engine"
pass "install.sh is idempotent"

# --- uninstall -----------------------------------------------------------------
bash "$ROOT/install.sh" --uninstall >"$work/uninstall.log" 2>&1 ||
  fail "uninstall exited non-zero" "$(cat "$work/uninstall.log")"
[[ ! -e $DEST ]] || fail "uninstall left $DEST behind"
pass "uninstall removes the installed copy"

# A modified copy is not ours to delete: the script reports it and leaves it.
mkdir -p "$(dirname "$DEST")"
printf '#!/bin/bash\necho modified\n' >"$DEST"
chmod +x "$DEST"
bash "$ROOT/install.sh" --uninstall >"$work/uninstall2.log" 2>&1 ||
  fail "uninstall failed on a modified copy" "$(cat "$work/uninstall2.log")"
[[ -e $DEST ]] || fail "uninstall deleted a copy it did not install"
grep -q "differs from this checkout" "$work/uninstall2.log" ||
  fail "uninstall did not explain why it left the modified copy"
pass "uninstall leaves a modified copy in place and says so"
