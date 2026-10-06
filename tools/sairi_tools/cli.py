"""Command-line entry point. Offline by default: reads local JSON files, never a wallet or key.

Only the explicitly named `testnet-*` commands touch the network, and only with read-only JSON-RPC calls /
a LayerZero Scan testnet GET restricted to the Base Sepolia <-> Robinhood testnet allowlist.
"""
import argparse
import datetime
import json
import re
import sys
import time

from . import config, demo, monitor, simulator, testnet
from .amm import Pool, PoolError, quote_exact_input
from .rpc import RpcClient
from .strict import StrictJSONError, load_path, parse_decimal


def _raw_int(text):
    if not re.fullmatch(r"\d+", text):
        raise argparse.ArgumentTypeError(f"expected a non-negative integer in raw units, got {text!r}")
    return int(text)


def _usd(text):
    try:
        return parse_decimal(text, simulator.USD_DECIMALS)
    except ValueError as err:
        raise argparse.ArgumentTypeError(str(err)) from err


def _emit(obj):
    print(json.dumps(obj, indent=2))


def cmd_validate_config(args):
    today = datetime.date.fromisoformat(args.today) if args.today else None
    try:
        report = config.validate(load_path(args.path), today=today).to_dict()
    except (OSError, StrictJSONError, ValueError) as err:
        report = {"environment": None, "status": "REJECTED", "issueCount": 1,
                  "issues": [{"path": "$", "code": "PARSE", "message": str(err)}]}
    report["file"] = args.path
    if args.expect_reject:
        report["gate"] = "EXPECTED_REJECT_PASSED" if report["status"] == "REJECTED" else "FAIL_OPEN_DETECTED"
        _emit(report)
        return 0 if report["status"] == "REJECTED" else 1
    _emit(report)
    return 0 if report["status"] == "VALID" else 1


def cmd_monitor(args):
    now = args.now if args.now is not None else int(time.time())
    try:
        result = monitor.evaluate(load_path(args.path), now)
    except (OSError, StrictJSONError, ValueError) as err:
        result = {"status": monitor.INVALID, "reasons": [{"code": "PARSE", "severity": monitor.INVALID,
                                                          "message": str(err)}]}
    result["file"] = args.path
    if args.expect:
        result["expected"] = args.expect
        _emit(result)
        return 0 if result["status"] == args.expect else 1
    _emit(result)
    return monitor.EXIT_CODES[result["status"]]


def cmd_simulate(args):
    try:
        report = simulator.simulate(
            total_usd=args.total_liquidity_usd, sairi_usd=args.sairi_usd, weth_usd=args.weth_usd,
            sairi_decimals=args.sairi_decimals, weth_decimals=args.weth_decimals,
            trades_usd=args.trade_usd or simulator.DEFAULT_TRADES_USD,
            reserve_sairi=args.reserve_sairi, reserve_weth=args.reserve_weth)
    except ValueError as err:
        _emit({"error": str(err)})
        return 2
    _emit(report)
    return 0 if all("error" not in c for c in report["cases"]) else 1


def cmd_quote(args):
    max_input = args.max_input if args.max_input is not None else args.gross
    try:
        q = quote_exact_input(args.gross, args.reserve_in, args.reserve_out)
        pool = Pool(reserve0=args.reserve_in, reserve1=args.reserve_out)
        swap = pool.swap_exact_input(True, args.gross, max_input, 0)
    except PoolError as err:
        _emit({"error": err.code})
        return 1
    _emit({"kind": "EXACT_INPUT_QUOTE_LOCAL_HARNESS", "grossInputRaw": str(q.gross),
           "consumedRaw": str(swap.consumed), "untouchedRaw": str(swap.untouched),
           "creatorFeeRaw": str(q.creator_fee), "lpFeeRaw": str(q.lp_fee), "netRaw": str(q.net),
           "outputRaw": str(q.output), "reserveInAfterRaw": str(pool.reserve0),
           "reserveOutAfterRaw": str(pool.reserve1)})
    return 0


def cmd_demo(_args):
    report = demo.run()
    _emit(report)
    return 0 if report["ok"] else 1


def _testnet_clients(cfg):
    chains = testnet.validate_config(cfg)
    return {key: RpcClient(chains[key]["rpc"]) for key in testnet.CHAIN_KEYS}


def _load_testnet_config(path):
    cfg = load_path(path)
    testnet.validate_config(cfg)
    return cfg


def cmd_testnet_preflight(args):
    try:
        cfg = _load_testnet_config(args.config)
        report = testnet.preflight(cfg, _testnet_clients(cfg))
    except (OSError, StrictJSONError, ValueError) as err:
        report = {"kind": "TESTNET_READ_ONLY_PREFLIGHT", "status": testnet.INVALID, "blockers": [str(err)]}
    if args.out:
        with open(args.out, "w", encoding="utf-8") as handle:
            handle.write(json.dumps(report, indent=2) + "\n")
    _emit(report)
    return 0 if report["status"] == testnet.READY else 1


