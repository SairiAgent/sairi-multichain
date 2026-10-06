"""Offline tests for the pinned-dependency verifier (no network; `fetch` is not exercised)."""
import copy
import hashlib
import importlib.util
import json
import unittest

import _support

_spec = importlib.util.spec_from_file_location("vendor_deps", _support.ROOT / "tools" / "vendor_deps.py")
vendor_deps = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(vendor_deps)


class RepositoryLockTest(unittest.TestCase):
    def test_repository_tree_verifies(self):
        self.assertEqual(vendor_deps.verify(), [])

    def test_pins_and_licenses(self):
        lock = vendor_deps.load_lock()
        names = {p["name"]: p for p in lock["packages"]}
        self.assertEqual(names["@layerzerolabs/oft-evm"]["version"], "4.0.1")
        self.assertEqual(names["@layerzerolabs/lz-evm-protocol-v2"]["license"], "LZBL-1.2")
        self.assertEqual(names["@openzeppelin/contracts"]["version"], "4.9.6")
        summary = vendor_deps.license_summary()
        self.assertEqual(set(summary), {"MIT", "LZBL-1.2", "Unlicense", "BUSL-1.1", "AGPL-3.0-only"})
        # Deployable OFT code paths are MIT except the LZBL-1.2 PacketV1Codec pulled in upstream by OFTCore.
        lzbl = set(summary["LZBL-1.2"])
        self.assertIn("@layerzerolabs/lz-evm-protocol-v2/contracts/messagelib/libs/PacketV1Codec.sol", lzbl)
        self.assertNotIn("@layerzerolabs/oft-evm/contracts/OFTAdapter.sol", lzbl)


class TamperDetectionTest(unittest.TestCase):
    def setUp(self):
        self.lock = vendor_deps.load_lock()
        self.tree = vendor_deps.vendored_tree()
        self.remaps = vendor_deps.expected_remappings(self.lock)

    def _problems(self, lock=None, tree=None, local=None, remaps=None):
        return vendor_deps.verify(lock if lock is not None else self.lock, tree if tree is not None else self.tree,
                                  local if local is not None else {}, remaps if remaps is not None else self.remaps)

    def test_clean_inputs_pass(self):
        self.assertEqual(self._problems(), [])

    def test_modified_file_detected(self):
        tree = dict(self.tree)
        key = "@layerzerolabs/oft-evm/contracts/OFTAdapter.sol"
        tree[key] = tree[key] + b"\n// tampered\n"
        self.assertTrue(any("hash mismatch" in p for p in self._problems(tree=tree)))

    def test_extra_and_missing_files_detected(self):
        tree = dict(self.tree)
        tree["@layerzerolabs/oft-evm/contracts/Evil.sol"] = b"// SPDX-License-Identifier: MIT\n"
        self.assertTrue(any("unpinned" in p for p in self._problems(tree=tree)))
        tree = dict(self.tree)
        tree.pop("@layerzerolabs/oft-evm/contracts/OFT.sol")
        problems = self._problems(tree=tree)
        self.assertTrue(any("missing vendored file" in p for p in problems))

    def test_unresolved_import_and_missing_spdx_detected(self):
        tree = dict(self.tree)
        lock = copy.deepcopy(self.lock)
        key = "@layerzerolabs/oft-evm/contracts/Extra.sol"
        tree[key] = b'pragma solidity ^0.8.0;\nimport "./Nope.sol";\n'
        lock["files"][key] = hashlib.sha256(tree[key]).hexdigest()
        problems = self._problems(lock=lock, tree=tree)
        self.assertTrue(any("unresolved import" in p for p in problems))
        self.assertTrue(any("missing SPDX" in p for p in problems))

    def test_loose_pins_and_bad_urls_detected(self):
        lock = copy.deepcopy(self.lock)
        lock["packages"][0]["version"] = "^4.0.1"
        lock["packages"][1]["tarball"] = "https://evil.example/oapp.tgz"
        lock["packages"][2]["integrity"] = "sha1-abc"
        problems = self._problems(lock=lock)
        self.assertTrue(any("exact pin" in p for p in problems))
        self.assertTrue(any("canonical registry URL" in p for p in problems))
        self.assertTrue(any("sha512" in p for p in problems))

    def test_manifest_license_mismatch_detected(self):
        tree = dict(self.tree)
        key = "@layerzerolabs/oft-evm/package.json"
        manifest = json.loads(tree[key])
        manifest["license"] = "GPL-3.0"
        tree[key] = json.dumps(manifest).encode()
        lock = copy.deepcopy(self.lock)
        lock["files"][key] = hashlib.sha256(tree[key]).hexdigest()
        self.assertTrue(any("license differ" in p for p in self._problems(lock=lock, tree=tree)))

    def test_local_imports_must_be_pinned_and_remappings_exact(self):
        local = {"src/X.sol": 'import {A} from "forge-std/Test.sol";\nimport {B} from "@openzeppelin/contracts/Nope.sol";\n'}
        problems = self._problems(local=local)
        self.assertTrue(any("not from a pinned package" in p for p in problems))
        self.assertTrue(any("is not vendored" in p for p in problems))
        self.assertTrue(any("remappings" in p for p in self._problems(remaps=self.remaps[:-1])))

    def test_integrity_check(self):
        blob = b"payload"
        import base64
        good = "sha512-" + base64.b64encode(hashlib.sha512(blob).digest()).decode()
        vendor_deps._verify_integrity(blob, good)
        with self.assertRaises(vendor_deps.VendorError):
            vendor_deps._verify_integrity(blob + b"x", good)
        with self.assertRaises(vendor_deps.VendorError):
            vendor_deps._verify_integrity(blob, "sha1-" + good[7:])

    def test_context_import_remap(self):
        lock = {"packages": [{"name": "a", "version": "1.0.0", "importRemap": {"x/": "x-old/"}},
                             {"name": "x", "version": "2.0.0"}, {"name": "x", "version": "1.0.0", "dir": "x-old"}]}
        self.assertEqual(vendor_deps.resolve_import("a/c/File.sol", "x/Y.sol", lock), "x-old/Y.sol")
        self.assertEqual(vendor_deps.resolve_import("x/c/File.sol", "x/Y.sol", lock), "x/Y.sol")
        self.assertEqual(vendor_deps.expected_remappings(lock), ["a/=dependencies/a/", "x/=dependencies/x/",
                                                                 "dependencies/a/:x/=dependencies/x-old/"])
        with self.assertRaises(vendor_deps.VendorError):
            vendor_deps.resolve_import("a/File.sol", "../../etc/passwd", lock)


