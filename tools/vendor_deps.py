"""Pinned Solidity dependency vendoring and offline verification (standard library only).

Third-party Solidity sources are vendored verbatim under `dependencies/<dir>/` (default `<dir>` is the npm
package name) from npm registry tarballs pinned by exact version and Subresource-Integrity (sha512) digest
in `dependencies/lock.json`. Only the import closure of the declared entrypoints plus each package's
license/metadata files are extracted; every vendored file is pinned by sha256.

A package may declare `importRemap` (prefix -> prefix) applied to non-relative imports inside its own files,
mirroring a Foundry context remapping (e.g. LayerZero protocol code built against OpenZeppelin 4.x while the
OApp/OFT layer uses 5.x). `verify` checks that foundry.toml carries exactly the derived remappings.

Full upstream license texts live in `licenses/` (pinned by commit, sha256 and git blob id in
`licenses/lock.json`). A package's `licenseTexts` are copied verbatim into its vendored directory so every
copy carries its license, and every vendored Solidity file's SPDX license must have a full text there.

  python3.12 tools/vendor_deps.py verify          # offline: tree == lock, imports resolve, SPDX, remappings
  python3.12 tools/vendor_deps.py fetch           # network: re-download, check integrity, rewrite tree
  python3.12 tools/vendor_deps.py list PACKAGE    # network: list files in a pinned tarball

No git submodules, symlinks or package-manager installs are used. Vendored files are never modified.
"""
import argparse
import base64
import hashlib
import io
import json
import pathlib
import posixpath
import re
import shutil
import sys
import tarfile
import tomllib
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
DEPS = ROOT / "dependencies"
LOCK = DEPS / "lock.json"
LICENSES = ROOT / "licenses"
LICENSE_LOCK = LICENSES / "lock.json"
LICENSE_DIR_EXTRAS = {"README.md", "lock.json"}
RAW_GITHUB_RE = re.compile(r"https://raw\.githubusercontent\.com/[\w.-]+/[\w.-]+/([0-9a-f]{40})/(.+)")
FOUNDRY_TOML = ROOT / "foundry.toml"
LOCAL_SOURCE_DIRS = ("src", "test", "script")
META_FILES = re.compile(r"^(LICENSE[^/]*|LICENCE[^/]*|COPYING[^/]*|NOTICE[^/]*|package\.json)$", re.I)
IMPORT_RE = re.compile(r"""^\s*import\s+(?:[^;"']*?\s+from\s+)?["']([^"']+)["']\s*;""", re.M)
SPDX_RE = re.compile(r"SPDX-License-Identifier:\s*([^\s*]+)")
REGISTRY = "https://registry.npmjs.org/"


class VendorError(Exception):
    pass


def load_lock():
    with open(LOCK, encoding="utf-8") as handle:
        return json.load(handle)


def load_license_lock():
    with open(LICENSE_LOCK, encoding="utf-8") as handle:
        return json.load(handle)


def license_texts():
    """{file name: bytes} for every file in licenses/ except the README and lock."""
    out = {}
    for path in sorted(LICENSES.iterdir()):
        if path.is_symlink():
            raise VendorError(f"symlink prohibited: {path.relative_to(ROOT)}")
        if path.is_file() and path.name not in LICENSE_DIR_EXTRAS:
            out[path.name] = path.read_bytes()
    return out


def git_blob_sha(data):
    return hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()


def verify_licenses(license_lock, texts):
    """Pinned upstream license texts: exact set, sha256, git blob id and pinned raw-GitHub provenance."""
    problems = []
    entries = {e["file"]: e for e in license_lock.get("files", [])}
    for name in sorted(set(entries) | set(texts)):
        if name not in texts:
            problems.append(f"licenses/{name} missing")
            continue
        if name not in entries:
            problems.append(f"licenses/{name} not pinned in licenses/lock.json")
            continue
        e, data = entries[name], texts[name]
        if hashlib.sha256(data).hexdigest() != e.get("sha256"):
            problems.append(f"licenses/{name}: sha256 mismatch")
        if git_blob_sha(data) != e.get("gitBlobSha"):
            problems.append(f"licenses/{name}: git blob sha differs from upstream")
        match = RAW_GITHUB_RE.fullmatch(e.get("url", ""))
        if not match or match.group(1) != e.get("commit") or match.group(2) != e.get("path"):
            problems.append(f"licenses/{name}: url must be raw GitHub pinned to the recorded commit and path")
    return problems


