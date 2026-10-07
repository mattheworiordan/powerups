#!/usr/bin/env python3
"""Non-interactive CLI calls with typed outcomes and per-call process ownership."""

from __future__ import annotations

import antigravity
import argparse
import json
import math
import os
import pwd
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from collections.abc import Callable
from pathlib import Path
from threading import Event, Thread

READ_TOOLS = "Read,Glob,Grep,WebSearch,WebFetch"
WRITE_TOOLS = "Bash,Read,Edit,Write,Glob,Grep,WebSearch,WebFetch"
AUTH = re.compile(
    r"not logged in|not authenticated|authentication required|invalid_grant|unauthorized",
    re.IGNORECASE,
)
LIMIT = re.compile(
    r"(?:hit|reached).*(?:usage|weekly|rate|limit)|rate limit|too many requests",
    re.IGNORECASE,
)


def real_home() -> Path:
    # HOME may belong to a parent's sandbox. Claude OAuth needs the OS user home.
    return Path(pwd.getpwuid(os.getuid()).pw_dir)


def binary(agent: str) -> str:
    if agent == "claude":
        path = real_home() / ".local/bin/claude"
        if not os.access(path, os.X_OK):
            raise ValueError(f"Claude binary is not executable: {path}")
        return str(path)
    path = shutil.which("agy" if agent == "antigravity" else agent)
    if not path:
        raise ValueError(f"{agent} binary not found on PATH")
    return path


def launch(
    args: argparse.Namespace, directory: Path
) -> tuple[list[str], dict[str, str]]:
    env = os.environ.copy()
    # Retain valid relative cert paths after resolving against the caller's cwd.
    for key in (
        "SSL_CERT_FILE",
        "SSL_CERT_DIR",
        "NODE_EXTRA_CA_CERTS",
        "REQUESTS_CA_BUNDLE",
        "CURL_CA_BUNDLE",
    ):
        value = env.get(key)
        if value:
            path = Path(value).absolute()
            if path.exists():
                env[key] = str(path)
            else:
                env.pop(key)
    env["TERM"] = "dumb"
    if args.agent != "antigravity":
        env["HOME"] = str(real_home())
    else:
        env.setdefault("HOME", str(real_home()))
    if args.agent == "codex":
        env["CODEX_HOME"] = str(real_home() / ".codex")
        for key in (
            "OPENAI_API_KEY",
            "CODEX_API_KEY",
            "OPENAI_BASE_URL",
            "CODEX_THREAD_ID",
            "CODEX_SESSION_ID",
        ):
            env.pop(key, None)
    argv = [binary(args.agent)]
    if args.agent == "claude":
        home = real_home()
        personal = home / ".claude-personal"
        requested = args.claude_config_dir
        if requested and requested != "personal":
            path = Path(requested.replace("~/", str(home) + "/", 1)).absolute()
            if path != personal:
                raise ValueError(
                    "Claude calls require the original ~/.claude-personal profile; other profiles are refused"
                )
        env["HOME"] = str(home)
        env["CLAUDE_CONFIG_DIR"] = str(personal)
        # A parent Claude session and API credentials must not select another account.
        for key in list(env):
            if (
                key == "CLAUDECODE" or key.startswith(("CLAUDE_", "ANTHROPIC_"))
            ) and key != "CLAUDE_CONFIG_DIR":
                env.pop(key)
        tools = READ_TOOLS if args.mode == "read-only" else WRITE_TOOLS
        argv += [
            "--safe-mode",
            "-p",
            "--output-format",
            "stream-json",
            "--verbose",
            "--strict-mcp-config",
            "--mcp-config",
            '{"mcpServers":{}}',
            "--permission-mode",
            "bypassPermissions",
            "--permission-prompts",
            "none",
            "--tools",
            tools,
            "--allowedTools",
            tools,
            "--disable-slash-commands",
            "--no-session-persistence",
            "--add-dir",
            str(args.cwd),
        ]
        for extra in args.add_dir:
            argv += ["--add-dir", str(extra)]
        if args.model:
            argv += ["--model", args.model]
        if args.reasoning_effort:
            argv += ["--effort", args.reasoning_effort]
    elif args.agent == "codex":
        argv += [
            "exec",
            "--ephemeral",
            "--color",
            "never",
            "--json",
            "--output-last-message",
            str(directory / "last-message.txt"),
            "--sandbox",
            args.mode,
            "--skip-git-repo-check",
            "-C",
            str(args.cwd),
            "-c",
            'approval_policy="never"',
        ]
        if not args.use_user_config:
            argv += ["--ignore-user-config"]
        if args.model:
            argv += ["--model", args.model]
        if args.reasoning_effort:
            argv += ["-c", f'model_reasoning_effort="{args.reasoning_effort}"']
        argv += ["-"]
    elif args.agent == "antigravity":
        workspace = directory / "workspace"
        prompt_path = workspace / "REVIEW_PROMPT.md"
        argv += [
            "-p",
            f"Read the file {json.dumps(str(prompt_path))} and follow its instructions exactly. Output only what it asks for. Do not mention the file itself.",
            "--add-dir",
            str(workspace if args.mode == "read-only" else args.cwd),
            "--add-dir",
            str(args.cwd if args.mode == "read-only" else workspace),
            "--dangerously-skip-permissions",
            "--disable-slash-commands",
            "--output-format",
            "stream-json",
            "--print-timeout",
            "0",
        ]
        for extra in args.add_dir:
            argv += ["--add-dir", str(extra)]
        if args.model:
            argv += ["--model", args.model]
        if args.reasoning_effort:
            argv += ["--effort", args.reasoning_effort]
    else:
        argv += [
            "--cwd",
            str(args.cwd),
            "--prompt-file",
            str(args.prompt_file),
            "--output-format",
            "streaming-messages-json",
            "--no-subagents",
            "--no-plan",
            "--sandbox",
            args.mode,
            "--permission-mode",
            "bypassPermissions",
            "--always-approve",
        ]
        if args.mode == "read-only":
            argv += [
                "--disallowed-tools",
                "search_replace,write",
                "--tools",
                "run_terminal_command,read_file,list_dir,grep,web_search,web_fetch",
            ]
        if args.model:
            argv += ["--model", args.model]
        if args.reasoning_effort:
            argv += ["--reasoning-effort", args.reasoning_effort]
    return argv, env


