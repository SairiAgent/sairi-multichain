# Adversarial review record

2026-10-05. Separate model-assisted read-only review plus orchestrator source review and independent execution. **Not an independent professional security audit.**

## Fixed before the contract checkpoint

- One-sided transfer checks could miss recipient under-credit or sender surcharge. ExactTransferLib now checks both ends; mutable-tax deposit/release/swap/claim regressions verify atomic rollback.
- LP entry accepted off-ratio donations and lacked minima. It now consumes only proportional amounts (rounding up less than one raw unit per asset), preserves unused input, enforces minShares, and removal enforces both asset minima. Changed-reserve/slippage and rounding fuzz regressions added.
- Added canonical token callback reentrancy tests and corrected owner liveness wording.

## Explicit residual risks / limitations

- A trusted endpoint or verification network compromise can forge credits or drain all backing with an authenticated release within totalLocked. Tests deliberately demonstrate these violations. Outbound rate limits do not limit inbound compromise. Monitoring detects accounting failure; it does not prevent it.
- Owners cannot directly mint or withdraw collateral, but pauses or zero burn-rate limits can indefinitely stall redemption. Governance and recovery need separate production design; no expiry of the underlying redemption entitlement is introduced.
- Exact balance checks assume honest balanceOf and non-rebasing behavior. Arbitrary malicious tokens are not supported.
- Mock endpoints and original constant-product harness do not validate LayerZero/CCIP or a Uniswap PoolManager/hook integration. Exact-output swaps and execution-engine partial fills are unsupported; a smaller explicitly consumed input simply leaves the unused maximum with its owner.
- Canonical identity, existing adapters, beneficiary, deployed bytecode, licensing of future imports and finalized production observations remain gated.

## Evidence

70 Solidity tests pass, none fail/skip; three fuzz tests run 128 cases each. make setup/check/demo completed locally. Hosted CI must be checked against the actual pushed commit separately. See STATUS.md and issue backlog for the remaining live integration gates.

## Tooling review and regression fixes

Orchestrator separately reviewed the Claude implementation and required: observed-balance L instead of totalLocked bookkeeping; all non-synthetic monitoring UNKNOWN without a verified evidence collector; exact value-bound evidence, known EIDs and credential-free URLs; atomic arithmetic-model updates on overflow/revert; strict bool/uint/direction boundaries; actual reserve valuation and sequential total-cost math. Claude implemented these corrections and negative regressions. 117 Python tests now pass independently, alongside the unchanged 70 Solidity tests. make setup/check/demo/simulate all completed successfully on 2026-10-05. No live integration/fork test is claimed.
