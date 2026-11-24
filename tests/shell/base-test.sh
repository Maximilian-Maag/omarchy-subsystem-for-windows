#!/bin/bash
# Shared helpers for this plugin's shell tests. Source it; never run it.
#
# The engine is a single bash script that both dispatches commands and exposes
# its internals as functions, so the tests here source it and call the internal
# functions directly, exactly as the core suite does.

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  echo "source tests/shell/base-test.sh from a shell test; do not run it directly" >&2
  exit 1
fi

# Physical, so a checkout reached through a symlink still resolves its own bin/.
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
export ROOT

pass() {
  printf 'ok - %s\n' "$1"
}

skip() {
  printf 'ok - %s # SKIP\n' "$1"
}

fail() {
  local description="$1"
  local detail="${2:-}"

  [[ -n $detail ]] && printf '%s\n' "$detail" >&2
  printf 'not ok - %s\n' "$description" >&2
  exit 1
}
