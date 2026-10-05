"""Strict JSON loading and type predicates shared by the validators.

`bool` is a subclass of `int` in Python, so every integer check here excludes it explicitly.
Floats, NaN/Infinity and duplicate object keys are rejected at parse time.
"""
import json
import re
from fractions import Fraction

ADDRESS_RE = re.compile(r"0x[0-9a-f]{40}")
ZERO_ADDRESS = "0x" + "0" * 40
DATE_RE = re.compile(r"\d{4}-\d{2}-\d{2}")


class StrictJSONError(ValueError):
    pass


def _reject_constant(name):
    raise StrictJSONError(f"non-finite number {name} is not allowed")


def _reject_float(text):
    raise StrictJSONError(f"non-integer number {text} is not allowed; use integers in base units")


def _unique_pairs(pairs):
    out = {}
    for key, value in pairs:
        if key in out:
            raise StrictJSONError(f"duplicate key {key!r}")
        out[key] = value
    return out


def loads(text):
    return json.loads(
        text,
        object_pairs_hook=_unique_pairs,
        parse_float=_reject_float,
        parse_constant=_reject_constant,
    )


def load_path(path):
    with open(path, "r", encoding="utf-8") as handle:
        return loads(handle.read())


def is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


def is_uint(value, bits=256):
    return is_int(value) and 0 <= value < 2**bits


def is_nonzero_address(value):
    """Lowercase 0x-prefixed 20-byte hex, not the zero address.

    EIP-55 checksums need keccak-256, which the standard library lacks, so mixed case is rejected
    rather than accepted unchecked.
    """
    return isinstance(value, str) and ADDRESS_RE.fullmatch(value) is not None and value != ZERO_ADDRESS


def parse_decimal(text, places):
    """Exact decimal string -> integer scaled by 10**places. Rejects floats, exponents and excess digits."""
    if not isinstance(text, str) or not re.fullmatch(r"\d+(\.\d+)?", text):
        raise ValueError(f"expected a non-negative decimal string, got {text!r}")
    whole, _, frac = text.partition(".")
    if len(frac) > places:
        raise ValueError(f"{text!r} has more than {places} fractional digits")
    return int(whole) * 10**places + int(frac.ljust(places, "0") or "0")


def format_fraction(value, places):
    """Render a Fraction (or int) as a decimal string, rounded half away from zero at `places` digits."""
    value = Fraction(value)
    scaled = abs(value) * 10**places
    units = scaled.numerator // scaled.denominator
    if (scaled - units) * 2 >= 1:
        units += 1
    sign = "-" if value < 0 and units != 0 else ""
    if places == 0:
        return f"{sign}{units}"
    digits = str(units).rjust(places + 1, "0")
    return f"{sign}{digits[:-places]}.{digits[-places:]}"


def format_units(raw, decimals):
    """Exact rendering of an integer amount with `decimals` implied places (no rounding)."""
    return format_fraction(Fraction(raw, 10**decimals), decimals)
