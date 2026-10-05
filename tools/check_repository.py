"""Conservative publication guard; not a substitute for human diff review."""
import pathlib
import re
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
PATTERNS = [
    re.compile(rb"gh[pousr]_" + rb"[A-Za-z0-9]{30,}"),
    re.compile(rb"github_pat_" + rb"[A-Za-z0-9_]{30,}"),
    re.compile(rb"-----BEGIN " + rb"(?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    re.compile(rb"https?://[^\s/]+:[^\s/@]+@"),
    re.compile(rb"(?i)(?:private_key|mnemonic|seed_phrase|api_key)\s*[=:]\s*[\"']?[A-Za-z0-9 /+]{24,}"),
]


def check(name, data):
    assert len(data) < 1_000_000, f"Oversized publication candidate: {name}"
    assert not any(pattern.search(data) for pattern in PATTERNS), f"Potential secret: {name}"
    assert not any(part in {'.openclaw', '.claude', 'runtime'} for part in pathlib.PurePosixPath(name).parts), name
    assert not pathlib.PurePosixPath(name).name.startswith('.env') or name == '.env.example', name


def main():
    paths = sorted(p for p in ROOT.rglob('*') if '.git' not in p.relative_to(ROOT).parts)
    count = 0
    for path in paths:
        assert not path.is_symlink(), f"Symlink prohibited: {path}"
        if path.is_file() and not any(x in path.relative_to(ROOT).parts for x in ['__pycache__', 'out', 'cache', 'node_modules']):
            check(str(path.relative_to(ROOT)), path.read_bytes())
            count += 1
    if (ROOT / '.git').exists():
        result = subprocess.run(['git', 'rev-list', '--objects', '--all'], cwd=ROOT, capture_output=True, text=True, check=True)
        for line in result.stdout.splitlines():
            oid, _, name = line.partition(' ')
            kind = subprocess.check_output(['git', 'cat-file', '-t', oid], cwd=ROOT).strip()
            if kind == b'blob':
                check(name, subprocess.check_output(['git', 'cat-file', '-p', oid], cwd=ROOT))
        modes = subprocess.check_output(['git', 'ls-files', '--stage'], cwd=ROOT, text=True)
        assert not any(line.startswith(('120000 ', '160000 ')) for line in modes.splitlines()), 'Symlink/submodule prohibited'
    assert 'THE SOFTWARE IS PROVIDED "AS IS"' in (ROOT / 'LICENSE').read_text()
    assert 'EXPERIMENTAL' in (ROOT / 'README.md').read_text()
    print(f'Publication guard passed: {count} working files and reachable Git blobs checked.')


if __name__ == '__main__':
    main()
