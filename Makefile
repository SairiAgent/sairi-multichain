PYTHON ?= python3.12
SAIRI := $(PYTHON) tools/sairi.py
MONITOR_NOW := 1700000600
# Keep the working tree clean: no __pycache__ directories from test or tool runs.
export PYTHONDONTWRITEBYTECODE := 1
# TESTNET ONLY (Base Sepolia 84532 <-> Robinhood Chain testnet 46630). Public, credential-free RPCs; they must
# match config/testnet/ and script/testnet/TestnetRoutes.sol (enforced by tests/test_testnet.py).
TESTNET_CONFIG := config/testnet/base-sepolia-robinhood-testnet.json
TESTNET_DEPLOYMENTS := config/testnet/deployments.json
BASE_SEPOLIA_RPC := https://sepolia.base.org
ROBINHOOD_TESTNET_RPC := https://rpc.testnet.chain.robinhood.com
TESTNET_SCRIPT := script/testnet/SairiTestnet.s.sol:SairiTestnet
# Foundry signer flags supplied by the operator at invocation time (e.g. an encrypted keystore account or a
# hardware wallet). This repository never stores, reads or prints key material.
SIGNER ?=
.PHONY: setup build test test-python invariants demo config-check monitor-check simulate check deps-verify deps-fetch deps-list \
	testnet-preflight testnet-fork-check testnet-guard testnet-amount-guard testnet-deploy-canonical testnet-deploy-representation \
	testnet-wire-base testnet-wire-robinhood testnet-send-base testnet-send-robinhood testnet-status testnet-message
setup:
	$(PYTHON) -c 'import sys; assert sys.version_info[:3] == (3, 12, 8), "Use pinned Python 3.12.8"'
	forge --version | head -1 | grep -q '1.5.1'
build:
	forge build
# test/fork/* needs public testnet RPCs and is run only by `make testnet-fork-check`.
test:
	forge test --no-match-path 'test/fork/*'
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
# Offline: vendored third-party sources match dependencies/lock.json exactly.
deps-verify:
	$(PYTHON) tools/vendor_deps.py verify
# Network (npm registry, pinned sha512 integrity): re-vendor the import closure. Maintainers only.
deps-fetch:
	$(PYTHON) tools/vendor_deps.py fetch
deps-list:
	$(PYTHON) tools/vendor_deps.py list $(PKG)
check:
	forge fmt --check
	$(MAKE) deps-verify
	$(MAKE) build
	$(MAKE) test
	$(MAKE) invariants
	$(MAKE) config-check
	$(MAKE) monitor-check
	$(PYTHON) tools/check_repository.py

# ---------------------------------------------------------------- testnet (network; never part of `check`)
# Read-only: Python JSON-RPC route verification, then the Solidity script's own on-chain preflight per chain.
testnet-preflight:
	$(SAIRI) testnet-preflight $(TESTNET_CONFIG) $(if $(OUT),--out $(OUT))
	forge script $(TESTNET_SCRIPT) --sig 'preflight()' --rpc-url $(BASE_SEPOLIA_RPC)
	forge script $(TESTNET_SCRIPT) --sig 'preflight()' --rpc-url $(ROBINHOOD_TESTNET_RPC)
# Read-only fork SIMULATION of deploy/wire/roundtrip through the live LayerZero contracts (DVN impersonated).
testnet-fork-check:
	forge test --match-path 'test/fork/*' -vv
# Broadcast gate: explicit acknowledgement, operator address and signer flags are all mandatory. Raw-key signer
# flags are refused, and broadcast recipes are not echoed so signer flags never reach terminal logs.
testnet-guard:
	@test "$(SAIRI_TESTNET_CONFIRM)" = "testnet-only" || { echo "Refusing: set SAIRI_TESTNET_CONFIRM=testnet-only"; exit 1; }
	@test -n "$(SAIRI_TESTNET_OPERATOR)" || { echo "Refusing: set SAIRI_TESTNET_OPERATOR"; exit 1; }
	@test -n "$(SIGNER)" || { echo "Refusing: set SIGNER to Foundry signer flags"; exit 1; }
	@case "$(SIGNER)" in *private-key*|*mnemonic*) echo "Refusing: use a keystore account or hardware wallet, not raw key flags"; exit 1;; esac
# $(1) = script signature, $(2) = RPC URL, $(3) = extra script arguments.
testnet_broadcast = @echo "forge script $(TESTNET_SCRIPT) --sig '$(1)' $(3) --rpc-url $(2) --broadcast --slow <signer flags redacted>"; \
	forge script $(TESTNET_SCRIPT) --sig '$(1)' $(3) --rpc-url $(2) --broadcast --slow $(SIGNER)
testnet-deploy-canonical: testnet-guard testnet-preflight
	$(call testnet_broadcast,deployCanonical(),$(BASE_SEPOLIA_RPC))
testnet-deploy-representation: testnet-guard testnet-preflight
	$(call testnet_broadcast,deployRepresentation(),$(ROBINHOOD_TESTNET_RPC))
testnet-wire-base: testnet-guard testnet-preflight
	$(call testnet_broadcast,wire(),$(BASE_SEPOLIA_RPC))
testnet-wire-robinhood: testnet-guard testnet-preflight
	$(call testnet_broadcast,wire(),$(ROBINHOOD_TESTNET_RPC))
# AMOUNT in local decimals (multiple of 1e12); MAX_FEE in wei caps the LayerZero native fee.
testnet-amount-guard:
	@case "$(AMOUNT)$(MAX_FEE)" in ''|*[!0-9]*) echo "Set numeric AMOUNT and MAX_FEE"; exit 1;; esac
	@test -n "$(AMOUNT)" && test -n "$(MAX_FEE)" || { echo "Set AMOUNT and MAX_FEE"; exit 1; }
testnet-send-base: testnet-guard testnet-amount-guard testnet-preflight
	$(call testnet_broadcast,send(uint256,uint256),$(BASE_SEPOLIA_RPC),$(AMOUNT) $(MAX_FEE))
testnet-send-robinhood: testnet-guard testnet-amount-guard testnet-preflight
	$(call testnet_broadcast,send(uint256,uint256),$(ROBINHOOD_TESTNET_RPC),$(AMOUNT) $(MAX_FEE))
# Structural checks + raw observations. Backing status is always UNKNOWN (exit 4) or worse; use EXPECT=UNKNOWN to
# assert that only the structural checks passed. Never treat this as settlement or solvency proof.
testnet-status:
	$(SAIRI) testnet-status $(TESTNET_CONFIG) $(TESTNET_DEPLOYMENTS) $(if $(EXPECT),--expect $(EXPECT))
testnet-message:
	@test -n "$(TX)" || { echo "Set TX=<source transaction hash>"; exit 1; }
	$(SAIRI) testnet-message $(TESTNET_CONFIG) $(TX)
