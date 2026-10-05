"""Integer ARITHMETIC MIRROR of src/pool/LocalConstantProductPool.sol and src/fees/CreatorFeeCollector.sol.

Every operation uses Python integers with explicit uint256 overflow checks, floor division where
Solidity floors and ceiling division where Solidity rounds up, so results match the contract exactly:

  creatorFee = floor(gross * 100 / 10000)                 input asset, leaves the pool to the collector
  lpFee      = floor((gross - creatorFee) * 30 / 10000)    input asset, stays in reserves
  net        = gross - creatorFee - lpFee
  output     = floor(reserveOut * net / (reserveIn + net))

Like a Solidity revert, every state-changing method computes and checks ALL new values first and commits
only if nothing raised, so a PoolError leaves the model unchanged.

This mirrors arithmetic only. It does NOT emulate the EVM, ERC-20 token transfers or balances, exact
transfer checks, reentrancy guards, msg.sender authorization or recipient validation; holders are plain
string labels. It is the LOCAL HARNESS constant-product pool, not Uniswap v4 or concentrated liquidity.
"""
import math
from dataclasses import dataclass, field

from . import UINT256_MAX

FEE_DENOMINATOR = 10_000
CREATOR_FEE_BPS = 100
LP_FEE_BPS = 30
MINIMUM_LIQUIDITY = 1_000
DEAD = "0x0"  # holder label for permanently locked MINIMUM_LIQUIDITY


class PoolError(Exception):
    """Raised where the Solidity contract reverts. `code` is the custom error name or panic.

    `NotUint256`, `InvalidDirection`, `InvalidAsset`, `InvalidHolder` and `InvalidState` are model-side
    argument errors (Solidity's ABI types make those inputs unrepresentable)."""

    def __init__(self, code):
        super().__init__(code)
        self.code = code


def _is_uint(value):
    return type(value) is int and 0 <= value <= UINT256_MAX


def _u(value):
    if not _is_uint(value):
        raise PoolError("NotUint256")
    return value


def _direction(zero_for_one):
    if type(zero_for_one) is not bool:
        raise PoolError("InvalidDirection")
    return zero_for_one


def _asset(index):
    if type(index) is not int or index not in (0, 1):
        raise PoolError("InvalidAsset")
    return index


def _holder(label):
    if not isinstance(label, str) or not label:
        raise PoolError("InvalidHolder")
    return label


def _mul(a, b):
    r = a * b
    if r > UINT256_MAX:
        raise PoolError("Panic(0x11)")
    return r


def _add(a, b):
    r = a + b
    if r > UINT256_MAX:
        raise PoolError("Panic(0x11)")
    return r


def ceil_div(a, b):
    return 0 if a == 0 else (a - 1) // b + 1


@dataclass(frozen=True)
class Quote:
    gross: int
    creator_fee: int
    lp_fee: int
    net: int
    output: int


def quote_exact_input(gross, reserve_in, reserve_out):
    """Mirror of `_quote`. Does not revert on zero input or zero output (the view does not either)."""
    _u(gross), _u(reserve_in), _u(reserve_out)
    if reserve_in == 0 or reserve_out == 0:
        raise PoolError("NoLiquidity")
    creator_fee = _mul(gross, CREATOR_FEE_BPS) // FEE_DENOMINATOR
    lp_fee = _mul(gross - creator_fee, LP_FEE_BPS) // FEE_DENOMINATOR
    net = gross - creator_fee - lp_fee
    output = _mul(reserve_out, net) // _add(reserve_in, net)
    return Quote(gross, creator_fee, lp_fee, net, output)


@dataclass(frozen=True)
class SwapResult:
    zero_for_one: bool
    consumed: int
    untouched: int
    creator_fee: int
    lp_fee: int
    output: int


@dataclass(frozen=True)
class LiquidityResult:
    amount0: int
    amount1: int
    shares: int
    unused0: int
    unused1: int