def text_blocks(content: object) -> str:
    if not isinstance(content, list):
        return ""
    return "\n".join(
        block["text"]
        for block in content
        if isinstance(block, dict)
        and block.get("type") == "text"
        and isinstance(block.get("text"), str)
    )


def parse_events(agent: str, raw: str) -> tuple[str, list[str], bool]:
    answer, errors, complete = "", [], False
    for line in raw.splitlines():
        if not line.strip():
            continue
        try:
            event = json.loads(line)
        except ValueError:
            errors.append("Malformed JSON event in stdout")
            continue
        if not isinstance(event, dict):
            errors.append("Non-object JSON event in stdout")
            continue
        if agent == "antigravity":
            if event.get("event") == "result":
                result = event.get("result")
                if not isinstance(result, dict):
                    errors.append("Malformed Antigravity result event")
                elif result.get("status") == "SUCCESS":
                    complete = True
                    answer = result.get("response", "")
                else:
                    complete = True
                    errors.append(
                        str(
                            result.get("error")
                            or result.get("response")
                            or result.get("status")
                            or "Antigravity result reported an error"
                        )
                    )
            elif event.get("event") == "error":
                errors.append(str(event.get("error") or "Antigravity error event"))
            continue
        kind = event.get("type")
        if kind == "result":
            complete = True
            if event.get("is_error"):
                errors.append(
                    str(
                        event.get("result")
                        or event.get("errors")
                        or "CLI result reported an error"
                    )
                )
            elif isinstance(event.get("result"), str) and event["result"].strip():
                answer = event["result"]
        elif kind == "assistant":
            message = event.get("message") or {}
            if isinstance(message, dict):
                candidate = text_blocks(message.get("content"))
                if candidate.strip():
                    answer = candidate
        elif kind == "item.completed" and agent == "codex":
            item = event.get("item") or {}
            if isinstance(item, dict) and item.get("type") == "agent_message":
                answer = item.get("text", "")
        elif kind == "turn.completed" and agent == "codex":
            complete = True
        elif kind in ("error", "turn.failed"):
            error = event.get("error") or event.get("message") or "CLI error event"
            errors.append(str(error))
    return answer, errors, complete


