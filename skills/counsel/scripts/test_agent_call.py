"""Offline outcome, launch and process-lifecycle regressions. No account calls."""

import argparse
import importlib.util
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPT = Path(__file__).with_name("agent-call.py")
spec = importlib.util.spec_from_file_location("agent_call", SCRIPT)
caller = importlib.util.module_from_spec(spec)
spec.loader.exec_module(caller)


def events(*rows):
    return "\n".join(json.dumps(row) for row in rows)


class CallerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.prompt = self.root / "prompt with spaces.txt"
        self.prompt.write_text(
            "Review `literal` $(literal)\nnot logged in\n" + "x" * 200_000
        )
        self.args = argparse.Namespace(
            agent="claude",
            prompt_file=self.prompt,
            cwd=self.root,
            mode="read-only",
            timeout=2,
            model=None,
            reasoning_effort=None,
            add_dir=[],
            use_user_config=False,
            claude_config_dir=None,
        )

    def fake(self, source):
        path = self.root / "fake-agent"
        path.write_text(f"#!{sys.executable}\n" + source)
        path.chmod(0o755)
        return str(path)

    def run_fake(self, source, agent="claude"):
        self.args.agent = agent
        directory = self.root / "out"
        directory.mkdir()
        executable = self.fake(source)
        return caller.execute(
            self.args, directory, [executable], os.environ.copy()
        ), directory

    def test_claude_personal_real_home_safe_mode_and_no_parent_auth(self):
        with (
            patch.object(caller, "binary", return_value="/real/.local/bin/claude"),
            patch.object(caller, "real_home", return_value=Path("/real")),
            patch.dict(
                os.environ,
                {
                    "HOME": "/sandbox",
                    "CLAUDE_CONFIG_DIR": "/work",
                    "CLAUDECODE": "1",
                    "CLAUDE_CODE_OAUTH_TOKEN": "secret",
                    "ANTHROPIC_API_KEY": "secret",
                    "ANTHROPIC_BASE_URL": "other",
                },
                clear=True,
            ),
        ):
            argv, env = caller.launch(self.args, self.root)
        self.assertEqual(env["HOME"], "/real")
        self.assertEqual(env["CLAUDE_CONFIG_DIR"], "/real/.claude-personal")
        self.assertNotIn("ANTHROPIC_API_KEY", env)
        self.assertNotIn("ANTHROPIC_BASE_URL", env)
        self.assertNotIn("CLAUDECODE", env)
        self.assertNotIn("CLAUDE_CODE_OAUTH_TOKEN", env)
        for flag in (
            "--safe-mode",
            "--verbose",
            "--strict-mcp-config",
            "--disable-slash-commands",
        ):
            self.assertIn(flag, argv)
        self.assertNotIn("--bare", argv)
        self.assertNotIn("", argv)
        self.assertEqual(argv[argv.index("--tools") + 1], caller.READ_TOOLS)
        self.assertNotIn("Bash", caller.READ_TOOLS)
        self.assertEqual(argv[argv.index("--mcp-config") + 1], '{"mcpServers":{}}')
        self.assertEqual(argv[argv.index("--permission-prompts") + 1], "none")
        self.assertNotIn(self.prompt.read_text(), argv)

    def test_non_personal_profile_is_refused_without_reading_it(self):
        self.args.claude_config_dir = "/real/.claude-work"
        with (
            patch.object(caller, "binary", return_value="claude"),
            patch.object(caller, "real_home", return_value=Path("/real")),
            self.assertRaisesRegex(ValueError, "other profiles are refused"),
        ):
            caller.launch(self.args, self.root)

    def test_read_only_and_write_launch_contracts(self):
        with patch.object(caller, "binary", side_effect=lambda agent: agent):
            for agent in ("grok", "codex"):
                self.args.agent = agent
                argv, _ = caller.launch(self.args, self.root)
                self.assertEqual(argv[argv.index("--sandbox") + 1], "read-only")
                if agent == "codex":
                    self.assertIn("--ignore-user-config", argv)
                    self.assertEqual(argv[-1], "-")
                    self.args.use_user_config = True
                    argv, _ = caller.launch(self.args, self.root)
                    self.assertNotIn("--ignore-user-config", argv)
                    self.args.use_user_config = False
                else:
                    self.assertIn("--always-approve", argv)
                    self.assertIn("--no-subagents", argv)
                    self.assertIn("--prompt-file", argv)
                    self.assertNotIn("--yolo", argv)
                    self.assertEqual(
                        argv[argv.index("--tools") + 1],
                        "run_terminal_command,read_file,list_dir,grep,web_search,web_fetch",
                    )
            self.args.agent = "claude"
            self.args.mode = "workspace-write"
            argv, _ = caller.launch(self.args, self.root)
            self.assertEqual(argv[argv.index("--tools") + 1], caller.WRITE_TOOLS)

    def test_auth_words_in_user_tool_init_and_answer_are_not_failure(self):
        raw = events(
            {"type": "system", "plugins": ["ably-skills", "not logged in"]},
            {
                "type": "user",
                "message": {"content": [{"type": "text", "text": "not logged in"}]},
            },
            {
                "type": "assistant",
                "message": {
                    "content": [{"type": "tool_use", "input": "not logged in"}]
                },
            },
            {
                "type": "result",
                "is_error": False,
                "result": "The app's comment says not logged in.",
            },
        )
        answer, errors, complete = caller.parse_events("claude", raw)
        self.assertEqual(errors, [])
        self.assertTrue(complete)
        self.assertIn("not logged in", answer)

    def test_result_error_not_overridden_by_later_answer(self):
        raw = events(
            {"type": "result", "is_error": True, "result": "Not logged in"},
            {
                "type": "assistant",
                "message": {"content": [{"type": "text", "text": "OK"}]},
            },
        )
        _, errors, _ = caller.parse_events("claude", raw)
        self.assertEqual(caller.error_status(errors), "authentication_error")

    def test_stream_failure_kinds_and_malformed_events(self):
        for agent in ("grok", "codex", "claude"):
            for row in (
                {"type": "error", "message": "unauthorized"},
                {"type": "turn.failed", "error": {"message": "rate limit"}},
            ):
                _, errors, _ = caller.parse_events(agent, events(row))
                self.assertTrue(errors)
        for raw in ("not JSON", "[]", "null"):
            self.assertTrue(caller.parse_events("claude", raw)[1])

    def test_grok_and_codex_final_answer_extraction(self):
        answer, errors, complete = caller.parse_events(
            "grok",
            events(
                {
                    "type": "assistant",
                    "message": {
                        "content": [
                            {"type": "thinking", "thinking": "internal"},
                            {"type": "text", "text": "review"},
                        ]
                    },
                },
                {"type": "result", "is_error": False},
            ),
        )
        self.assertEqual((answer, errors, complete), ("review", [], True))
        answer, errors, complete = caller.parse_events(
            "codex",
            events(
                {
                    "type": "item.completed",
                    "item": {"type": "command_execution", "aggregated_output": "noise"},
                },
                {
                    "type": "item.completed",
                    "item": {"type": "agent_message", "text": "review"},
                },
                {"type": "turn.completed"},
            ),
        )
        self.assertEqual((answer, errors, complete), ("review", [], True))

    def test_antigravity_native_envelopes_ignore_tool_auth_comments(self):
        raw = events(
            {"event": "init", "init": {"tools": ["not logged in"]}},
            {
                "event": "step_update",
                "step_update": {"tool_info": "app comment: not logged in"},
            },
            {
                "event": "result",
                "result": {
                    "status": "SUCCESS",
                    "response": "The app says not logged in.",
                },
            },
        )
        answer, errors, complete = caller.parse_events("antigravity", raw)
        self.assertTrue(complete)
        self.assertEqual(errors, [])
        self.assertEqual(answer, "The app says not logged in.")
        _, errors, _ = caller.parse_events(
            "antigravity",
            events(
                {
                    "event": "result",
                    "result": {"status": "ERROR", "error": "Not logged in"},
                },
            ),
        )
        self.assertEqual(caller.error_status(errors), "authentication_error")
        self.assertTrue(
            caller.parse_events(
                "antigravity", events({"event": "result", "result": []})
            )[1]
        )

    def test_antigravity_launch_plan_and_writable_root(self):
        self.args.agent = "antigravity"
        self.args.model = "test-model"
        self.args.reasoning_effort = "high"
        self.args.add_dir = [self.root]
        with patch.object(caller, "binary", return_value="agy"):
            argv, _ = caller.launch(self.args, self.root / "out")
            self.assertEqual(
                argv[argv.index("--add-dir") + 1], str(self.root / "out/workspace")
            )
            self.assertIn(
                str(self.root / "out/workspace/REVIEW_PROMPT.md"),
                argv[argv.index("-p") + 1],
            )
            self.assertEqual(argv[argv.index("--output-format") + 1], "stream-json")
            self.assertEqual(argv[argv.index("--effort") + 1], "high")
            self.assertEqual(argv[argv.index("--model") + 1], "test-model")
            self.assertNotIn(self.prompt.read_text(), argv)
            self.args.mode = "workspace-write"
            argv, _ = caller.launch(self.args, self.root / "out")
            self.assertEqual(argv[argv.index("--add-dir") + 1], str(self.root))

    def test_antigravity_success_cleans_workspace_failure_retains_prompt(self):
        good = {
            "event": "result",
            "result": {"status": "SUCCESS", "response": "review"},
        }
        result, directory = self.run_fake(
            f"import json\nprint({json.dumps(json.dumps(good))})\n", agent="antigravity"
        )
        self.assertEqual(result["status"], "ok")
        self.assertEqual((directory / "answer.md").read_text().strip(), "review")
        self.assertFalse((directory / "workspace").exists())
        shutil_remove(directory)
        partial = {"event": "step_update", "step_update": {"text_delta": "partial"}}
        result, directory = self.run_fake(
            f"import json\nprint({json.dumps(json.dumps(partial))})\n",
            agent="antigravity",
        )
        self.assertEqual(result["status"], "protocol_error")
        self.assertTrue((directory / "workspace/REVIEW_PROMPT.md").is_file())
        self.assertFalse((directory / "answer.md").exists())

    def test_antigravity_typed_prompt_not_found_stub_is_not_success(self):
        stub = {
            "event": "result",
            "result": {
                "status": "SUCCESS",
                "response": "The requested REVIEW_PROMPT.md file was not found in the current working directory.",
            },
        }
        result, directory = self.run_fake(
            f"print({json.dumps(json.dumps(stub))})\n", agent="antigravity"
        )
        self.assertEqual(result["status"], "protocol_error")
        self.assertTrue((directory / "workspace").is_dir())

    def test_removed_gemini_is_rejected_before_launch(self):
        process = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--agent",
                "gemini",
                "--prompt-file",
                str(self.prompt),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(process.returncode, 2)
        self.assertIn("invalid choice", process.stderr)

    def test_antigravity_stopped_call_reaps_helper_after_root_exits(self):
        # Force root exit before the next cancellation/deadline check, so
        # cleanup must use call status rather than the root's running state.
        for wanted in ("cancelled", "timeout"):
            with self.subTest(status=wanted):
                self.args.agent = "antigravity"
                self.args.timeout = 0.05 if wanted == "timeout" else 5
                directory = self.root / wanted
                directory.mkdir()
                pidfile = self.root / f"{wanted}.pid"
                executable = self.fake(
                    "import subprocess,time\n"
                    f'p=subprocess.Popen([{sys.executable!r},"-c","import time; time.sleep(60)"])\n'
                    f'open({str(pidfile)!r},"w").write(str(p.pid))\n'
                    "time.sleep(0.1)\n"
                )
                original = subprocess.Popen
                owned = []

                def start(*args, _original=original, _owned=owned, **kwargs):
                    process = _original(*args, **kwargs)
                    if kwargs.get("start_new_session"):
                        _owned.append(process)
                    return process

                def stopped_after_root_exit(_owned=owned, _wanted=wanted):
                    _owned[0].wait(timeout=5)
                    return _wanted == "cancelled"

                try:
                    with patch.object(caller.subprocess, "Popen", side_effect=start):
                        result = caller.execute(
                            self.args,
                            directory,
                            [executable],
                            os.environ.copy(),
                            stopped_after_root_exit,
                        )
                    self.assertEqual(result["status"], wanted)
                    self.assertEqual(result["exit_code"], 0)
                    self.assert_process_dead(int(pidfile.read_text()))
                finally:
                    if pidfile.exists():
                        try:
                            os.kill(int(pidfile.read_text()), signal.SIGKILL)
                        except ProcessLookupError:
                            pass

    def test_antigravity_malformed_cache_config_is_an_empty_inventory(self):
        config = self.root / ".gemini/config/mcp_config.json"
        config.parent.mkdir(parents=True)
        config.write_text("[]")
        self.assertEqual(
            caller.antigravity.mcp_cache_status(self.root),
            {"cached": [], "uncached": []},
        )

    def test_large_prompt_stdin_and_preserved_raw_logs(self):
        result, directory = self.run_fake(
            "import sys,json\np=sys.stdin.read()\n"
            'print(json.dumps({"type":"result","result":str(len(p)),"is_error":False}))\n'
        )
        self.assertEqual(result["status"], "ok")
        self.assertEqual(
            (directory / "answer.md").read_text().strip(),
            str(len(self.prompt.read_text())),
        )
        self.assertTrue((directory / "stdout.jsonl").is_file())
        self.assertEqual(
            json.loads((directory / "result.json").read_text())["status"], "ok"
        )

    def test_requested_cwd_is_used_for_relative_reads(self):
        (self.root / "relative.txt").write_text("TARGET_REPO")
        result, directory = self.run_fake(
            'import json,pathlib\nprint(json.dumps({"type":"result","is_error":False,"result":pathlib.Path("relative.txt").read_text()}))\n'
        )
        self.assertEqual(result["status"], "ok")
        self.assertEqual((directory / "answer.md").read_text().strip(), "TARGET_REPO")

    def test_stderr_login_failure_and_nonzero_with_answer_fail_closed(self):
        for source, wanted in (
            (
                (
                    'import sys,json\nprint(json.dumps({"type":"result","result":"review","is_error":False}))\n'
                    'print("Not logged in",file=sys.stderr)\n'
                ),
                "authentication_error",
            ),
            (
                (
                    'import sys,json\nprint(json.dumps({"type":"result","result":"review","is_error":False}))\n'
                    "sys.exit(7)\n"
                ),
                "process_error",
            ),
            (
                'import json\nprint(json.dumps({"type":"assistant","message":{"content":[{"type":"text","text":"partial"}]}}))\n',
                "protocol_error",
            ),
        ):
            with self.subTest(wanted=wanted):
                result, directory = self.run_fake(source)
                self.assertEqual(result["status"], wanted)
                self.assertFalse((directory / "answer.md").exists())
                shutil_remove(directory)

    def test_timeout_kills_own_descendant_and_discards_partial_answer(self):
        pidfile = self.root / "child.pid"
        result, directory = self.run_fake(
            "import subprocess,time,json\n"
            f'p=subprocess.Popen([{sys.executable!r},"-c","import time; time.sleep(60)"])\n'
            f'open({str(pidfile)!r},"w").write(str(p.pid))\n'
            'print(json.dumps({"type":"assistant","message":{"content":[{"type":"text","text":"partial"}]}}),flush=True)\n'
            "time.sleep(60)\n"
        )
        self.assertEqual(result["status"], "timeout")
        self.assertFalse((directory / "answer.md").exists())
        self.assert_process_dead(int(pidfile.read_text()))

    def assert_process_dead(self, pid):
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            check = subprocess.run(
                ["ps", "-p", str(pid), "-o", "stat="],
                capture_output=True,
                text=True,
                check=False,
            )
            if check.returncode or check.stdout.strip().startswith("Z"):
                return
            time.sleep(0.05)
        self.fail(f"Owned descendant {pid} survived cleanup")

    def test_repeated_cancellation_reaps_term_resistant_cli_and_children(self):
        # Exercise the real command entrypoint; only Grok on PATH is replaced.
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        pidfile = self.root / "child.pid"
        grok = bin_dir / "grok"
        grok.write_text(
            f"#!{sys.executable}\nimport subprocess,time,signal\nsignal.signal(signal.SIGTERM,signal.SIG_IGN)\n"
            f'p=subprocess.Popen([{sys.executable!r},"-c","import time; time.sleep(60)"])\n'
            f'open({str(pidfile)!r},"w").write(str(p.pid))\ntime.sleep(60)\n'
        )
        grok.chmod(0o755)
        directory = self.root / "cancel"
        env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ["PATH"])
        process = subprocess.Popen(
            [
                sys.executable,
                str(SCRIPT),
                "--agent",
                "grok",
                "--prompt-file",
                str(self.prompt),
                "--cwd",
                str(self.root),
                "--output-dir",
                str(directory),
            ],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        try:
            deadline = time.monotonic() + 5
            while not pidfile.exists() and time.monotonic() < deadline:
                time.sleep(0.05)
            self.assertTrue(pidfile.exists())
            process.send_signal(signal.SIGTERM)
            time.sleep(0.4)
            process.send_signal(signal.SIGTERM)
            _, diagnostic = process.communicate(timeout=5)
            self.assertNotIn(b"Traceback", diagnostic)
            self.assertNotEqual(process.returncode, 0)
            self.assertEqual(
                json.loads((directory / "result.json").read_text())["status"],
                "cancelled",
            )
            self.assert_process_dead(int(pidfile.read_text()))
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()


def shutil_remove(path):
    import shutil

    shutil.rmtree(path)


if __name__ == "__main__":
    unittest.main()
