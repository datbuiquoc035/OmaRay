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


    def test_menu_normalizer_keeps_well_formed_rows(self):
        rows = HELPER.normalize_menu({
            "install": {"label": "Install", "icon": "x"},
            "install.vim": {"label": "Vim", "action": "omarchy-install-app Vim vim",
                            "when": "omarchy-pkg-missing vim"},
            "bad id!": {"label": "Bad"},
            "ok_id-1.2": "not a dict",
        })
        by_id = {r["id"]: r for r in rows}
        self.assertEqual(by_id["install"]["parent"], "root")
        self.assertEqual(by_id["install"]["kind"], "menu")
        self.assertEqual(by_id["install.vim"]["parent"], "install")
        self.assertEqual(by_id["install.vim"]["kind"], "action")
        self.assertNotIn("bad id!", by_id)
        self.assertNotIn("ok_id-1.2", by_id)
        self.assertEqual(HELPER.normalize_menu([]), [])

    def test_menu_guards_answer_true_false_and_drop_garbage(self):
        proc = subprocess.run(
            [str(HELPER_PATH), "menu-guards"],
            input=b'{"a.b": "true", "c.d": "false", "evil!id": "true", "e.f": ""}',
            capture_output=True, timeout=60)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        guards = json.loads(proc.stdout.decode())["guards"]
        self.assertTrue(guards["a.b"])
        self.assertFalse(guards["c.d"])
        self.assertNotIn("evil!id", guards)
        self.assertNotIn("e.f", guards)

    def test_menu_guards_reject_non_json(self):
        proc = subprocess.run(
            [str(HELPER_PATH), "menu-guards"],
            input=b"nope", capture_output=True, timeout=30)
        self.assertFalse(json.loads(proc.stdout.decode())["ok"])

    def test_user_menu_extensions_read_from_scratch_home(self):
        with tempfile.TemporaryDirectory() as home:
            ext = Path(home) / ".config" / "omarchy" / "extensions"
            ext.mkdir(parents=True)
            (ext / "omarchy-menu.jsonc").write_text(
                '// comment\n{"my.tool": {"label": "Mine", "action": "run-it",},}')
            real_home = os.environ.get("HOME")
            os.environ["HOME"] = home
            try:
                rows = HELPER._read_menu_jsonc(False)
            finally:
                if real_home is None:
                    del os.environ["HOME"]
                else:
                    os.environ["HOME"] = real_home
            self.assertEqual(len(rows), 1)
            self.assertEqual(rows[0]["id"], "my.tool")
            self.assertEqual(rows[0]["parent"], "my")


    def test_clipboard_reads_omarchy_history_not_omaray_state(self):
        with tempfile.TemporaryDirectory() as home:
            owned = Path(home) / ".local" / "state" / "omarchy"
            owned.mkdir(parents=True)
            (owned / "clipboard-history.json").write_text(
                json.dumps([{"type": "text", "text": "hello clipboard"}]))
            # A decoy in the plugin's own state dir must never be consulted.
            decoy = Path(home) / ".local" / "state" / "omaray"
            decoy.mkdir(parents=True)
            (decoy / "clipboard-history.json").write_text(
                json.dumps([{"type": "text", "text": "wrong file"}]))
            env = dict(os.environ, HOME=home)
            proc = subprocess.run(
                [str(HELPER_PATH), "read-clipboard"],
                capture_output=True, env=env, timeout=30)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            reply = json.loads(proc.stdout.decode())
            self.assertTrue(reply["ok"])
            self.assertEqual(len(reply["items"]), 1)
            self.assertEqual(reply["items"][0]["title"], "hello clipboard")

    def test_clipboard_read_is_empty_without_history(self):
        with tempfile.TemporaryDirectory() as home:
            Path(home, ".local", "state").mkdir(parents=True)
            env = dict(os.environ, HOME=home)
            proc = subprocess.run(
                [str(HELPER_PATH), "read-clipboard"],
                capture_output=True, env=env, timeout=30)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            reply = json.loads(proc.stdout.decode())
            self.assertTrue(reply["ok"])
            self.assertEqual(reply["items"], [])

    def _wl_copy_stub(self, directory):
        """A wl-copy that records what it was handed and what was visible in argv.

        Returning a path with `wl-copy` in it makes the helper spawn this
        instead of the real one. The stub runs while the helper is still alive
        and blocked on it, which is the one moment where /proc/<pid>/cmdline
        for the helper is on screen to any other local user.
        """
        bin_dir = Path(directory) / "bin"
        bin_dir.mkdir(parents=True, exist_ok=True)
        stub = bin_dir / "wl-copy"
        stub.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, sys\n"
            "def cmdline(pid):\n"
            "    raw = open('/proc/%s/cmdline' % pid, 'rb').read()\n"
            "    return [a.decode('utf-8', 'replace') for a in raw.split(b'\\x00')[:-1]]\n"
            "stdin = sys.stdin.buffer.read()\n"
            "record = {\n"
            "    'argv': sys.argv[1:],\n"
            "    'self_cmdline': cmdline('self'),\n"
            "    'parent_cmdline': cmdline(os.getppid()),\n"
            "    'stdin': stdin.decode('utf-8', 'replace'),\n"
            "    'saw_in_any_cmdline': False,\n"
            "}\n"
            "for entry in os.listdir('/proc'):\n"
            "    if not entry.isdigit():\n"
            "        continue\n"
            "    try:\n"
            "        raw = open('/proc/%s/cmdline' % entry, 'rb').read()\n"
            "    except OSError:\n"
            "        continue\n"
            "    if stdin and stdin in raw:\n"
            "        record['saw_in_any_cmdline'] = True\n"
            "open(os.environ['WL_COPY_RECORD'], 'w').write(json.dumps(record))\n")
        stub.chmod(0o755)
        return bin_dir

    def _run_copy(self, home, argv, stdin, record):
        """Run a helper command with a stubbed wl-copy; return its reply.

        Returns (reply, record). `stdin` is what the caller sends on the pipe,
        which for both commands is the text that must never reach argv.
        """
        with tempfile.TemporaryDirectory() as sandbox:
            bin_dir = self._wl_copy_stub(sandbox)
            env = dict(os.environ, HOME=home, PATH="%s:%s" % (bin_dir, os.environ["PATH"]),
                       WL_COPY_RECORD=record)
            proc = subprocess.run(
                [str(HELPER_PATH)] + argv, input=stdin.encode("utf-8"),
                capture_output=True, env=env, timeout=30)
            reply = json.loads(proc.stdout.decode())
        path = Path(record)
        return reply, (json.loads(path.read_text()) if path.stat().st_size else None)

    def test_clipboard_copy_takes_the_title_on_stdin_not_argv(self):
        # The reported leak: `title` is the first CLIP_TITLE_CHARS of the real
        # clipboard text, so for an entry this short it is the secret verbatim.
        # argv is world-readable through /proc/<pid>/cmdline wherever /proc is
        # mounted without hidepid, which is the default almost everywhere.
        secret = "pw-4f2a-9c"
        with tempfile.TemporaryDirectory() as home:
            state = Path(home) / ".local" / "state" / "omarchy"
            state.mkdir(parents=True)
            (state / "clipboard-history.json").write_text(
                json.dumps([{"type": "text", "text": secret}]))
            with tempfile.NamedTemporaryFile(suffix=".json") as record:
                reply, seen = self._run_copy(
                    home, ["clipboard-copy", "0"], secret, record.name)
                self.assertTrue(reply["ok"], reply)

            # The secret reached wl-copy, so the copy did happen...
            self.assertEqual(seen["stdin"], secret)
            # ...entirely over the pipe, and nowhere in any process arguments.
            self.assertFalse(seen["saw_in_any_cmdline"],
                             "clipboard text leaked into a /proc cmdline")
            self.assertNotIn(secret, " ".join(seen["parent_cmdline"]))
            # argv[0] is however the shebang resolved the interpreter, so the
            # assertion is on the operands: the index, and nothing else.
            self.assertTrue(seen["parent_cmdline"][0].endswith("python3"))
            self.assertEqual(seen["parent_cmdline"][1:],
                             [str(HELPER_PATH), "clipboard-copy", "0"])
            # wl-copy itself is handed the text on stdin, never as an operand. Its own
            # argv is the interpreter plus the script and nothing else.
            self.assertEqual(seen["argv"], [])
            self.assertEqual(len(seen["self_cmdline"]), 2)
            self.assertTrue(seen["self_cmdline"][1].endswith("/wl-copy"))

    def test_clipboard_copy_still_rejects_a_title_that_no_longer_matches(self):
        # Re-identification is the whole reason the title exists at all: the
        # history can shift between the row being drawn and Enter.
        with tempfile.TemporaryDirectory() as home:
            state = Path(home) / ".local" / "state" / "omarchy"
            state.mkdir(parents=True)
            (state / "clipboard-history.json").write_text(
                json.dumps([{"type": "text", "text": "current entry"}]))
            with tempfile.NamedTemporaryFile(suffix=".json") as record:
                reply, _ = self._run_copy(home, ["clipboard-copy", "0"],
                                          "stale entry", record.name)
            self.assertFalse(reply["ok"])
            self.assertEqual(reply["error"], "clipboard entry changed")

    def test_clipboard_copy_rejects_an_oversized_title(self):
        with tempfile.TemporaryDirectory() as home:
            state = Path(home) / ".local" / "state" / "omarchy"
            state.mkdir(parents=True)
            (state / "clipboard-history.json").write_text(
                json.dumps([{"type": "text", "text": "x" * 4000}]))
            with tempfile.NamedTemporaryFile(suffix=".json") as record:
                reply, _ = self._run_copy(home, ["clipboard-copy", "0"],
                                          "x" * 4000, record.name)
            self.assertFalse(reply["ok"])
            self.assertIn("stdin exceeded", reply["error"])

    def test_copy_text_takes_the_text_on_stdin_not_argv(self):
        # Calculator, unit, date, colour and emoji rows all land here. The
        # values are derived rather than raw copied secrets, but they are still
        # user data crossing a channel any local user can read off /proc.
        # An emoji is one of the real payloads and cannot collide with an
        # unrelated process during the /proc sweep.
        text = "\U0001d11e"
        with tempfile.TemporaryDirectory() as home:
            with tempfile.NamedTemporaryFile(suffix=".json") as record:
                reply, seen = self._run_copy(home, ["copy-text"], text, record.name)
                self.assertTrue(reply["ok"], reply)
                self.assertEqual(reply["copied"], len(text.encode("utf-8")))
            self.assertEqual(seen["stdin"], text)
            self.assertFalse(seen["saw_in_any_cmdline"],
                             "copy text leaked into a /proc cmdline")
            self.assertTrue(seen["parent_cmdline"][0].endswith("python3"))
            self.assertEqual(seen["parent_cmdline"][1:],
                             [str(HELPER_PATH), "copy-text"])

    def test_copy_text_refuses_empty_and_nul(self):
        with tempfile.TemporaryDirectory() as home:
            with tempfile.NamedTemporaryFile(suffix=".json") as record:
                reply, _ = self._run_copy(home, ["copy-text"], "", record.name)
                self.assertFalse(reply["ok"])
                reply, _ = self._run_copy(home, ["copy-text"], "a\x00b", record.name)
                self.assertFalse(reply["ok"])
                self.assertEqual(reply["error"], "text contains NUL")

    def test_clip_title_flattens_caps_and_truncates(self):
        self.assertEqual(HELPER._clip_title("  a\tb\n c  "), "a b c")
        self.assertEqual(HELPER._clip_title("   "), "")
        long = "x" * (HELPER.CLIP_TITLE_CHARS + 50)
        self.assertEqual(HELPER._clip_title(long), "x" * HELPER.CLIP_TITLE_CHARS + "…")
        # A capped title always fits the stdin allowance, at worst 4 bytes/char.
        self.assertLessEqual(len(HELPER._clip_title(long).encode("utf-8")),
                             HELPER.CLIP_TITLE_BYTES)

    def test_file_preview_text_dir_image_and_missing(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            text_file = base / "notes.txt"
            text_file.write_text("hello preview\nsecond line\n")
            sub = base / "sub"
            sub.mkdir()
            (sub / "a").write_text("x")
            img = base / "pic.png"
            img.write_bytes(b"\x89PNG" + b"x" * 100)
            binary = base / "blob.bin"
            binary.write_bytes(b"\x00\x01\x02abc")

            def preview(path):
                proc = subprocess.run(
                    [str(HELPER_PATH), "file-preview", str(path)],
                    capture_output=True, timeout=30)
                self.assertEqual(proc.returncode, 0, proc.stderr)
                reply = json.loads(proc.stdout.decode())
                self.assertTrue(reply["ok"])
                return reply["preview"]

            text = preview(text_file)
            self.assertFalse(text["isDir"])
            self.assertEqual(text["kind"], "text")
            self.assertIn("hello preview", text["snippet"])
            self.assertFalse(text["truncated"])

            folder = preview(sub)
            self.assertTrue(folder["isDir"])
            self.assertEqual(folder["childCount"], 1)

            image = preview(img)
            self.assertTrue(image["isImage"])
            self.assertEqual(image["kind"], "image")
            self.assertEqual(image["snippet"], "")

            blob = preview(binary)
            self.assertEqual(blob["kind"], "binary")
            self.assertTrue(blob["binary"])

            missing = preview(base / "nope.txt")
            self.assertTrue(missing.get("unavailable"))

    def test_file_preview_rejects_relative_paths(self):
        proc = subprocess.run(
            [str(HELPER_PATH), "file-preview", "relative/path"],
            capture_output=True, timeout=30)
        self.assertFalse(json.loads(proc.stdout.decode())["ok"])


if __name__ == "__main__":
    unittest.main()
