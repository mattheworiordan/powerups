"""Track Antigravity-owned MCP processes without matching other sessions."""

import json
import os
import signal
import subprocess
from pathlib import Path
from threading import Event


def table():
    """pid -> (ppid, start, command). Start time tells a reused PID apart."""
    try:
        # -ww: procps cuts the command to $COLUMNS even into a pipe.
        out = subprocess.run(
            ["ps", "-ww", "-A", "-o", "pid=,ppid=,lstart=,command="],
            capture_output=True,
            text=True,
            env=dict(os.environ, LC_ALL="C"),
            check=False,
            timeout=2,
        ).stdout
    except (OSError, ValueError, subprocess.SubprocessError):
        return {}
    rows = {}
    for line in out.splitlines():
        f = line.split(None, 7)
        if len(f) < 7 or not f[0].isdigit() or not f[1].isdigit():
            continue
        rows[int(f[0])] = (int(f[1]), " ".join(f[2:7]), f[7] if len(f) > 7 else "")
    return rows


def watch(root, record, stopped: Event):
    seen, root_start = set(), None
    with open(record, "a") as out:
        while not stopped.is_set():
            rows = table()
            if root not in rows:
                return
            # A new start time means ROOT's PID now belongs to another process.
            if root_start is None:
                root_start = rows[root][1]
            elif rows[root][1] != root_start:
                return
            kids = {}
            for pid, (ppid, _, _) in rows.items():
                kids.setdefault(ppid, []).append(pid)
            # Linux ps reads /proc one process at a time, so a snapshot can
            # hold a parent loop; visit each PID once.
            todo, tree, found = [root], [], {root}
            while todo:
                for kid in kids.get(todo.pop(), []):
                    if kid not in found:
                        found.add(kid)
                        tree.append(kid)
                        todo.append(kid)
            for pid in tree:
                ppid, start, cmd = rows[pid]
                if (pid, start, cmd) not in seen:
                    seen.add((pid, start, cmd))
                    out.write(f"{pid}\t{start}\t{ppid}\t{cmd}\n")
            out.flush()
            stopped.wait(0.2)


def orphans(record, config, workspace):
    names = set()
    try:
        data = json.loads(Path(config).read_text())
        configured = data.get("mcpServers") if isinstance(data, dict) else {}
        servers = configured.values() if isinstance(configured, dict) else []
    except (OSError, ValueError):
        servers = []
    for s in servers:
        if not isinstance(s, dict) or not s.get("command"):
            continue
        names.add(os.path.basename(str(s["command"])))
        for arg in s.get("args") or []:
            # Flags such as -y say nothing about which server this is.
            names.update(t for t in str(arg).split() if not t.startswith("-"))
    procs = {}
    with open(record) as f:
        for line in f:
            p = line.rstrip("\n").split("\t", 3)
            if len(p) == 4 and p[0].isdigit() and p[2].isdigit():
                procs.setdefault((int(p[0]), p[1]), [int(p[2]), set()])[1].add(p[3])
    now = table()

    def running(key):
        return key[0] in now and now[key[0]][1] == key[1]

    def is_server(key):
        cmds = procs[key][1] | ({now[key[0]][2]} if running(key) else set())
        if any(workspace in cmd for cmd in cmds):
            return False
        return any(
            t in names or os.path.basename(t) in names
            for cmd in cmds
            for t in cmd.split()
        )

    kids = {}
    for key, (ppid, _) in procs.items():
        kids.setdefault(ppid, []).append(key)
    # A server whose parent is gone, even one that has exited itself: a
    # wrapper such as `npm exec` can die and leave the real server running.
    todo = [
        key
        for key, (ppid, _) in procs.items()
        if is_server(key) and not any(running(p) for p in procs if p[0] == ppid)
    ]
    seen, reap = set(), []
    while todo:
        key = todo.pop()
        if key in seen:
            continue
        seen.add(key)
        if running(key):
            reap.append(key[0])
        todo.extend(kids.get(key[0], []))
    return sorted(reap)


def reap(record: Path, home: Path, workspace: Path) -> None:
    """Reap only recorded orphaned servers, retaining native background helpers."""
    try:
        pids = orphans(
            str(record), str(home / ".gemini/config/mcp_config.json"), str(workspace)
        )
    except (OSError, ValueError):
        return
    for pid in pids:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def mcp_cache_status(home: Path) -> dict[str, list[str]]:
    """Schema cache presence is a hint, not proof of a current connection."""
    config = home / ".gemini/config/mcp_config.json"
    cache = home / ".gemini/antigravity-cli/mcp"
    try:
        data = json.loads(config.read_text())
        servers = data.get("mcpServers") if isinstance(data, dict) else {}
        names = sorted(servers) if isinstance(servers, dict) else []
    except (OSError, ValueError):
        names = []
    present = [name for name in names if (cache / name).is_dir()]
    return {
        "cached": present,
        "uncached": [name for name in names if name not in present],
    }


def prepare_prompt(args, directory: Path, home: Path) -> None:
    workspace = directory / "workspace"
    workspace.mkdir()
    status = mcp_cache_status(home)
    prefix = ""
    if args.mode == "read-only":
        prefix += "Perform a READ-ONLY task. Do not modify, write or create files. Do not run commands that change state.\n\n"
    if status["cached"] or status["uncached"]:
        prefix += (
            "MCP schema cache inventory (not verified live connections):\n"
            f"Cached schemas: {','.join(status['cached']) or 'none'}\n"
            f"No cached schemas: {','.join(status['uncached']) or 'none'}\n"
            "Do not call servers without cached schemas; complete the task using the supplied evidence and available tools.\n\n"
        )
    (workspace / "REVIEW_PROMPT.md").write_text(prefix + args.prompt_file.read_text())
