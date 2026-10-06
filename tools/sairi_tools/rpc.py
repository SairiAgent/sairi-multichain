"""Minimal read-only JSON-RPC client and ABI helpers (standard library only).

Only `eth_chainId`, `eth_blockNumber`, `eth_getBlockByNumber`, `eth_getCode` and `eth_call` are issued.
There is no signing, no `eth_sendRawTransaction` and no key handling anywhere in this module.
"""
import json
import urllib.parse
import urllib.request

from .keccak import keccak256, selector

READ_ONLY_METHODS = frozenset({"eth_chainId", "eth_blockNumber", "eth_getBlockByNumber", "eth_getCode", "eth_call"})


class RpcError(Exception):
    pass


def validate_public_url(url):
    """Accepts only credential-free https URLs without query strings or fragments."""
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != "https" or not parsed.hostname:
        raise ValueError(f"RPC URL must be https: {url!r}")
    if parsed.username or parsed.password or "@" in parsed.netloc:
        raise ValueError("RPC URL must not embed credentials")
    if parsed.query or parsed.fragment:
        raise ValueError("RPC URL must not carry a query string or fragment (possible API key)")
    return url


class RpcClient:
    def __init__(self, url, timeout=30, transport=None):
        self.url = validate_public_url(url)
        self.timeout = timeout
        self._transport = transport or self._http
        self._id = 0

    def _http(self, payload):
        request = urllib.request.Request(
            self.url,
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json", "Accept": "application/json", "User-Agent": "sairi-tools"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:  # noqa: S310 - https only
                return json.loads(response.read())
        except (OSError, ValueError) as err:  # URLError/TimeoutError/connection resets are OSError; bad JSON is ValueError
            raise RpcError(f"{self.url}: {err}") from err

    def call(self, method, params):
        if method not in READ_ONLY_METHODS:
            raise RpcError(f"method {method} is not on the read-only allowlist")
        self._id += 1
        reply = self._transport({"jsonrpc": "2.0", "id": self._id, "method": method, "params": params})
        if not isinstance(reply, dict) or "error" in reply or "result" not in reply:
            raise RpcError(f"{method}: {reply.get('error') if isinstance(reply, dict) else reply}")
        return reply["result"]

    def chain_id(self):
        return int(self.call("eth_chainId", []), 16)

    def block_number(self):
        return int(self.call("eth_blockNumber", []), 16)

    def block_hash(self, number):
        block = self.call("eth_getBlockByNumber", [hex(number), False])
        if not block or "hash" not in block:
            raise RpcError(f"block {number} unavailable")
        return block["hash"]

    def code(self, address, block):
        return bytes.fromhex(self.call("eth_getCode", [address, hex(block)]).removeprefix("0x"))

    def eth_call(self, to, data, block):
        result = self.call("eth_call", [{"to": to, "data": "0x" + data.hex()}, hex(block)])
        return bytes.fromhex(result.removeprefix("0x"))


# ---------------------------------------------------------------------- ABI


def enc_uint(value):
    if not isinstance(value, int) or isinstance(value, bool) or not 0 <= value < 2**256:
        raise ValueError(f"bad uint {value!r}")
    return value.to_bytes(32, "big")


def enc_address(address):
    raw = bytes.fromhex(address.removeprefix("0x"))
    if len(raw) != 20:
        raise ValueError(f"bad address {address!r}")
    return raw.rjust(32, b"\0")


def enc_bytes(data):
    padded = data + b"\0" * (-len(data) % 32)
    return enc_uint(len(data)) + padded


def calldata(signature, *words):
    return selector(signature) + b"".join(words)


def word(data, index):
    chunk = data[32 * index:32 * index + 32]
    if len(chunk) != 32:
        raise RpcError("short ABI return data")
    return chunk


def dec_uint(data, index=0):
    return int.from_bytes(word(data, index), "big")


def dec_address(data, index=0):
    raw = word(data, index)
    if any(raw[:12]):
        raise RpcError("dirty address word")
    return "0x" + raw[12:].hex()


def dec_bool(data, index=0):
    value = dec_uint(data, index)
    if value > 1:
        raise RpcError("bad bool")
    return value == 1


def _dec_address_array(data, offset):
    length = int.from_bytes(data[offset:offset + 32], "big")
    if length > 255 or offset + 32 * (length + 1) > len(data):
        raise RpcError("bad address array")
    return [dec_address(data[offset + 32:], i) for i in range(length)]


def dec_uln_config(data):
    """ABI-decodes a returned `UlnConfig` struct (dynamic tuple)."""
    base = dec_uint(data, 0)
    struct = data[base:]
    return {
        "confirmations": dec_uint(struct, 0),
        "requiredDVNCount": dec_uint(struct, 1),
        "optionalDVNCount": dec_uint(struct, 2),
        "optionalDVNThreshold": dec_uint(struct, 3),
        "requiredDVNs": _dec_address_array(struct, dec_uint(struct, 4)),
        "optionalDVNs": _dec_address_array(struct, dec_uint(struct, 5)),
    }


def quote_calldata(dst_eid, receiver32, message, options, sender):
    """`quote((uint32,bytes32,bytes,bytes,bool),address)` calldata for EndpointV2."""
    head = enc_uint(dst_eid) + receiver32 + enc_uint(5 * 32)
    message_part = enc_bytes(message)
    head += enc_uint(5 * 32 + len(message_part)) + enc_uint(0)
    tuple_bytes = head + message_part + enc_bytes(options)
    return calldata("quote((uint32,bytes32,bytes,bytes,bool),address)", enc_uint(64), enc_address(sender)) + tuple_bytes


def code_hash(code):
    return "0x" + keccak256(code).hex()