def error_status(messages: list[str]) -> str:
    text = "\n".join(messages)
    if AUTH.search(text):
        return "authentication_error"
    if LIMIT.search(text):
        return "usage_limit"
    if re.search(
        r"sandbox.*(?:could not|failed)|could not.*sandbox", text, re.IGNORECASE
    ):
        return "sandbox_error"
    return "process_error"


def stop_group(proc: subprocess.Popen) -> None:
    # Only this call's new process group; never inspect or kill other sessions.
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    proc.wait()


def execute(
    args: argparse.Namespace,
    directory: Path,
    argv: list[str],
    env: dict[str, str],
    cancelled: Callable[[], bool] = lambda: False,
) -> dict:
    started = time.monotonic()
    stdout = directory / "stdout.jsonl"
    stderr = directory / "stderr.txt"
    proc = None
    status = "ok"
    error = ""
    code = None
    launch_cwd = (
        directory / "workspace"
        if args.agent == "antigravity" and args.mode == "read-only"
        else args.cwd
    )
    tracker = None
    stopped = Event()
    record = directory / ".agy-tree-antigravity"
    try:
        if args.agent == "antigravity":
            antigravity.prepare_prompt(args, directory, Path(env["HOME"]))
            record.touch()
        with (
            args.prompt_file.open("rb") as prompt,
            stdout.open("wb") as out,
            stderr.open("wb") as err,
        ):
            proc = subprocess.Popen(
                argv,
                cwd=launch_cwd,
                env=env,
                start_new_session=True,
                stdin=prompt
                if args.agent in ("claude", "codex")
                else subprocess.DEVNULL,
                stdout=out,
                stderr=err,
            )
            if args.agent == "antigravity":
                tracker = Thread(
                    target=antigravity.watch,
                    args=(proc.pid, record, stopped),
                    daemon=True,
                )
                tracker.start()
            deadline = started + args.timeout
            while True:
                if cancelled():
                    status, error = "cancelled", "caller interrupted"
                    break
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    status, error = (
                        "timeout",
                        f"timed out after {args.timeout:g}s (no final answer)",
                    )
                    break
                try:
                    code = proc.wait(timeout=min(remaining, 0.2))
                    break
                except subprocess.TimeoutExpired:
                    continue
    except InterruptedError:
        status, error = "cancelled", "caller interrupted"
    except OSError as exc:
        status, error = "process_error", str(exc)
    finally:
        if proc:
            if (
                args.agent != "antigravity"
                or status in ("cancelled", "timeout")
                or proc.poll() is None
            ):
                stop_group(proc)
            code = proc.returncode
        if tracker:
            stopped.set()
            tracker.join(timeout=3)
            antigravity.reap(record, Path(env["HOME"]), directory / "workspace")
    raw = stdout.read_text(errors="replace") if stdout.exists() else ""
    diagnostic = stderr.read_text(errors="replace") if stderr.exists() else ""
    answer, event_errors, complete = parse_events(args.agent, raw)
    # Authentication is classified ONLY from error events or stderr, never user,
    # assistant, tool, or init content (the app itself can say "not logged in").
    failures = event_errors + (
        [diagnostic] if AUTH.search(diagnostic) or LIMIT.search(diagnostic) else []
    )
    if status == "ok":
        if failures or code != 0:
            status = error_status(failures + ([diagnostic] if code != 0 else []))
            error = (
                event_errors[0]
                if event_errors
                else f"CLI exited {code}; see stderr.txt"
            )
        elif not complete or not isinstance(answer, str) or not answer.strip():
            status, error = (
                "protocol_error",
                "CLI produced no completed, non-empty final answer",
            )
    # Historical print-mode failure: exit 0 but it asks where the prompt is.
    if (
        args.agent == "antigravity"
        and status == "ok"
        and "REVIEW_PROMPT.md" in answer
        and re.search(
            r"not found|could not (find|locate)|no such file", answer, re.IGNORECASE
        )
        and len(answer) < 800
    ):
        status, error = "protocol_error", "Antigravity could not locate its prompt file"
    result = {
        "agent": args.agent,
        "status": status,
        "exit_code": code,
        "seconds": round(time.monotonic() - started, 2),
        "error": error,
        "output_dir": str(directory),
        "mode": args.mode,
        "context": {
            "claude": "safe-mode; no custom instructions, skills, hooks or MCP",
            "codex": "native project context; user config opt-in",
            "grok": "native context; read-only tools exclude MCP execution",
            "antigravity": "native context and MCP; read-only restriction is prompt-based",
        }[args.agent],
        "answer_file": str(directory / "answer.md") if status == "ok" else None,
    }
    if status == "ok":
        (directory / "answer.md").write_text(answer.rstrip() + "\n")
        if args.agent == "antigravity":
            shutil.rmtree(directory / "workspace")
    (directory / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    return result


def parser() -> argparse.ArgumentParser:
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument(
        "--agent", required=True, choices=("claude", "grok", "codex", "antigravity")
    )
    cli.add_argument("--prompt-file", required=True, type=Path)
    cli.add_argument("--cwd", type=Path, default=Path.cwd())
    cli.add_argument(
        "--output-dir",
        type=Path,
        help="New directory for raw logs, answer and typed result",
    )
    cli.add_argument("--timeout", type=float, default=300)
    cli.add_argument(
        "--mode", choices=("read-only", "workspace-write"), default="read-only"
    )
    cli.add_argument("--model")
    cli.add_argument("--reasoning-effort")
    cli.add_argument(
        "--claude-config-dir",
        help="Only personal or the original ~/.claude-personal is accepted",
    )
    cli.add_argument("--add-dir", type=Path, action="append", default=[])
    cli.add_argument(
        "--use-user-config",
        action="store_true",
        help="Codex only: retain configured MCP servers",
    )
    cli.add_argument(
        "--dry-run",
        action="store_true",
        help="Print launch plan without executing a CLI",
    )
    return cli


def main() -> int:
    cli = parser()
    args = cli.parse_args()
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        cli.error("--timeout must be a positive, finite number")
    args.prompt_file = args.prompt_file.expanduser().resolve()
    args.cwd = args.cwd.expanduser().resolve()
    args.add_dir = [path.expanduser().resolve() for path in args.add_dir]
    if not args.prompt_file.is_file() or not args.prompt_file.stat().st_size:
        cli.error("--prompt-file must be a non-empty file")
    if not args.cwd.is_dir() or any(not path.is_dir() for path in args.add_dir):
        cli.error("--cwd and --add-dir must be existing directories")
    if args.add_dir and args.agent not in ("claude", "antigravity"):
        cli.error("--add-dir is supported only for Claude and Antigravity")
    if args.use_user_config and args.agent != "codex":
        cli.error("--use-user-config is supported only for Codex")
    directory = (
        args.output_dir.expanduser().absolute()
        if args.output_dir
        else Path(tempfile.gettempdir()) / "agent-call-preview"
    )
    try:
        argv, env = launch(args, directory)
    except ValueError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 2
    if args.dry_run:
        print(
            json.dumps(
                {
                    "cwd": str(
                        directory / "workspace"
                        if args.agent == "antigravity" and args.mode == "read-only"
                        else args.cwd
                    ),
                    "argv": argv,
                    "prompt_file": str(args.prompt_file),
                    "stdin": "prompt-file"
                    if args.agent in ("claude", "codex")
                    else "devnull",
                    "mcp_cache": antigravity.mcp_cache_status(Path(env["HOME"]))
                    if args.agent == "antigravity"
                    else None,
                    "env": {
                        key: env[key]
                        for key in ("HOME", "CLAUDE_CONFIG_DIR")
                        if key in env
                    },
                },
                indent=2,
            )
        )
        return 0
    try:
        if args.output_dir:
            directory.mkdir(parents=True, mode=0o700, exist_ok=False)
        else:
            directory = Path(tempfile.mkdtemp(prefix="agent-call-"))
        # Output-last-message must name the actual newly allocated directory.
        argv, env = launch(args, directory)
    except (OSError, ValueError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 2

    was_cancelled = False

    def interrupted(_signum, _frame):
        # Signals mark cancellation. They never interrupt cleanup or publishing
        # result.json, including when a caller repeats TERM during the grace period.
        nonlocal was_cancelled
        was_cancelled = True

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    result = execute(args, directory, argv, env, cancelled=lambda: was_cancelled)
    if result["status"] == "ok":
        sys.stdout.write((directory / "answer.md").read_text())
        return 0
    print(
        f"Error: {result['status']}: {result['error']}. Logs: {directory}",
        file=sys.stderr,
    )
    return 124 if result["status"] == "timeout" else 1


if __name__ == "__main__":
    raise SystemExit(main())
