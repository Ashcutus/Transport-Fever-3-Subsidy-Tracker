"""Offline checks for release matching and version-only remote changes."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("modio_version", Path(__file__).resolve().parents[1] / "scripts/set_modio_version.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


class VersionTests(unittest.TestCase):
    def setUp(self):
        self.files = [dict(id=i, filename=f"file{i}.zip", version="1.0", changelog=heading)
                      for i, heading in enumerate(["v1.2.0 — New feature", "1.2.0: Console", "v1.2.01 Wrong", "v1.1.2 Mention v1.2.0"], 1)]

    def test_exact_release_and_both_platform_files(self):
        self.assertEqual([f["id"] for f in mod.select_files(self.files, "1.2.0")], [1, 2])

    def test_explicit_ids_must_all_belong_to_mod(self):
        with self.assertRaises(ValueError):
            mod.select_files(self.files, "1.2.0", [1, 99])
        self.assertEqual(mod.select_files(self.files, "1.1.2", [4]), [self.files[3]])

    def test_no_match_refuses(self):
        with self.assertRaises(ValueError):
            mod.select_files(self.files, "9.0.0")

    def test_preview_never_writes_and_apply_only_sets_version(self):
        calls = []
        state = dict(self.files[0])

        class Client:
            def request(self, suffix, fields=None):
                calls.append((suffix, fields))
                if fields:
                    state.update(fields)
                return dict(state)

        with patch("builtins.print"):
            mod.update(Client(), [dict(state)], "1.2.0")
            self.assertEqual(calls, [])
            mod.update(Client(), [dict(state)], "1.2.0", True)
            self.assertEqual(calls, [("/1", None), ("/1", {"version": "1.2.0"}), ("/1", None)])
            calls.clear()
            mod.update(Client(), [dict(state)], "1.2.0", True)
            self.assertEqual(calls, [])

    def test_changed_file_refuses_write(self):
        class Client:
            def request(self, suffix, fields=None):
                self.assert_read(fields)
                return dict(id=1, version="1.0", changelog="changed")

            def assert_read(self, fields):
                if fields is not None:
                    raise AssertionError("Unexpected write")

        with patch("builtins.print"), self.assertRaises(RuntimeError):
            mod.update(Client(), [self.files[0]], "1.2.0", True)

    def test_pagination(self):
        client = mod.Client("unused-test-token")
        with patch.object(client, "request", side_effect=[
            {"data": self.files[:2], "result_total": 4},
            {"data": self.files[2:], "result_total": 4},
        ]) as request:
            self.assertEqual(client.files(), self.files)
            self.assertIn("_offset=2", request.call_args.args[0])


if __name__ == "__main__":
    unittest.main()
