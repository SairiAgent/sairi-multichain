# Runbook (local only)

**EXPERIMENTAL — UNAUDITED — NO MAINNET DEPLOYMENT.** Every command in this file is offline once the Solidity 0.8.30 compiler has been fetched by Foundry. None uses a wallet, private key, RPC endpoint or network service. The separate, testnet-only network procedure (read-only checks plus maintainer-gated testnet broadcasts) is in [TESTNET_RUNBOOK](TESTNET_RUNBOOK.md); there is no mainnet procedure.

## Prerequisites

Foundry v1.5.1 and Python 3.12.8 (`PYTHON ?= python3.12`; override with `make PYTHON=/path/to/python3.12 ...`). No Python packages. Third-party Solidity sources are vendored in `dependencies/` and pinned by `dependencies/lock.json` (`make deps-verify`); `make deps-fetch` (network, maintainers only) re-creates them from the pinned npm tarballs. Nothing is installed globally; `PYTHONDONTWRITEBYTECODE=1` is exported so test runs leave no `__pycache__`.

## Make targets

| Command | Does |
|---|---|
| `make setup` | Asserts Python is exactly 3.12.8 and Forge reports 1.5.1. Installs nothing. |
| `make build` | `forge build` |
| `make test` | `forge test` excluding the opt-in `test/fork/*`, then `make test-python` |
| `make test-python` | `python -m unittest discover -s tests -p 'test_*.py' -v` |
| `make invariants` | `forge test --match-path 'test/invariant/*'` (local harness and LayerZero stack) |
| `make deps-verify` | Vendored dependency tree equals `dependencies/lock.json` (hashes, pins, SPDX, imports, remappings); full upstream license texts in `licenses/` match `licenses/lock.json` (sha256 + git blob id) and are present in every package that needs them |
| `make demo` | Solidity integration test (`test/integration/*`, `-vv`), then `tools/sairi.py demo` and `tools/sairi.py simulate` |
| `make config-check` | Validates `config/local/local-mock.json`; runs the expected-reject gate on `config/networks/live.json` (passes only when the live file is rejected) |
| `make monitor-check` | Evaluates the five monitor fixtures at fixed `--now 1700000600` and asserts SAFE / UNSAFE (observed-balance loss) / STALE / UNKNOWN (incoherent) / UNKNOWN (non-synthetic) |
| `make simulate` | Default synthetic buy/sell cost table |
| `make check` | `forge fmt --check`, deps-verify, build, test (Solidity + Python), invariants, config-check, monitor-check, `tools/check_repository.py` publication guard (which rejects any `runtime/`, `.claude/` or `.env*` path in the working tree) |
| `make testnet-*` | Network; see [TESTNET_RUNBOOK](TESTNET_RUNBOOK.md). Never part of `check` |

## Tool commands

```sh
python3.12 tools/sairi.py validate-config config/local/local-mock.json
python3.12 tools/sairi.py validate-config --expect-reject config/networks/live.json
python3.12 tools/sairi.py monitor config/local/monitor-safe.json --now 1700000600 [--expect SAFE]
python3.12 tools/sairi.py simulate [--total-liquidity-usd 120000] [--sairi-usd 0.01] [--weth-usd 3000] \
    [--trade-usd 500 --trade-usd 1000 ...] [--sairi-decimals 18] [--weth-decimals 18] \
    [--reserve-sairi RAW --reserve-weth RAW]
python3.12 tools/sairi.py quote --reserve-in RAW --reserve-out RAW --gross RAW [--max-input RAW]
python3.12 tools/sairi.py demo
```

USD amounts and prices are exact decimal strings (≤ 18 fractional digits, no exponents) converted to fixed-point integers; raw amounts are non-negative integers. All output is JSON; large integers are emitted as decimal strings where precision matters.

`validate-config` checks records offline only (`deploymentVerified: false` always); live evidence entries must carry `configuredValue` equal to the configured value. `monitor` reports every `synthetic: false` snapshot as UNKNOWN because no verified live evidence collector exists; L in a snapshot must be the observed `balanceOf(lockbox)` normalized to shared units, with `totalLocked` supplied only as the optional `trackedLocked` observation. `simulate` rejects non-positive explicit reserves and reports `initialValuationUsd` separately from the configured total.

Exit codes: `validate-config` 0 = VALID (or REJECTED with `--expect-reject`), 1 otherwise. `monitor` 0 SAFE, 2 UNSAFE, 3 STALE, 4 UNKNOWN, 5 INVALID, or 0/1 with `--expect`. `simulate` 0, 1 if any case reverted, 2 on bad parameters. `demo` 0 only if every step is SAFE and all reconciliations hold.

## Responding to a monitor result (local harness)

- `UNSAFE`: treat as a backing failure. In the harness this occurs with forged deliveries (verifier compromise tests) or a modelled observed-balance loss. There is no automatic remedy; pausing stops further credits/releases but cannot restore lost backing.
- `UNKNOWN` / `STALE` / `INVALID`: the snapshot proves nothing. For synthetic data, re-collect a coherent, finalized snapshot at one epoch and ledger checkpoint; do not combine unrelated latest-block reads. For non-synthetic data `UNKNOWN` is expected and permanent until a verified collector exists (BLOCKED); still read the `reasons` list, which includes any deficit.

## Promotion to any live configuration

Mainnet promotion is not authorized (testnet steps are in [TESTNET_RUNBOOK](TESTNET_RUNBOOK.md)). It would require, at minimum: official-source provenance and pinned-block code verification for every value (see [SOURCES](SOURCES.md), [EXISTING_SAIRI](EXISTING_SAIRI.md)); integration against mature LayerZero and DEX libraries; fee-schedule approval; an independent audit; and the integration issues tracked in [STATUS](STATUS.md).
