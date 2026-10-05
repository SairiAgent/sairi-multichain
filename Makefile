PYTHON ?= python3.12
.PHONY: setup build test invariants demo check
setup:
	$(PYTHON) -c 'import sys; assert sys.version_info[:3] == (3, 12, 8), "Use pinned Python 3.12.8"'
	forge --version | head -1 | grep -q '1.5.1'
build:
	forge build
test:
	forge test
invariants:
	forge test --match-path 'test/invariant/*'
demo:
	forge test --match-path 'test/integration/*' -vv
check:
	forge fmt --check
	$(MAKE) build
	$(MAKE) test
	$(MAKE) invariants
	$(PYTHON) tools/check_repository.py
