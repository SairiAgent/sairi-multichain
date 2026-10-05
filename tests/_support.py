"""Shared test helpers. Puts tools/ on sys.path so `sairi_tools` imports without installation."""
import contextlib
import io
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
if str(ROOT / "tools") not in sys.path:
    sys.path.insert(0, str(ROOT / "tools"))

LOCAL_CONFIG = ROOT / "config" / "local" / "local-mock.json"
LIVE_CONFIG = ROOT / "config" / "networks" / "live.json"
MONITOR_NOW = 1_700_000_600


def fixture(name):
    return ROOT / "config" / "local" / name


def run_cli(*argv):
    """Runs the CLI in-process; returns (exit_code, parsed JSON stdout)."""
    import json

    from sairi_tools.cli import main

    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        code = main([str(a) for a in argv])
    return code, json.loads(out.getvalue())


def assert_no_floats(testcase, obj):
    if isinstance(obj, dict):
        for value in obj.values():
            assert_no_floats(testcase, value)
    elif isinstance(obj, list):
        for value in obj:
            assert_no_floats(testcase, value)
    else:
        testcase.assertNotIsInstance(obj, float)
