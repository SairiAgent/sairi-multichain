"""Pure-Python Keccak-256 (the pre-NIST padding used by Ethereum), standard library only.

Used for function selectors, runtime code hashes and EIP-55 checksums. Slow but adequate for tooling.
`hashlib.sha3_256` is NOT a substitute: it uses the NIST SHA-3 padding and yields different digests.
"""

_RC = [
    0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
    0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
    0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
    0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
    0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
    0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
]
_ROT = [
    [0, 36, 3, 41, 18],
    [1, 44, 10, 45, 2],
    [62, 6, 43, 15, 61],
    [28, 55, 25, 21, 56],
    [27, 20, 39, 8, 14],
]
_MASK = (1 << 64) - 1
_RATE = 136


def _rotl(value, shift):
    return ((value << shift) | (value >> (64 - shift))) & _MASK if shift else value


def _permute(state):
    for rc in _RC:
        c = [state[x][0] ^ state[x][1] ^ state[x][2] ^ state[x][3] ^ state[x][4] for x in range(5)]
        d = [c[(x - 1) % 5] ^ _rotl(c[(x + 1) % 5], 1) for x in range(5)]
        for x in range(5):
            for y in range(5):
                state[x][y] ^= d[x]
        b = [[0] * 5 for _ in range(5)]
        for x in range(5):
            for y in range(5):
                b[y][(2 * x + 3 * y) % 5] = _rotl(state[x][y], _ROT[x][y])
        for x in range(5):
            for y in range(5):
                state[x][y] = b[x][y] ^ ((~b[(x + 1) % 5][y]) & b[(x + 2) % 5][y])
        state[0][0] ^= rc


def keccak256(data):
    """Keccak-256 digest (32 bytes) of `data` (bytes)."""
    if not isinstance(data, (bytes, bytearray)):
        raise TypeError("keccak256 expects bytes")
    padded = bytearray(data)
    padded.append(0x01)
    while len(padded) % _RATE:
        padded.append(0)
    padded[-1] |= 0x80
    state = [[0] * 5 for _ in range(5)]
    for offset in range(0, len(padded), _RATE):
        block = padded[offset:offset + _RATE]
        for i in range(_RATE // 8):
            lane = int.from_bytes(block[8 * i:8 * i + 8], "little")
            state[i % 5][i // 5] ^= lane
        _permute(state)
    out = bytearray()
    for i in range(4):
        out += state[i % 5][i // 5].to_bytes(8, "little")
    return bytes(out)


def selector(signature):
    """4-byte function selector for a canonical signature such as `eid()`."""
    return keccak256(signature.encode("ascii"))[:4]


def to_checksum_address(address):
    """EIP-55 checksum of a 0x-prefixed 20-byte hex address."""
    hex_part = address.lower().removeprefix("0x")
    if len(hex_part) != 40 or any(c not in "0123456789abcdef" for c in hex_part):
        raise ValueError(f"not a 20-byte hex address: {address!r}")
    digest = keccak256(hex_part.encode("ascii")).hex()
    return "0x" + "".join(c.upper() if c.isalpha() and int(digest[i], 16) >= 8 else c for i, c in enumerate(hex_part))
