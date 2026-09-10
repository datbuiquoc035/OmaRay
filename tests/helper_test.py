import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
HELPER_PATH = ROOT / "bin" / "omaray-helper"
SPEC = importlib.util.spec_from_file_location("omaray_helper", HELPER_PATH)
if SPEC is None:
    from importlib.machinery import SourceFileLoader

    SPEC = importlib.util.spec_from_loader(
        "omaray_helper", SourceFileLoader("omaray_helper", str(HELPER_PATH))
    )
HELPER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HELPER)


class HelperTests(unittest.TestCase):
    def test_settings_are_private_by_default_and_bounded(self):
        defaults = HELPER.normalize_settings({})
        self.assertFalse(defaults["webSuggestions"])

        settings = HELPER.normalize_settings({
            "webSuggestions": "yes",
            "maxApps": 999,
            "maxSuggestions": -5,
            "searchEngine": "invalid-value",
        })
        self.assertFalse(settings["webSuggestions"])
        self.assertEqual(settings["maxApps"], 24)
        self.assertEqual(settings["maxSuggestions"], 0)
        self.assertEqual(settings["searchEngine"], "g")

    def test_file_reader_rejects_symlinks_and_oversized_files(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            (base / "target").write_bytes(b"secret")
            (base / "link").symlink_to("target")
            (base / "large").write_bytes(b"x" * 9)
            fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
            try:
                with self.assertRaises(HELPER.Denied):
                    HELPER.read_file(fd, "link", 64)
                with self.assertRaises(HELPER.Denied):
                    HELPER.read_file(fd, "large", 8)
            finally:
                os.close(fd)

    def test_deadline_reaps_the_process_group(self):
        with tempfile.TemporaryDirectory() as directory:
            pid_file = Path(directory) / "child.pid"
            code = (
                "import os,subprocess,sys,time; "
                "child=subprocess.Popen(['sleep','60']); "
                "open(sys.argv[1],'w').write(str(child.pid)); "
                "print('ready',flush=True); time.sleep(60)"
            )
            output, truncated = HELPER.run_bounded(
                [sys.executable, "-c", code, str(pid_file)], 1024, 0.2
            )
            self.assertTrue(truncated)
            self.assertIn(b"ready", output)
            child_pid = int(pid_file.read_text())
            for _ in range(50):
                if not Path("/proc") .joinpath(str(child_pid)).exists():
                    break
                time.sleep(0.02)
            self.assertFalse(Path("/proc").joinpath(str(child_pid)).exists())


    def test_write_settings_round_trip_through_a_scratch_home(self):
        with tempfile.TemporaryDirectory() as home:
            config = Path(home) / ".config" / "omarchy"
            config.mkdir(parents=True)
            env = dict(os.environ, HOME=home)
            written = subprocess.run(
                [str(HELPER_PATH), "write-settings"],
                input=b'{"maxApps": 999, "webSuggestions": true, "searchEngine": "yt"}',
                capture_output=True, env=env, timeout=30)
            self.assertEqual(written.returncode, 0, written.stderr)
            reply = json.loads(written.stdout.decode())
            self.assertTrue(reply["ok"])
            self.assertEqual(reply["settings"]["maxApps"], 24)
            self.assertTrue(reply["settings"]["webSuggestions"])
            self.assertEqual(reply["settings"]["searchEngine"], "yt")

            stored = config / "omaray.json"
            self.assertTrue(stored.exists())
            self.assertEqual(stored.stat().st_mode & 0o777, 0o600)

            read = subprocess.run(
                [str(HELPER_PATH), "read-settings"],
                capture_output=True, env=env, timeout=30)
            reread = json.loads(read.stdout.decode())
            self.assertEqual(reread["settings"], reply["settings"])

    def test_write_settings_rejects_non_json(self):
        with tempfile.TemporaryDirectory() as home:
            (Path(home) / ".config" / "omarchy").mkdir(parents=True)
            env = dict(os.environ, HOME=home)
            bad = subprocess.run(
                [str(HELPER_PATH), "write-settings"],
                input=b"not json", capture_output=True, env=env, timeout=30)
            self.assertEqual(bad.returncode, 0)
            self.assertFalse(json.loads(bad.stdout.decode())["ok"])

    def test_emoji_normalizer_keeps_only_well_formed_entries(self):
        out = HELPER.normalize_emojis([
            {"e": "😀", "k": "grinning face"},
            {"e": "", "k": "empty glyph"},
            {"e": "😂"},
            "nope",
            {"e": "❤", "k": "  red   heart  "},
        ])
        self.assertEqual(out, [
            {"e": "😀", "k": "grinning face"},
            {"e": "❤", "k": "red heart"},
        ])
        self.assertEqual(HELPER.normalize_emojis({"e": "x"}), [])

    def test_usage_keys_cover_windows_emoji_and_hotkeys(self):
        now = int(time.time() * 1000)
        entry = {"count": 2, "last": now}
        usage = HELPER.normalize_usage({
            "win:term:bash": dict(entry),
            "emoji:3": dict(entry),
            "hotkey:close-window": dict(entry),
            "app:X": dict(entry),
            "evil:__proto__": dict(entry),
            "__proto__": dict(entry),
        })
        for key in ("win:term:bash", "emoji:3", "hotkey:close-window", "app:X"):
            self.assertIn(key, usage)
        self.assertNotIn("evil:__proto__", usage)
        self.assertNotIn("__proto__", usage)

    def test_script_resolver_refuses_missing_and_user_owned_files(self):
        with tempfile.TemporaryDirectory() as directory:
            owned = Path(directory) / "script"
            owned.write_text("#!/bin/sh\n")
            env_home = os.environ.get("OMARCHY_PATH")
            try:
                os.environ["OMARCHY_PATH"] = directory
                with self.assertRaises(HELPER.Denied):
                    HELPER.omarchy_script("script")
                with self.assertRaises(HELPER.Denied):
                    HELPER.omarchy_script("no-such-file")
            finally:
                if env_home is None:
                    del os.environ["OMARCHY_PATH"]
                else:
                    os.environ["OMARCHY_PATH"] = env_home


    def test_dmenu_finish_writes_selection_and_signals_done(self):
        with tempfile.TemporaryDirectory() as directory:
            sel = str(Path(directory) / "selection")
            done = str(Path(directory) / "done")
            Path(sel).write_text("")
            picked = subprocess.run(
                [str(HELPER_PATH), "dmenu-finish", sel, done],
                input="Docs\t/home/pics".encode(),
                capture_output=True, timeout=30)
            self.assertEqual(picked.returncode, 0, picked.stderr)
            self.assertTrue(json.loads(picked.stdout.decode())["wrote"])
            self.assertEqual(Path(sel).read_text(), "Docs\t/home/pics\n")
            self.assertTrue(Path(done).exists())
            self.assertEqual(Path(done).read_bytes(), b"")

    def test_dmenu_finish_cancel_leaves_selection_empty(self):
        with tempfile.TemporaryDirectory() as directory:
            sel = str(Path(directory) / "selection")
            done = str(Path(directory) / "done")
            Path(sel).write_text("")
            cancelled = subprocess.run(
                [str(HELPER_PATH), "dmenu-finish", sel, done],
                input=b"", capture_output=True, timeout=30)
            self.assertEqual(cancelled.returncode, 0)
            self.assertFalse(json.loads(cancelled.stdout.decode())["wrote"])
            self.assertEqual(Path(sel).read_text(), "")
            self.assertTrue(Path(done).exists())

    def test_dmenu_finish_refuses_symlinks_and_relative_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            (base / "target").write_text("x")
            (base / "link").symlink_to("target")
            done = str(base / "done")
            refused = subprocess.run(
                [str(HELPER_PATH), "dmenu-finish", str(base / "link"), done],
                input=b"y", capture_output=True, timeout=30)
            self.assertFalse(json.loads(refused.stdout.decode())["ok"])
            self.assertFalse(Path(done).exists())
            relative = subprocess.run(
                [str(HELPER_PATH), "dmenu-finish", "relative", done],
                input=b"y", capture_output=True, timeout=30,
                cwd=directory)
            self.assertFalse(json.loads(relative.stdout.decode())["ok"])


if __name__ == "__main__":
    unittest.main()
