import hashlib
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import importlib.util
import subprocess

SPEC = importlib.util.spec_from_file_location("updater", Path(__file__).parents[1] / "scripts/update_apifox.py")
updater = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(updater)


def archive_bytes(manifest, filename="package/package.json"):
    data = json.dumps(manifest).encode()
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w:gz") as archive:
        member = tarfile.TarInfo(filename)
        member.size = len(data)
        archive.addfile(member, io.BytesIO(data))
    return output.getvalue()


class UpdateTests(unittest.TestCase):
    def setUp(self):
        self.formula = (Path(__file__).parents[1] / "Formula/apifox-cli.rb").read_text()
        self.current = updater.formula_version(self.formula)
        major, minor, patch_number = updater.version_tuple(self.current)
        self.next = f"{major}.{minor}.{patch_number + 1}"
        self.manifest = {"name": "apifox-cli", "version": self.next, "dependencies": {"example": "1.0.0"}}
        self.archive = archive_bytes(self.manifest)
        import base64
        self.metadata = {"version": self.next, "dist": {
            "tarball": f"{updater.REGISTRY}/apifox-cli/-/apifox-cli-{self.next}.tgz",
            "integrity": "sha512-" + base64.b64encode(hashlib.sha512(self.archive).digest()).decode()}}
        self.lock = {"name": "apifox-cli", "version": self.next, "lockfileVersion": 3,
                     "packages": {"": self.manifest, "node_modules/example": {"version": "1.0.0"}}}

    def test_version_order_and_prerelease_rejection(self):
        self.assertGreater(updater.version_tuple("2.2.12"), updater.version_tuple("2.2.9"))
        with self.assertRaises(ValueError):
            updater.version_tuple("2.3.0-beta.1")

    def test_no_update_has_no_remote_writes(self):
        metadata = json.dumps({"version": self.current}).encode()
        with patch.object(updater, "download", return_value=metadata), \
             patch.object(updater, "command") as command, \
             patch("sys.argv", ["update_apifox.py"]):
            updater.main()
        command.assert_not_called()

    def test_prepare_updates_formula_checksum_lock_and_revision(self):
        def npm(*args, **kwargs):
            self.assertIn("--ignore-scripts", args)
            self.assertIn("--omit=optional", args)
            (kwargs["cwd"] / "npm-shrinkwrap.json").write_text(json.dumps(self.lock))
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(updater, "download", return_value=self.archive), \
             patch.object(updater, "lock_resource", return_value=b"{}"), \
             patch.object(updater, "command", side_effect=npm):
            result, lock_path = updater.prepare(self.formula + "\n  revision 2\n", self.metadata, Path(directory))
            self.assertEqual(updater.formula_version(result), self.next)
            self.assertIn(hashlib.sha256(self.archive).hexdigest(), result)
            self.assertIn(hashlib.sha256(lock_path.read_bytes()).hexdigest(), result)
            self.assertNotIn("revision 2", result)
            self.assertIn("--omit=optional", result)

    def test_reuses_published_lock_without_resolving_again(self):
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(updater, "download", return_value=self.archive), \
             patch.object(updater, "command") as command:
            updater.prepare(self.formula, self.metadata, Path(directory), json.dumps(self.lock).encode())
        command.assert_not_called()

    def test_rejects_corrupt_tarball(self):
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(updater, "download", return_value=b"corrupt"):
            with self.assertRaisesRegex(ValueError, "integrity mismatch"):
                updater.prepare(self.formula, self.metadata, Path(directory))

    def test_rejects_escaping_tar_paths(self):
        import base64
        archive = archive_bytes(self.manifest, "package/../../escape.json")
        self.metadata["dist"]["integrity"] = "sha512-" + base64.b64encode(hashlib.sha512(archive).digest()).decode()
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(updater, "download", return_value=archive):
            with self.assertRaises(tarfile.OutsideDestinationError):
                updater.prepare(self.formula, self.metadata, Path(directory))

    def test_ci_is_explicitly_dispatched_once_for_the_pr_commit(self):
        result = subprocess.CompletedProcess([], 0, stdout="[]")
        with patch.object(updater, "command", return_value=result) as command:
            updater.dispatch_ci("auto/apifox-cli-2.2.13", "abc123")
        self.assertEqual(command.call_count, 2)
        self.assertEqual(command.call_args.args[:3], ("gh", "workflow", "run"))
        self.assertIn("--ref", command.call_args.args)
        result.stdout = '[{"headSha":"abc123"}]'
        with patch.object(updater, "command", return_value=result) as command:
            updater.dispatch_ci("auto/apifox-cli-2.2.13", "abc123")
        self.assertEqual(command.call_count, 1)

    def test_new_release_opens_pr_then_dispatches_ci_without_force_push(self):
        calls = []
        def fake_command(*args, **kwargs):
            calls.append(args)
            output = ""
            if args[:3] in (("gh", "pr", "list"), ("gh", "run", "list")):
                output = "[]"
            if args[:3] == ("git", "rev-parse", "HEAD"):
                output = "abc123"
            return subprocess.CompletedProcess(args, 0, stdout=output)
        with tempfile.TemporaryDirectory() as directory:
            formula = Path(directory) / "formula.rb"
            formula.write_text(self.formula)
            lock = Path(directory) / "npm-shrinkwrap.json"
            lock.write_text(json.dumps(self.lock))
            with patch.object(updater, "FORMULA", formula), \
                 patch.object(updater, "download", return_value=json.dumps(self.metadata).encode()), \
                 patch.object(updater, "release_info", return_value=None), \
                 patch.object(updater, "prepare", return_value=(self.formula, lock)), \
                 patch.object(updater, "command", side_effect=fake_command), \
                 patch("sys.argv", ["update_apifox.py"]):
                updater.main()
        create = next(i for i, args in enumerate(calls) if args[:3] == ("gh", "pr", "create"))
        dispatch = next(i for i, args in enumerate(calls) if args[:3] == ("gh", "workflow", "run"))
        self.assertLess(create, dispatch)
        push = next(args for args in calls if args[:2] == ("git", "push"))
        self.assertFalse(any(arg.startswith("--force") for arg in push))

    def test_existing_pr_is_reused_and_closed_pr_is_respected(self):
        for state in ("OPEN", "CLOSED"):
            pr = {"number": 42, "state": state, "headRefOid": "abc123"}
            result = subprocess.CompletedProcess([], 0, stdout=json.dumps([pr]))
            with self.subTest(state=state), \
                 patch.object(updater, "download", return_value=json.dumps(self.metadata).encode()), \
                 patch.object(updater, "command", return_value=result) as command, \
                 patch.object(updater, "dispatch_ci") as dispatch, \
                 patch("sys.argv", ["update_apifox.py"]):
                updater.main()
                self.assertEqual(command.call_count, 1)
                self.assertEqual(dispatch.call_count, 1 if state == "OPEN" else 0)


if __name__ == "__main__":
    unittest.main()
