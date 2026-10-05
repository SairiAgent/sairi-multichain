"""SYNTHETIC local roundtrip mirroring test/integration/LocalHarnessFlow.t.sol.

Models lock -> credit -> pool seed -> buy -> sell -> claims -> burn -> release -> donation with integer
amounts and reports L, R, P, Q (shared-decimal units) plus a monitor verdict after every step.

L is the OBSERVED canonical balance held by the lockbox (floor(balance / conversionRate)). The lockbox's
`totalLocked` is reported separately as `trackedLocked`, a reconciliation record that must equal R + P + Q;
it never replaces L. The ledger here is a Python arithmetic model, not an EVM or token emulation; the
Solidity integration test (run by `make demo`) is the executable reference.
"""
from . import monitor
from .amm import Pool

CANON_DECIMALS, REP_DECIMALS, SHARED_DECIMALS = 18, 12, 6
CANON_RATE = 10 ** (CANON_DECIMALS - SHARED_DECIMALS)
REP_RATE = 10 ** (REP_DECIMALS - SHARED_DECIMALS)
DEMO_EPOCH_TIME = 1_700_000_000
SAIRI, WETH = 0, 1  # pool token order: token0 = backed SAIRI, token1 = WETH-like
DONATION_LD = 7 * CANON_RATE + 3  # 7 shared units of surplus plus 3 raw units of dust


class DemoError(AssertionError):
    pass


