#!/usr/bin/env python3
"""Runtime contracts, including real ZLE interaction. Python is test-only."""
import json
import os
from pathlib import Path
import pty
import re
import select
import shlex
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class Shell:
    def __init__(self, home, extra=None):
        self.env = {**os.environ, "HOME": str(home), "ZDOTDIR": str(home),
                    "XDG_STATE_HOME": str(home / "state"), "XDG_CACHE_HOME": str(home / "cache"),
                    "XDG_DATA_HOME": str(home / "data"), "TERM": "xterm-256color",
                    "ZSHARD_HOME": str(ROOT), "ZSHARD_PROMPT": "off"}
        self.env.update(extra or {})

    def run(self, script, interactive=False):
        return subprocess.run(["zsh", "-f"] + (["-i"] if interactive else []) +
                              ["-c", 'source "$ZSHARD_HOME/zshard.zsh"; ' + script],
                              env=self.env, cwd=ROOT, text=True, capture_output=True, timeout=12)


class Terminal(Shell):
    def __init__(self, home, extra=None):
        super().__init__(home, extra)
        self.master, slave = pty.openpty()
        self.process = subprocess.Popen(["zsh", "-f", "-i"], env=self.env, cwd=home,
                                        stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
        os.close(slave)
        self.read_for(0.1)
        self.send('source "$ZSHARD_HOME/zshard.zsh"; PROMPT="ZS> "; print -r -- __READY__\n')
        self.until(b"\r\n__READY__\r\n")
        self.read_for(0.05)

    def send(self, value):
        os.write(self.master, value.encode() if isinstance(value, str) else value)

    def read_for(self, duration):
        result = b""
        end = time.monotonic() + duration
        while time.monotonic() < end:
            ready, _, _ = select.select([self.master], [], [], max(0, end - time.monotonic()))
            if ready:
                try:
                    data = os.read(self.master, 65536)
                except OSError:
                    break
                if not data:
                    break
                result += data
        return result

    def until(self, needle, timeout=10):
        result = b""
        end = time.monotonic() + timeout
        while needle not in result and time.monotonic() < end:
            result += self.read_for(0.02)
        if needle not in result:
            raise AssertionError(f"Expected {needle!r}; terminal output: {result!r}")
        return result

    def command(self, value):
        self.send(value + '; print -r -- "__DONE__$?"\n')
        return self.until(b"\r\n__DONE__0\r\n")

    def close(self):
        self.send(b"\x03exit\n")
        try:
            self.process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=2)
        os.close(self.master)


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="zshard-test-")
        self.home = Path(self.tmp.name)
        self.shell = Shell(self.home)

    def tearDown(self):
        self.tmp.cleanup()

    def test_syntax(self):
        for path in [ROOT / "zshard.zsh", *ROOT.glob("lib/*.zsh"), ROOT / "bin/zshard"]:
            result = subprocess.run(["zsh", "-n", str(path)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_json_and_no_secret_context(self):
        self.shell.env["VERY_SECRET_VALUE"] = "must-not-be-exported"
        result = self.shell.run("zai context")
        self.assertEqual(result.returncode, 0, result.stderr)
        context = json.loads(result.stdout)
        self.assertEqual(context["schema"], "zshard.context.v1")
        self.assertFalse(context["history_included"])
        self.assertFalse(context["environment_included"])
        self.assertNotIn("must-not-be-exported", result.stdout)

    def test_json_escaping(self):
        result = self.shell.run("""zai context >/dev/null; _zshard_json_string $'a"b\\\\c\\n\\t\\x01中文'""")
        self.assertEqual(json.loads(result.stdout), 'a"b\\c\n\t\x01中文')

    def test_repeat_source_and_hook_coexistence(self):
        result = self.shell.run('before() { :; }; precmd_functions+=(before); '
                                'source "$ZSHARD_HOME/zshard.zsh"; '
                                'print -rl -- $precmd_functions', interactive=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines().count("_zshard_precmd"), 1)
        self.assertIn("before", result.stdout.splitlines())

    def test_load_once_defer_and_lazy_arguments(self):
        plugin = self.home / "plugin with spaces.zsh"
        plugin.write_text('(( COUNTER += 1 )); loaded_command() { print -rl -- "$@"; }\n')
        result = self.shell.run(f"COUNTER=0; zshard lazy loaded_command {shlex.quote(str(plugin))}; "
                                'print $COUNTER; loaded_command "two words" \'$(printf hostile)\'; '
                                f'zshard load {shlex.quote(str(plugin))}; print $COUNTER')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["0", "two words", "$(printf hostile)", "1"])
        result = self.shell.run(f"COUNTER=0; zshard defer {shlex.quote(str(plugin))}; "
                                "print $COUNTER; _zshard_run_deferred; print $COUNTER; "
                                "_zshard_run_deferred; print $COUNTER")
        self.assertEqual(result.stdout.splitlines(), ["0", "1", "1"])

    def test_extension_hooks_theme_and_completion_registration(self):
        custom = self.home / "completions"
        custom.mkdir()
        (custom / "_fixture").write_text("#compdef fixture\n_arguments '*:path:_files'\n")
        script = (
            "one() { :; }; two() { :; }; zshard hook precmd one; zshard hook precmd two; "
            "zshard unhook precmd one; print -rl -- $precmd_functions; "
            "my_theme() { PROMPT=\"status=$1 seconds=$2\"; }; zshard theme my_theme; "
            "false; _zshard_precmd; print -r -- $PROMPT; "
            "zshard completions " + shlex.quote(str(custom)) + "; zshard complete; print -r -- $_comps[fixture]"
        )
        result = self.shell.run(script, interactive=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("one", result.stdout.splitlines())
        self.assertIn("two", result.stdout.splitlines())
        self.assertIn("status=1 seconds=0", result.stdout.splitlines())
        self.assertIn("_fixture", result.stdout.splitlines())

    def test_noninteractive_cli_context(self):
        result = subprocess.run(["zsh", str(ROOT / "bin/zshard"), "ai", "context"],
                                env=self.shell.env, cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["schema"], "zshard.context.v1")

    def test_bad_plugin_identifiers_and_pins(self):
        for command in ["plugin add ../bad https://example.invalid/x " + "a" * 40 + " main.zsh",
                        "plugin add good https://example.invalid/x main main.zsh",
                        "plugin add good file:///tmp/repo " + "a" * 40 + " main.zsh",
                        "plugin add good https://example.invalid/x " + "a" * 40 + " ../outside",
                        "lazy 'bad;name' /dev/null"]:
            result = self.shell.run("zshard " + command)
            self.assertNotEqual(result.returncode, 0, command)

    def test_real_git_pin_and_dirty_detection(self):
        plugin_dir = self.home / "plugins"
        plugin = plugin_dir / "fixture"
        plugin.mkdir(parents=True)
        for args in [["init", "-q"], ["config", "user.name", "Fixture"],
                     ["config", "user.email", "fixture@example.invalid"]]:
            subprocess.run(["git", "-C", str(plugin), *args], check=True)
        (plugin / "init.zsh").write_text("typeset -g FIXTURE_LOADED=yes\nzshard_plugin_fixture_unload() { unset FIXTURE_LOADED; unfunction zshard_plugin_fixture_unload; }\n")
        subprocess.run(["git", "-C", str(plugin), "add", "."], check=True)
        subprocess.run(["git", "-C", str(plugin), "commit", "-qm", "fixture"], check=True)
        sha = subprocess.check_output(["git", "-C", str(plugin), "rev-parse", "HEAD"], text=True).strip()
        (plugin_dir / "fixture.lock").write_text(sha + "\thttps://example.invalid/fixture\tinit.zsh\n")
        self.shell.env["ZSHARD_PLUGIN_DIR"] = str(plugin_dir)
        result = self.shell.run("zshard use fixture; print $FIXTURE_LOADED; zshard plugin verify fixture")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("yes\nfixture: pinned", result.stdout)
        lock = self.home / "plugins.lock"
        result = self.shell.run("zshard use fixture; zshard unload fixture; print ${+FIXTURE_LOADED}; zshard use fixture; print $FIXTURE_LOADED; zshard plugin export > " + shlex.quote(str(lock)) + "; zshard plugin restore " + shlex.quote(str(lock)))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.startswith("0\nyes\n"), result.stdout)
        self.assertEqual(lock.read_text().splitlines()[0], "# zshard.plugins.v1")
        (plugin / "init.zsh").write_text("changed\n")
        self.assertNotEqual(self.shell.run("zshard plugin verify fixture").returncode, 0)
        (plugin / "init.zsh").unlink()
        (plugin / "init.zsh").symlink_to("/etc/passwd")
        self.assertNotEqual(self.shell.run("zshard use fixture").returncode, 0)

    def test_ai_provider_is_explicit_argv(self):
        result = self.shell.run("zai ask hello")
        self.assertEqual(result.returncode, 2)
        result = self.shell.run("ZSHARD_AI_COMMAND=(cat); zai ask 'hello $(noexec)'")
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.splitlines()
        self.assertEqual(json.loads(lines[0])["schema"], "zshard.context.v1")
        self.assertEqual(lines[1], "hello $(noexec)")

    def test_completion_is_lazy_and_audited(self):
        result = self.shell.run('print $_ZSHARD_COMPLETION_READY; zshard complete; '
                                'print $_ZSHARD_COMPLETION_READY; print $+functions[compdef]', interactive=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["0", "1", "1"])
        self.assertTrue((self.home / "cache/zshard").is_dir())
        self.assertEqual((self.home / "cache/zshard").stat().st_mode & 0o777, 0o700)

    def test_cli_warms_completion_cache(self):
        custom = self.home / "suite-completions"
        custom.mkdir()
        (custom / "_suite_command").write_text("#compdef suite-command\n_arguments '*:path:_files'\n")
        cache = self.home / "suite-cache"
        self.shell.env["ZSHARD_CACHE_DIR"] = str(cache)
        result = subprocess.run(["zsh", str(ROOT / "bin/zshard"), "cache", "warm", str(custom)],
                                env=self.shell.env, cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        dump = next(cache.glob("zcompdump-*"))
        self.assertIn("suite-command", dump.read_text())
        self.assertFalse((self.home / "cache/zshard").exists())

    def isolated_completion_prefix(self):
        """Use real system compinit with only private, stable completion inputs."""
        directory = self.home / "completion-fixture"
        directory.mkdir(exist_ok=True)
        locate = (
            "for name in compinit compaudit compdump compinstall; do "
            "for directory in $fpath; do "
            'if [[ -f $directory/$name ]]; then print -r -- "$directory/$name"; break; fi; '
            "done; done"
        )
        files = subprocess.check_output(["zsh", "-f", "-c", locate], env=self.shell.env, text=True).splitlines()
        self.assertEqual(len(files), 4)
        for name in files:
            shutil.copyfile(name, directory / Path(name).name)
        (directory / "_fixture").write_text("#compdef fixture\n_arguments '*:path:_files'\n")
        return "fpath=(" + shlex.quote(str(directory)) + "); "

    def test_secure_completion_dump_is_reused(self):
        prefix = self.isolated_completion_prefix()
        first = self.shell.run(prefix + "zshard complete", interactive=True)
        self.assertEqual(first.returncode, 0, first.stderr)
        dump = next((self.home / "cache/zshard").glob("zcompdump-*"))
        with dump.open("a") as output:
            output.write("\ntypeset -g ZSHARD_TEST_CACHE_REUSED=yes\n")
        dump.chmod(0o600)
        result = self.shell.run(prefix + "zshard complete; print -r -- $ZSHARD_TEST_CACHE_REUSED", interactive=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "yes")

    def test_writable_completion_dump_is_not_executed(self):
        prefix = self.isolated_completion_prefix()
        first = self.shell.run(prefix + "zshard complete", interactive=True)
        self.assertEqual(first.returncode, 0, first.stderr)
        dump = next((self.home / "cache/zshard").glob("zcompdump-*"))
        marker = self.home / "unsafe-cache-executed"
        with dump.open("a") as output:
            output.write("\nprint unsafe > " + shlex.quote(str(marker)) + "\n")
        dump.chmod(0o666)
        result = self.shell.run(prefix + "zshard complete", interactive=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(marker.exists())

    def test_prompt_escapes_git_branch(self):
        result = self.shell.run("_ZSHARD_GIT_DIR=" + shlex.quote(str(self.home)) +
                                "; _zshard_git_branch; print -r -- $_ZSHARD_BRANCH", interactive=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        (self.home / "HEAD").write_text("ref: refs/heads/%F{red}branch\n")
        result = self.shell.run("_ZSHARD_GIT_DIR=" + shlex.quote(str(self.home)) +
                                "; _zshard_git_branch; print -r -- $_ZSHARD_BRANCH", interactive=True)
        self.assertEqual(result.stdout.strip(), "%%F{red}branch")

    @unittest.skipUnless(shutil.which("strace"), "strace is optional")
    def test_startup_and_prompt_do_not_fork(self):
        trace = self.home / "trace"
        result = subprocess.run(["strace", "-f", "-e", "trace=process", "-o", str(trace),
                                 "zsh", "-f", "-i", "-c",
                                 'source "$ZSHARD_HOME/zshard.zsh"; _zshard_precmd'],
                                env=self.shell.env, cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        data = trace.read_text()
        self.assertIsNone(re.search(r"\b(?:clone|clone3|fork|vfork)\(", data), data)

    def test_pty_suggestion_accepts_without_execution(self):
        terminal = Terminal(self.home)
        try:
            output = self.home / "accepted"
            candidate = "print -r -- accepted > " + shlex.quote(str(output))
            terminal.command("print -s -- " + shlex.quote(candidate))
            self.assertFalse(output.exists())
            terminal.send("print -r -- acc")
            seen = terminal.until(b"epted", timeout=5)
            self.assertIn(b"epted", seen)
            terminal.send(b"\x06\n")
            terminal.read_for(0.15)
            self.assertEqual(output.read_text(), "accepted\n")
        finally:
            terminal.close()

    def test_pty_tab_completion(self):
        terminal = Terminal(self.home)
        try:
            target = self.home / "unique-completion-file"
            target.write_text("")
            terminal.send("print -r -- unique-comple")
            terminal.send(b"\t")
            output = terminal.until(b"tion-file", timeout=10)
            self.assertIn(b"tion-file", output)
            terminal.send(b"\n")
            terminal.read_for(0.1)
            terminal.command('[[ $_ZSHARD_COMPLETION_READY == 1 ]]')
        finally:
            terminal.close()

    def test_pty_ai_proposal_stages_until_enter(self):
        terminal = Terminal(self.home)
        try:
            marker = self.home / "must-not-run"
            terminal.command("zai propose " + shlex.quote("touch " + str(marker)))
            terminal.read_for(0.1)
            self.assertFalse(marker.exists())
            terminal.send(b"\x03")
            terminal.read_for(0.1)
            self.assertFalse(marker.exists())
        finally:
            terminal.close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