@dataclass
class Pool:
    """Pool reserves/shares plus fee-collector accounting. Token 0 / token 1 follow the Solidity
    constructor order. Constructing with reserves and zero supply is allowed (used for virtual quotes)."""

    reserve0: int = 0
    reserve1: int = 0
    total_shares: int = 0
    shares: dict = field(default_factory=dict)
    accrued: list = field(default_factory=lambda: [0, 0])
    delivered: list = field(default_factory=lambda: [0, 0])

    def __post_init__(self):
        for value in (self.reserve0, self.reserve1, self.total_shares):
            _u(value)
        if not isinstance(self.shares, dict) or not all(
                isinstance(k, str) and k and _is_uint(v) for k, v in self.shares.items()):
            raise PoolError("InvalidState")
        if sum(self.shares.values()) > self.total_shares:
            raise PoolError("InvalidState")
        for book in (self.accrued, self.delivered):
            if not isinstance(book, list) or len(book) != 2 or not all(_is_uint(v) for v in book):
                raise PoolError("InvalidState")
        if any(d > a for a, d in zip(self.accrued, self.delivered)):
            raise PoolError("InvalidState")

    # ------------------------------------------------------------ liquidity

    def quote_add_liquidity(self, max0, max1):
        _u(max0), _u(max1)
        if max0 == 0 or max1 == 0:
            raise PoolError("ZeroInput")
        supply = self.total_shares
        if supply == 0:
            minted = math.isqrt(_mul(max0, max1))
            if minted <= MINIMUM_LIQUIDITY:
                raise PoolError("InsufficientLiquidityMinted")
            return LiquidityResult(max0, max1, minted - MINIMUM_LIQUIDITY, 0, 0)
        if self.reserve0 == 0 or self.reserve1 == 0:
            raise PoolError("Panic(0x12)")  # division by zero, as in Solidity
        s0 = _mul(max0, supply) // self.reserve0
        s1 = _mul(max1, supply) // self.reserve1
        shares = min(s0, s1)
        if shares == 0:
            raise PoolError("InsufficientLiquidityMinted")
        amount0 = ceil_div(_mul(shares, self.reserve0), supply)
        amount1 = ceil_div(_mul(shares, self.reserve1), supply)
        return LiquidityResult(amount0, amount1, shares, max0 - amount0, max1 - amount1)

    def add_liquidity(self, max0, max1, min_shares, to):
        _u(min_shares), _holder(to)
        result = self.quote_add_liquidity(max0, max1)
        if result.shares < min_shares:
            raise PoolError("MinSharesNotMet")
        new_shares = dict(self.shares)
        supply = self.total_shares
        if supply == 0:
            new_shares[DEAD] = MINIMUM_LIQUIDITY
            supply = MINIMUM_LIQUIDITY
        new_total = _add(supply, result.shares)
        new_shares[to] = _add(new_shares.get(to, 0), result.shares)
        new_r0 = _add(self.reserve0, result.amount0)
        new_r1 = _add(self.reserve1, result.amount1)
        # Commit only after every check above has passed.
        self.shares, self.total_shares, self.reserve0, self.reserve1 = new_shares, new_total, new_r0, new_r1
        return result

    def quote_remove_liquidity(self, shares):
        _u(shares)
        if shares == 0:
            raise PoolError("ZeroInput")
        if shares > self.total_shares:
            raise PoolError("InsufficientShares")
        amount0 = _mul(shares, self.reserve0) // self.total_shares
        amount1 = _mul(shares, self.reserve1) // self.total_shares
        if amount0 == 0 or amount1 == 0:
            raise PoolError("ZeroOutput")
        return amount0, amount1

    def remove_liquidity(self, holder, shares, min0, min1):
        _holder(holder), _u(shares), _u(min0), _u(min1)
        if shares == 0:
            raise PoolError("ZeroInput")
        if self.shares.get(holder, 0) < shares:
            raise PoolError("InsufficientShares")
        amount0, amount1 = self.quote_remove_liquidity(shares)
        if amount0 < min0 or amount1 < min1:
            raise PoolError("MinAmountsNotMet")
        new_shares = dict(self.shares)
        new_shares[holder] -= shares
        self.shares = new_shares
        self.total_shares -= shares
        self.reserve0 -= amount0
        self.reserve1 -= amount1
        return amount0, amount1

    # ------------------------------------------------------------ swaps

    def reserves(self, zero_for_one):
        _direction(zero_for_one)
        return (self.reserve0, self.reserve1) if zero_for_one else (self.reserve1, self.reserve0)

    def swap_exact_input(self, zero_for_one, gross, max_input, min_output):
        """Exact-input swap. Exactly `gross` is consumed; `max_input - gross` is never pulled."""
        _direction(zero_for_one), _u(gross), _u(max_input), _u(min_output)
        if gross == 0:
            raise PoolError("ZeroInput")
        if gross > max_input:
            raise PoolError("MaxInputExceeded")
        reserve_in, reserve_out = self.reserves(zero_for_one)
        q = quote_exact_input(gross, reserve_in, reserve_out)
        if q.output == 0:
            raise PoolError("ZeroOutput")
        if q.output < min_output:
            raise PoolError("Slippage")
        new_in = _add(reserve_in, gross) - q.creator_fee
        new_out = reserve_out - q.output
        index = 0 if zero_for_one else 1
        new_accrued = list(self.accrued)
        if q.creator_fee:
            new_accrued[index] = _add(new_accrued[index], q.creator_fee)
        # Commit only after every check above has passed.
        if zero_for_one:
            self.reserve0, self.reserve1 = new_in, new_out
        else:
            self.reserve1, self.reserve0 = new_in, new_out
        self.accrued = new_accrued
        return SwapResult(zero_for_one, gross, max_input - gross, q.creator_fee, q.lp_fee, q.output)

    @staticmethod
    def swap_exact_output(*_args):
        raise PoolError("ExactOutputUnsupported")

    # ------------------------------------------------------------ creator fees

    def claimable(self, index):
        _asset(index)
        return self.accrued[index] - self.delivered[index]

    def claim(self, index):
        """Permissionless claim; the fixed beneficiary is implied (no recipient is modelled)."""
        amount = self.claimable(index)
        if amount == 0:
            raise PoolError("NothingToClaim")
        new_delivered = list(self.delivered)
        new_delivered[index] += amount
        self.delivered = new_delivered
        return amount