def cmd_testnet_status(args):
    try:
        cfg = _load_testnet_config(args.config)
        report = testnet.status(cfg, load_path(args.deployments), _testnet_clients(cfg))
    except (OSError, StrictJSONError, ValueError) as err:
        report = {"kind": "TESTNET_DEPLOYMENT_STATUS", "status": testnet.INVALID, "blockers": [str(err)],
                  **testnet.STATUS_EVIDENCE_FLAGS}
    if args.expect:
        report["expected"] = args.expect
        _emit(report)
        return 0 if report["status"] == args.expect else 1
    _emit(report)
    # Fail closed: no status proves backing, so none exits 0 (UNKNOWN 4, BLOCKED 1, INVALID 5, NOT_DEPLOYED 6).
    return testnet.STATUS_EXIT_CODES[report["status"]]


def cmd_testnet_message(args):
    try:
        cfg = _load_testnet_config(args.config)
        report = testnet.fetch_message(cfg, args.tx_hash)
    except (OSError, StrictJSONError, ValueError) as err:
        report = {"kind": "LAYERZERO_SCAN_LOOKUP", "status": testnet.INVALID, "error": str(err)}
    _emit(report)
    # 0 only means the third-party indexer reports delivery on the pinned route; it is not proof (`proof: false`).
    return 0 if report["status"] == testnet.INDEXER_DELIVERED else 1


def build_parser():
    parser = argparse.ArgumentParser(prog="sairi", description="EXPERIMENTAL offline SAIRI harness tooling")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("validate-config", help="strictly validate a configuration file")
    p.add_argument("path")
    p.add_argument("--expect-reject", action="store_true", help="succeed only if the file is rejected (fail-closed gate)")
    p.add_argument("--today", help="override today's date (YYYY-MM-DD) for evidence date checks")
    p.set_defaults(func=cmd_validate_config)

    p = sub.add_parser("monitor", help="evaluate an L/R/P/Q accounting snapshot")
    p.add_argument("path")
    p.add_argument("--now", type=_raw_int, help="evaluation time, unix seconds (default: system clock)")
    p.add_argument("--expect", choices=monitor.PRECEDENCE, help="succeed only if this status is produced")
    p.set_defaults(func=cmd_monitor)

    p = sub.add_parser("simulate", help="synthetic constant-product buy/sell cost table")
    p.add_argument("--total-liquidity-usd", type=_usd, default=simulator.DEFAULT_TOTAL_LIQUIDITY_USD)
    p.add_argument("--sairi-usd", type=_usd, default=simulator.DEFAULT_SAIRI_USD)
    p.add_argument("--weth-usd", type=_usd, default=simulator.DEFAULT_WETH_USD)
    p.add_argument("--sairi-decimals", type=_raw_int, default=18)
    p.add_argument("--weth-decimals", type=_raw_int, default=18)
    p.add_argument("--trade-usd", type=_usd, action="append", help="repeatable; default 500 1000 5000 10000")
    p.add_argument("--reserve-sairi", type=_raw_int, help="explicit raw SAIRI reserve (requires --reserve-weth)")
    p.add_argument("--reserve-weth", type=_raw_int, help="explicit raw WETH reserve (requires --reserve-sairi)")
    p.set_defaults(func=cmd_simulate)

    p = sub.add_parser("quote", help="exact integer quote matching LocalConstantProductPool._quote")
    p.add_argument("--reserve-in", type=_raw_int, required=True)
    p.add_argument("--reserve-out", type=_raw_int, required=True)
    p.add_argument("--gross", type=_raw_int, required=True)
    p.add_argument("--max-input", type=_raw_int)
    p.set_defaults(func=cmd_quote)

    p = sub.add_parser("demo", help="synthetic L/R/P/Q roundtrip with swaps and claims reconciliation")
    p.set_defaults(func=cmd_demo)

    p = sub.add_parser("testnet-preflight", help="NETWORK, read-only: verify the pinned testnet LayerZero route")
    p.add_argument("config")
    p.add_argument("--out", help="also write the JSON evidence report to this path")
    p.set_defaults(func=cmd_testnet_preflight)

    p = sub.add_parser("testnet-status",
                       help="NETWORK, read-only: structural checks + raw observations (backing status is UNKNOWN)")
    p.add_argument("config")
    p.add_argument("deployments")
    p.add_argument("--expect", choices=sorted(testnet.STATUS_EXIT_CODES),
                   help="succeed only if this status is produced")
    p.set_defaults(func=cmd_testnet_status)

    p = sub.add_parser("testnet-message", help="NETWORK, read-only: LayerZero Scan testnet lookup by source tx")
    p.add_argument("config")
    p.add_argument("tx_hash")
    p.set_defaults(func=cmd_testnet_message)
    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
