"""Local checks for persistent install boundaries, without running host hooks."""

import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


def load(filename):
    spec = importlib.util.spec_from_file_location(filename, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


harness = load("install_harness.py")
audit = load("release-audit.py")


class InstallSafety(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def test_linked_managed_parent_is_rejected(self):
        outside = self.root / "other"
        outside.mkdir()
        chosen = self.root / "chosen"
        chosen.mkdir()
        hooks = chosen / "hooks"
        try:
            hooks.symlink_to(outside, target_is_directory=True)
        except OSError as error:
            self.skipTest(f"directory symlinks are unavailable: {error}")
        with self.assertRaisesRegex(ValueError, "linked install path"):
            harness.check_path(hooks / "settings.json", chosen)
        self.assertEqual(list(outside.iterdir()), [])

    def test_hard_linked_settings_are_rejected(self):
        original = self.root / "original.json"
        original.write_text("{}", encoding="utf-8")
        target = self.root / "settings.json"
        try:
            os.link(original, target)
        except OSError as error:
            self.skipTest(f"hard links are unavailable: {error}")
        with self.assertRaisesRegex(ValueError, "hard-linked install file"):
            harness.check_path(target, self.root)
        self.assertEqual(original.read_text(encoding="utf-8"), "{}")

    def test_directory_at_managed_file_path_is_rejected(self):
        settings = self.root / "settings.json"
        settings.mkdir()
        with self.assertRaisesRegex(ValueError, "expected a regular install file"):
            harness.check_claude_paths(self.root)
        self.assertEqual(list(settings.iterdir()), [])

    def test_file_at_managed_directory_path_is_rejected(self):
        hooks = self.root / "hooks"
        hooks.write_text("fixture", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "expected an install directory"):
            harness.check_claude_paths(self.root)
        self.assertEqual(hooks.read_text(encoding="utf-8"), "fixture")

    def test_gemini_preserves_global_hook_opt_out(self):
        with patch.dict(os.environ, {"HOME": str(self.root)}):
            layout = harness.layout("gemini")
            config = Path(layout["config"])
            config.parent.mkdir()
            original = {"tools": {"enableHooks": False}, "hooks": {"BeforeTool": [
                {"matcher": "other", "hooks": [{"type": "command", "command": "true"}]}
            ]}}
            config.write_text(json.dumps(original), encoding="utf-8")
            guard = str(Path(layout["hooks"]) / harness.GUARD_NAME)
            self.assertTrue(harness.register("gemini", layout, guard, dry=False))
            edited = json.loads(config.read_text(encoding="utf-8"))
            self.assertIs(edited["tools"]["enableHooks"], False)
            self.assertIn(original["hooks"]["BeforeTool"][0], edited["hooks"]["BeforeTool"])
            self.assertEqual(len(edited["hooks"]["BeforeTool"]), 2)

    def test_release_audit_ignores_registry_and_uses_bundled_guard(self):
        unrelated = self.root / "unrelated.sh"
        unrelated.write_text("# fixture\n", encoding="utf-8")
        (self.root / ".guards").write_text(f"codex\t{unrelated}\n", encoding="utf-8")
        with patch.object(audit, "ROOT", str(self.root)), patch.dict(os.environ, {"APP_STORE_GUARD_PATH": ""}):
            self.assertIsNone(audit.resolve_guard()[0])
            bundled = self.root / "agent-os" / "hooks" / audit.GUARD_NAME
            bundled.parent.mkdir(parents=True)
            bundled.write_text("# fixture\n", encoding="utf-8")
            self.assertEqual(audit.resolve_guard(), (str(bundled), None))


if __name__ == "__main__":
    unittest.main(verbosity=2)
