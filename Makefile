PYTHON ?= python3.12
SAIRI := $(PYTHON) tools/sairi.py
MONITOR_NOW := 1700000600
# Keep the working tree clean: no __pycache__ directories from test or tool runs.
export PYTHONDONTWRITEBYTECODE := 1
.PHONY: setup build test test-python invariants demo config-check monitor-check simulate check
setup:
	$(PYTHON) -c 'import sys; assert sys.version_info[:3] == (3, 12, 8), "Use pinned Python 3.12.8"'
	forge --version | head -1 | grep -q '1.5.1'
build:
	forge build
test:
	forge test
	$(MAKE) test-python
test-python:
	$(PYTHON) -m unittest discover -s tests -p 'test_*.py' -v
invariants:
	forge test --match-path 'test/invariant/*'
demo:
	forge test --match-path 'test/integration/*' -vv
	$(SAIRI) demo
	$(SAIRI) simulate
config-check:
	$(SAIRI) validate-config config/local/local-mock.json
	$(SAIRI) validate-config --expect-reject config/networks/live.json
monitor-check:
	$(SAIRI) monitor config/local/monitor-safe.json --now $(MONITOR_NOW) --expect SAFE
	$(SAIRI) monitor config/local/monitor-unsafe.json --now $(MONITOR_NOW) --expect UNSAFE
	$(SAIRI) monitor config/local/monitor-stale.json --now $(MONITOR_NOW) --expect STALE
	$(SAIRI) monitor config/local/monitor-incoherent.json --now $(MONITOR_NOW) --expect UNKNOWN
	$(SAIRI) monitor config/local/monitor-nonsynthetic.json --now $(MONITOR_NOW) --expect UNKNOWN
simulate:
	$(SAIRI) simulate
check:
	forge fmt --check
	$(MAKE) build
	$(MAKE) test
	$(MAKE) invariants
	$(MAKE) config-check
	$(MAKE) monitor-check
	$(PYTHON) tools/check_repository.py