def pkg_dir(pkg):
    return pkg.get("dir", pkg["name"])


def _owner(path, dirs):
    """Longest vendored directory that prefixes `path`."""
    best = None
    for d in dirs:
        if path.startswith(d + "/") and (best is None or len(d) > len(best)):
            best = d
    return best


def _remaps(lock):
    """{package dir: [(from_prefix, to_prefix), ...]} for context-specific import remapping."""
    return {pkg_dir(p): sorted(p.get("importRemap", {}).items(), key=lambda kv: -len(kv[0])) for p in lock["packages"]}


def resolve_import(importer, target, lock):
    """Resolves an import inside vendored file `importer` to a vendored path `<dir>/<file>`."""
    if target.startswith("."):
        resolved = posixpath.normpath(posixpath.join(posixpath.dirname(importer), target))
    else:
        resolved = posixpath.normpath(target)
        owner = _owner(importer, [pkg_dir(p) for p in lock["packages"]])
        for prefix, replacement in _remaps(lock).get(owner, []):
            if resolved.startswith(prefix):
                resolved = replacement + resolved[len(prefix):]
                break
    if resolved.startswith("../") or resolved.startswith("/"):
        raise VendorError(f"{importer}: import escapes root: {target}")
    return resolved


def imports_of(text):
    return IMPORT_RE.findall(text)


def expected_remappings(lock):
    """Foundry remapping lines implied by the lock (global by package name, plus context remaps)."""
    lines = []
    for pkg in lock["packages"]:
        if "dir" not in pkg:
            lines.append(f"{pkg['name']}/=dependencies/{pkg['name']}/")
    for pkg in lock["packages"]:
        for prefix, replacement in sorted(pkg.get("importRemap", {}).items()):
            lines.append(f"dependencies/{pkg_dir(pkg)}/:{prefix}=dependencies/{replacement}")
    return lines


def _verify_integrity(blob, integrity):
    algo, _, digest = integrity.partition("-")
    if algo != "sha512":
        raise VendorError(f"unsupported integrity algorithm {algo!r}")
    actual = base64.b64encode(hashlib.sha512(blob).digest()).decode()
    if actual != digest:
        raise VendorError(f"integrity mismatch: expected {integrity}, got sha512-{actual}")


def _tarball_url(pkg):
    name, version = pkg["name"], pkg["version"]
    expected = f"{REGISTRY}{name}/-/{name.split('/')[-1]}-{version}.tgz"
    if pkg["tarball"] != expected:
        raise VendorError(f"{name}: tarball URL must be the canonical registry URL {expected}")
    return expected


def download(pkg):
    url = _tarball_url(pkg)
    request = urllib.request.Request(url, headers={"User-Agent": "sairi-vendor-deps"})
    with urllib.request.urlopen(request, timeout=120) as response:  # noqa: S310 - pinned https URL
        blob = response.read()
    _verify_integrity(blob, pkg["integrity"])
    files = {}
    with tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz") as archive:
        for member in archive.getmembers():
            if not member.isfile():
                continue
            if not member.name.startswith("package/"):
                raise VendorError(f"{pkg['name']}: unexpected tar member {member.name}")
            rel = posixpath.normpath(member.name[len("package/"):])
            if rel.startswith("..") or rel.startswith("/"):
                raise VendorError(f"{pkg['name']}: unsafe tar path {member.name}")
            files[rel] = archive.extractfile(member).read()
    return files


