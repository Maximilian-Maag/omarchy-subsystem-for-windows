# Canonical entry points. `make test` runs the same suite CI runs
# (.github/workflows/test.yml -> tools/run_tests.sh); `make check` is the fast
# pre-push subset.
.PHONY: test check lint mutation

test:
	@bash tools/run_tests.sh

check: lint
	@bash tests/shell/test_install.sh
	@bash tests/shell/test_windows_vm_instances.sh

lint:
	@python3 tools/policy_check.py

mutation:
	@python3 tools/mutator.py
