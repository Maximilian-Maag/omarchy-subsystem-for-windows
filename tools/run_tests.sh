#!/bin/bash
# Every test kind this repository promises, in escalating cost order.
#
#   policy as code -> shell -> mutation
#
# Locally: `tools/run_tests.sh`. In CI: .github/workflows/test.yml.
# `SKIP_MUTATION=1` runs everything but the mutation pass (it is the slow one);
# `ONLY=shell` runs a subset.
set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")/.." || exit 1

ONLY="${ONLY:-}"
want() { [ -n "$ONLY" ] || return 0; case ",$ONLY," in *",$1,"*) return 0 ;; esac; return 1; }
fail=0
run() {                        # run <label> <command...>
  local label="$1"; shift
  printf '\n=== %s ===\n' "$label"
  if "$@"; then
    printf '%s: ok\n' "$label"
  else
    printf '%s: FAILED (exit %s)\n' "$label" "$?"
    fail=1
  fi
}

if want policy; then
  run "policy as code" python3 tools/policy_check.py
fi

if want shell; then
  shopt -s nullglob
  sh_files=(tests/shell/test_*.sh)
  if [ ${#sh_files[@]} -gt 0 ]; then
    for f in "${sh_files[@]}"; do
      run "shell tests: $(basename "$f")" bash "$f"
    done
  fi
fi

if want mutation && [ -z "${SKIP_MUTATION:-}" ]; then
  run "mutation tests" python3 tools/mutator.py
fi

printf '\n'
if [ "$fail" -eq 0 ]; then
  echo "ALL TEST KINDS PASSED"
else
  echo "SOME TESTS FAILED"
fi
exit "$fail"