def closure(lock, contents):
    """Import closure of the entrypoints. `contents` maps `<dir>/<file>` -> bytes."""
    dirs = [pkg_dir(p) for p in lock["packages"]]
    pending = list(lock["entrypoints"])
    seen = set()
    while pending:
        path = pending.pop()
        if path in seen:
            continue
        if _owner(path, dirs) is None:
            raise VendorError(f"import {path} is not provided by a pinned package")
        if path not in contents:
            raise VendorError(f"import {path} missing from pinned package contents")
        seen.add(path)
        for target in imports_of(contents[path].decode("utf-8")):
            pending.append(resolve_import(path, target, lock))
    return seen


def cmd_fetch(_args):
    lock = load_lock()
    contents = {}
    meta = set()
    for pkg in lock["packages"]:
        for rel, data in download(pkg).items():
            key = f"{pkg_dir(pkg)}/{rel}"
            contents[key] = data
            if "/" not in rel and META_FILES.match(rel):
                meta.add(key)
    selected = closure(lock, contents) | meta
    texts = license_texts()
    problems = verify_licenses(load_license_lock(), texts)
    if problems:
        raise VendorError("; ".join(problems))
    for pkg in lock["packages"]:
        for name in pkg.get("licenseTexts", []):
            key = f"{pkg_dir(pkg)}/{name}"
            if key in contents:
                raise VendorError(f"{key}: would overwrite an upstream file")
            contents[key] = texts[name]
            selected.add(key)
    if DEPS.exists():
        for child in DEPS.iterdir():
            if child.name != "lock.json":
                shutil.rmtree(child) if child.is_dir() else child.unlink()
    hashes = {}
    for key in sorted(selected):
        target = DEPS / key
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(contents[key])
        hashes[key] = hashlib.sha256(contents[key]).hexdigest()
    lock["files"] = hashes
    LOCK.write_text(json.dumps(lock, indent=2) + "\n", encoding="utf-8")
    print(f"Vendored {len(hashes)} files from {len(lock['packages'])} pinned packages.")
    return 0


def vendored_tree():
    out = {}
    for path in sorted(DEPS.rglob("*")):
        if path.is_symlink():
            raise VendorError(f"symlink prohibited: {path.relative_to(ROOT)}")
        if path.is_file() and path != LOCK:
            out[path.relative_to(DEPS).as_posix()] = path.read_bytes()
    return out


def _foundry_remappings():
    with open(FOUNDRY_TOML, "rb") as handle:
        return tomllib.load(handle).get("profile", {}).get("default", {}).get("remappings", [])