class Ledger:
    """Lockbox, representation supply and the delivery ledger shared by both mock endpoints."""

    def __init__(self):
        self.lockbox_balance = 0  # canonical LD actually held by the lockbox (observed backing)
        self.total_locked = 0  # canonical LD tracked by the lockbox (reconciliation record)
        self.rep_balances = {}  # representation LD per holder
        self.messages = []  # {"kind": "lock"|"burn", "recipient", "amountSD", "delivered"}

    @property
    def rep_supply(self):
        return sum(self.rep_balances.values())

    def _to_sd(self, amount_ld, rate):
        if amount_ld == 0 or amount_ld % rate:
            raise DemoError("Dust/zero amount rejected (BridgeAppBase._prepareOutbound)")
        return amount_ld // rate

    def lock(self, amount_ld, recipient):
        sd = self._to_sd(amount_ld, CANON_RATE)
        self.lockbox_balance += amount_ld
        self.total_locked += amount_ld
        self.messages.append({"kind": "lock", "recipient": recipient, "amountSD": sd, "delivered": False})
        return len(self.messages) - 1

    def burn(self, holder, amount_ld, recipient):
        sd = self._to_sd(amount_ld, REP_RATE)
        if self.rep_balances.get(holder, 0) < amount_ld:
            raise DemoError("burn exceeds balance")
        self.rep_balances[holder] -= amount_ld
        self.messages.append({"kind": "burn", "recipient": recipient, "amountSD": sd, "delivered": False})
        return len(self.messages) - 1

    def relay(self, index):
        msg = self.messages[index]
        if msg["delivered"]:
            raise DemoError("Replay")
        msg["delivered"] = True
        if msg["kind"] == "lock":
            self.rep_balances[msg["recipient"]] = self.rep_balances.get(msg["recipient"], 0) + msg["amountSD"] * REP_RATE
        else:
            amount = msg["amountSD"] * CANON_RATE
            if amount > self.total_locked:
                raise DemoError("InsufficientBacking")
            self.total_locked -= amount
            self.lockbox_balance -= amount

    def donate(self, amount_ld):
        """Unsolicited transfer to the lockbox: raises the observed balance only, never totalLocked."""
        self.lockbox_balance += amount_ld

    def lrpq(self):
        pending = {"lock": 0, "burn": 0}
        for msg in self.messages:
            if not msg["delivered"]:
                pending[msg["kind"]] += msg["amountSD"]
        return {"L": self.lockbox_balance // CANON_RATE, "R": self.rep_supply // REP_RATE,
                "P": pending["lock"], "Q": pending["burn"], "trackedLocked": self.total_locked // CANON_RATE}

    def checkpoint(self):
        delivered = sum(1 for m in self.messages if m["delivered"])
        return f"demo-ledger-sent{len(self.messages)}-delivered{delivered}"


def _snapshot(values, epoch, checkpoint, observed_at):
    def obs(name, source):
        return {"value": values[name], "units": monitor.UNITS, "decimals": SHARED_DECIMALS, "epoch": epoch,
                "ledgerCheckpoint": checkpoint, "finalized": True, "observedAt": observed_at,
                "evidence": {"source": f"synthetic:{source}", "chainId": 31337 if name in ("L", "P", monitor.TRACKED) else 31338,
                             "blockNumber": epoch}}

    return {"schemaVersion": 1, "synthetic": True, "sharedDecimals": SHARED_DECIMALS, "maxAgeSeconds": 300,
            "observations": {"L": obs("L", "canonical.balanceOf(lockbox)/conversionRate"),
                             "R": obs("R", "representation.totalSupply"),
                             "P": obs("P", "ledger.pendingLocks"), "Q": obs("Q", "ledger.pendingBurns"),
                             monitor.TRACKED: obs(monitor.TRACKED, "lockbox.totalLocked/conversionRate")}}


def run():
    ledger, pool = Ledger(), Pool()
    weth = {"ALICE": 0, "TRADER": 0, "CREATOR": 0}
    steps, swaps, claims = [], [], {}

    def record(label):
        values = ledger.lrpq()
        epoch = len(steps) + 1
        t = DEMO_EPOCH_TIME + epoch * 12
        verdict = monitor.evaluate(_snapshot(values, epoch, ledger.checkpoint(), t), t)
        steps.append({"step": epoch, "action": label, **values, "requiredBacking": values["R"] + values["P"] + values["Q"],
                      "monitorStatus": verdict["status"], "ledgerCheckpoint": ledger.checkpoint()})

    # 1. Bridge canonical liquidity and trader funds to the representation side.
    ledger.relay(ledger.lock(500_000 * 10**CANON_DECIMALS, "ALICE"))
    record("lock+credit ALICE 500000 SAIRI")
    trader_lock = ledger.lock(5_000 * 10**CANON_DECIMALS, "TRADER")
    record("lock TRADER 5000 SAIRI (in flight, P>0)")
    ledger.relay(trader_lock)
    record("credit TRADER")

    # 2. Seed the local pool from locally supplied backed SAIRI and WETH-like.
    weth["ALICE"] += 50 * 10**18
    seed = pool.add_liquidity(500_000 * 10**REP_DECIMALS, 50 * 10**18, 5 * 10**18 - 1_000, "ALICE")
    ledger.rep_balances["ALICE"] -= seed.amount0
    ledger.rep_balances["POOL"] = seed.amount0
    weth["ALICE"] -= seed.amount1
    weth["POOL"] = seed.amount1
    record("seed pool (supply unchanged)")

    # 3. Independent-direction trades on the same pool, in sequence.
    weth["TRADER"] += 10 * 10**18
    buy = pool.swap_exact_input(False, 2 * 10**18, 2 * 10**18, 1)
    weth["TRADER"] -= buy.consumed
    weth["POOL"] += buy.consumed - buy.creator_fee
    weth["COLLECTOR"] = buy.creator_fee
    ledger.rep_balances["POOL"] -= buy.output
    ledger.rep_balances["TRADER"] += buy.output
    sell = pool.swap_exact_input(True, 3_000 * 10**REP_DECIMALS, 3_000 * 10**REP_DECIMALS, 1)
    ledger.rep_balances["TRADER"] -= sell.consumed
    ledger.rep_balances["POOL"] += sell.consumed - sell.creator_fee
    ledger.rep_balances["COLLECTOR"] = sell.creator_fee
    weth["POOL"] -= sell.output
    weth["TRADER"] += sell.output
    for label, s in (("buy WETH->SAIRI", buy), ("sell SAIRI->WETH", sell)):
        swaps.append({"action": label, "consumedRaw": str(s.consumed), "untouchedRaw": str(s.untouched),
                      "creatorFeeRaw": str(s.creator_fee), "creatorFeeAsset": "WETH" if label.startswith("buy") else "SAIRI",
                      "lpFeeRaw": str(s.lp_fee), "outputRaw": str(s.output)})
    record("buy + sell (supply unchanged)")

    # 4. Permissionless claims always pay the fixed beneficiary.
    for index, name, book in ((WETH, "WETH", weth), (SAIRI, "SAIRI", ledger.rep_balances)):
        amount = pool.claim(index)
        book["COLLECTOR"] -= amount
        book["CREATOR"] = book.get("CREATOR", 0) + amount
        claims[name] = {"claimedRaw": str(amount), "beneficiary": "CREATOR (fixed)", "callerReceived": "0"}
    record("claims (supply unchanged)")

    # 5. Bridge back, excluding sub-shared-decimal dust.
    creator_back = ledger.rep_balances["CREATOR"] - ledger.rep_balances["CREATOR"] % REP_RATE
    trader_back = ledger.rep_balances["TRADER"] - ledger.rep_balances["TRADER"] % REP_RATE
    c = ledger.burn("CREATOR", creator_back, "CREATOR")
    t = ledger.burn("TRADER", trader_back, "TRADER")
    record("burn CREATOR + TRADER (in flight, Q>0)")
    ledger.relay(t)
    record("release TRADER")
    ledger.relay(c)
    record("release CREATOR")

    # 6. Unsolicited donation: observed L rises (surplus + sub-shared-decimal dust), tracked record does not.
    ledger.donate(DONATION_LD)
    record("donation to lockbox (untracked surplus, not releasable)")

    reconciliation = {
        "weth": {
            "poolReserveMatchesBalance": pool.reserve1 == weth["POOL"],
            "collectorHeldEqualsAccruedMinusDelivered": weth["COLLECTOR"] == pool.claimable(WETH),
            "beneficiaryEqualsDelivered": weth["CREATOR"] == pool.delivered[WETH],
            "creatorFeeIsOnePercentOfInput": pool.accrued[WETH] == 2 * 10**18 // 100,
            "conserved": sum(weth.values()) == 60 * 10**18,
        },
        "sairi": {
            "poolReserveMatchesBalance": pool.reserve0 == ledger.rep_balances["POOL"],
            "collectorHeldEqualsAccruedMinusDelivered": ledger.rep_balances["COLLECTOR"] == pool.claimable(SAIRI),
            "creatorFeeIsOnePercentOfInput": pool.accrued[SAIRI] == 3_000 * 10**REP_DECIMALS // 100,
            "trackedFullyBackedNothingInFlight": ledger.total_locked == ledger.rep_supply * (CANON_RATE // REP_RATE),
            "observedBalanceCoversTracked": ledger.lockbox_balance >= ledger.total_locked,
            "untrackedDonationEqualsBalanceMinusTracked":
                ledger.lockbox_balance - ledger.total_locked == DONATION_LD,
        },
        "donation": {
            "rawCanonical": str(DONATION_LD),
            "surplusSharedUnits": str(DONATION_LD // CANON_RATE),
            "subSharedDecimalDustRaw": str(DONATION_LD % CANON_RATE),
        },
    }
    ok = all(
        s["monitorStatus"] == monitor.SAFE and s["trackedLocked"] == s["requiredBacking"]
        and s["L"] >= s["trackedLocked"] for s in steps
    ) and all(all(v for v in group.values() if isinstance(v, bool)) for group in reconciliation.values())
    return {
        "kind": "SYNTHETIC_LOCAL_DEMO_NOT_A_CHAIN_OBSERVATION",
        "units": f"L/R/P/Q in shared-decimal units (sharedDecimals={SHARED_DECIMALS})",
        "lDefinition": monitor.L_DEFINITION,
        "steps": steps, "swaps": swaps, "claims": claims, "reconciliation": reconciliation, "ok": ok,
    }