class LicenseTextTest(unittest.TestCase):
    def setUp(self):
        self.lock = vendor_deps.load_lock()
        self.tree = vendor_deps.vendored_tree()
        self.llock = vendor_deps.load_license_lock()
        self.texts = vendor_deps.license_texts()

    def _problems(self, lock=None, tree=None, llock=None, texts=None):
        return vendor_deps.verify(lock or self.lock, tree or self.tree, {}, vendor_deps.expected_remappings(self.lock),
                                  llock or self.llock, texts or self.texts)

    def test_repository_license_texts_pinned_to_upstream(self):
        self.assertEqual(vendor_deps.verify_licenses(self.llock, self.texts), [])
        entries = {e["file"]: e for e in self.llock["files"]}
        self.assertEqual(entries["LayerZero-v2-LICENSE-LZBL-1.2"]["gitBlobSha"],
                         "52be5c9fe938d115b30069a14b99d088b9928e19")
        self.assertIn(b"is not an open source license", self.texts["LayerZero-v2-LICENSE-LZBL-1.2"])
        self.assertIn(b"You must conspicuously display this License", self.texts["LayerZero-v2-LICENSE-LZBL-1.2"])
        self.assertIn(b"zOS Global Limited", self.texts["OpenZeppelin-contracts-4.9.6-LICENSE"])

    def test_every_lzbl_package_copy_carries_full_lzbl_text(self):
        lzbl = self.texts["LayerZero-v2-LICENSE-LZBL-1.2"]
        for pkg in ("@layerzerolabs/lz-evm-protocol-v2", "@layerzerolabs/lz-evm-messagelib-v2"):
            self.assertEqual(self.tree[f"{pkg}/LayerZero-v2-LICENSE-LZBL-1.2"], lzbl)
        for key in vendor_deps.license_summary(self.tree)["LZBL-1.2"]:
            self.assertIn(key.split("/contracts/")[0] + "/LayerZero-v2-LICENSE-LZBL-1.2", self.tree)

    def test_tampered_or_unpinned_license_text_detected(self):
        texts = dict(self.texts)
        texts["LayerZero-v2-LICENSE-LZBL-1.2"] = texts["LayerZero-v2-LICENSE-LZBL-1.2"].replace(b"not an", b"an")
        problems = self._problems(texts=texts)
        self.assertTrue(any("sha256 mismatch" in p for p in problems))
        self.assertTrue(any("git blob sha" in p for p in problems))
        texts = dict(self.texts)
        texts["Extra-LICENSE"] = b"x"
        self.assertTrue(any("not pinned" in p for p in self._problems(texts=texts)))
        texts = dict(self.texts)
        texts.pop("LayerZero-v2-LICENSE-MIT")
        self.assertTrue(any("missing" in p for p in self._problems(texts=texts)))

    def test_unpinned_provenance_url_detected(self):
        llock = copy.deepcopy(self.llock)
        llock["files"][0]["url"] = llock["files"][0]["url"].replace(llock["files"][0]["commit"], "main")
        self.assertTrue(any("pinned to the recorded commit" in p for p in self._problems(llock=llock)))

    def test_package_copy_and_spdx_coverage_enforced(self):
        tree = dict(self.tree)
        tree.pop("@layerzerolabs/lz-evm-protocol-v2/LayerZero-v2-LICENSE-LZBL-1.2")
        self.assertTrue(any("missing or differs" in p for p in self._problems(tree=tree)))
        lock = copy.deepcopy(self.lock)
        for pkg in lock["packages"]:
            if pkg["name"] == "@layerzerolabs/lz-evm-messagelib-v2":
                pkg["licenseTexts"] = ["LayerZero-v2-LICENSE-MIT"]
        problems = self._problems(lock=lock)
        self.assertTrue(any("SPDX LZBL-1.2 has no full license text" in p for p in problems))


if __name__ == "__main__":
    unittest.main()