def verify(lock=None, tree=None, local_sources=None, remappings=None, license_lock=None, texts=None):
    """Offline verification. Returns a list of problems (empty means verified)."""
    lock = lock if lock is not None else load_lock()
    tree = tree if tree is not None else vendored_tree()
    license_lock = license_lock if license_lock is not None else load_license_lock()
    texts = texts if texts is not None else license_texts()
    problems = verify_licenses(license_lock, texts)
    text_license = {e["file"]: e["license"] for e in license_lock.get("files", [])}
    for pkg in lock["packages"]:
        d, names = pkg_dir(pkg), pkg.get("licenseTexts", [])
        covered = set()
        for name in names:
            if name not in texts:
                problems.append(f"{pkg['name']}: license text {name} not in licenses/")
                continue
            covered.add(text_license.get(name))
            if tree.get(f"{d}/{name}") != texts[name]:
                problems.append(f"{pkg['name']}: {d}/{name} missing or differs from licenses/{name}")
        has_own_license = any(k.startswith(d + "/") and "/" not in k[len(d) + 1:]
                              and k.rsplit("/", 1)[1].upper().startswith("LICENSE") and k.rsplit("/", 1)[1] not in names
                              for k in tree)
        for key, data in tree.items():
            if key.startswith(d + "/") and key.endswith(".sol"):
                match = SPDX_RE.search(data.decode("utf-8", "replace"))
                spdx = match.group(1) if match else None
                if names and spdx not in covered:
                    problems.append(f"{key}: SPDX {spdx} has no full license text in its package directory")
                elif not names and not has_own_license:
                    problems.append(f"{key}: package {pkg['name']} ships no license text")
    dirs = [pkg_dir(p) for p in lock["packages"]]
    if len(set(dirs)) != len(dirs):
        problems.append("duplicate vendored package directory")
    for pkg in lock["packages"]:
        try:
            _tarball_url(pkg)
        except VendorError as err:
            problems.append(str(err))
        if not re.fullmatch(r"\d+\.\d+\.\d+", pkg["version"]):
            problems.append(f"{pkg['name']}: version {pkg['version']!r} is not an exact pin")
        if not pkg["integrity"].startswith("sha512-"):
            problems.append(f"{pkg['name']}: integrity must be sha512")
        manifest = tree.get(f"{pkg_dir(pkg)}/package.json")
        if manifest is None:
            problems.append(f"{pkg['name']}: package.json not vendored")
        else:
            declared = json.loads(manifest)
            if (declared.get("name"), declared.get("version"), declared.get("license")) != (
                    pkg["name"], pkg["version"], pkg["license"]):
                problems.append(f"{pkg['name']}: package.json name/version/license differ from lock")
    expected = lock.get("files", {})
    for key in sorted(set(expected) | set(tree)):
        if key not in tree:
            problems.append(f"missing vendored file {key}")
        elif key not in expected:
            problems.append(f"unpinned vendored file {key}")
        elif hashlib.sha256(tree[key]).hexdigest() != expected[key]:
            problems.append(f"hash mismatch {key}")
    for key, data in tree.items():
        if not key.endswith(".sol"):
            continue
        text = data.decode("utf-8")
        if not SPDX_RE.search(text):
            problems.append(f"{key}: missing SPDX identifier")
        for target in imports_of(text):
            try:
                resolved = resolve_import(key, target, lock)
            except VendorError as err:
                problems.append(str(err))
                continue
            if resolved not in tree:
                problems.append(f"{key}: unresolved import {target}")
    public = [p["name"] for p in lock["packages"] if "dir" not in p]
    for rel, text in (local_sources if local_sources is not None else _local_sources()).items():
        for target in imports_of(text):
            if target.startswith("."):
                continue
            if _owner(target, public) is None:
                problems.append(f"{rel}: import {target} is not from a pinned package")
            elif posixpath.normpath(target) not in tree:
                problems.append(f"{rel}: import {target} is not vendored")
    actual = remappings if remappings is not None else _foundry_remappings()
    if sorted(actual) != sorted(expected_remappings(lock)):
        problems.append(f"foundry.toml remappings must be exactly {expected_remappings(lock)}")
    return problems


def _local_sources():
    out = {}
    for directory in LOCAL_SOURCE_DIRS:
        base = ROOT / directory
        if base.exists():
            for path in sorted(base.rglob("*.sol")):
                out[path.relative_to(ROOT).as_posix()] = path.read_text(encoding="utf-8")
    return out


def license_summary(tree=None):
    tree = tree if tree is not None else vendored_tree()
    summary = {}
    for key, data in tree.items():
        if key.endswith(".sol"):
            match = SPDX_RE.search(data.decode("utf-8"))
            summary.setdefault(match.group(1) if match else "MISSING", []).append(key)
    return summary


def cmd_verify(_args):
    try:
        problems = verify()
    except VendorError as err:
        problems = [str(err)]
    if problems:
        for problem in problems:
            print(f"FAIL {problem}", file=sys.stderr)
        return 1
    lock = load_lock()
    counts = {k: len(v) for k, v in sorted(license_summary().items())}
    print(f"Dependency lock verified: {len(lock['files'])} files, {len(lock['packages'])} packages, "
          f"SPDX {json.dumps(counts, sort_keys=True)}.")
    return 0


def cmd_list(args):
    lock = load_lock()
    pkg = next((p for p in lock["packages"] if pkg_dir(p) == args.package), None)
    if pkg is None:
        print(f"unknown package {args.package}", file=sys.stderr)
        return 1
    for rel in sorted(download(pkg)):
        print(rel)
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("verify").set_defaults(func=cmd_verify)
    sub.add_parser("fetch").set_defaults(func=cmd_fetch)
    listing = sub.add_parser("list")
    listing.add_argument("package")
    listing.set_defaults(func=cmd_list)
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except VendorError as err:
        print(f"FAIL {err}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
