#!/usr/bin/env python3
"""Run one benchmark item with a fresh, headless Claude Code agent and record what it cost.

The agent starts in an empty directory of its own (no CLAUDE.md, no repository notes), gets the
item's prompt and the arm's tools, and must write its answer to `answer.json` there. Recorded per
item: the answer file, the agent's final message, tokens, cost, turns, wall time, and every shell
command it ran (from the session transcript), so a run can be audited for reads of the benchmark's
own answers.

usage (library): run_item(item_id, prompt, workdir, model, allowed_tools, env_extra, timeout, max_turns,
                          prepare) -> dict
"""
import json, os, pathlib, shutil, subprocess, time

DISALLOWED = ["Task", "Agent", "WebFetch", "WebSearch", "NotebookEdit"]


def run_item(item_id, prompt, workdir, model, allowed_tools, env_extra=None, timeout=1200, max_turns=60,
             prepare=None):
    work = pathlib.Path(workdir)
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    if prepare:
        prepare()                                  # files the arm puts beside the agent
    env = dict(os.environ)
    for k in ["CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD", "PLTADDONDIR", "FHIR_MCP_DAEMON"]:
        env.pop(k, None)
    env.update(env_extra or {})
    cmd = ["claude", "-p", prompt, "--model", model, "--output-format", "json",
           "--max-turns", str(max_turns),
           "--allowedTools", *allowed_tools,
           "--disallowedTools", *DISALLOWED]
    t0 = time.monotonic()
    try:
        p = subprocess.run(cmd, cwd=work, env=env, capture_output=True, text=True, timeout=timeout)
        out, err, status = p.stdout, p.stderr, p.returncode
    except subprocess.TimeoutExpired as e:
        out, err, status = (e.stdout or b"").decode() if isinstance(e.stdout, bytes) else (e.stdout or ""), "timeout", -1
    seconds = time.monotonic() - t0
    try:
        meta = json.loads(out)
    except Exception:
        meta = {"raw": out[-2000:]}
    answer_file = work / "answer.json"
    try:
        answer = json.loads(answer_file.read_text())
    except Exception as e:
        answer = None
    usage = meta.get("usage", {})
    rec = {
        "id": item_id,
        "answer": answer,
        "final_message": meta.get("result"),
        "status": status,
        "error": None if (status == 0 and answer is not None) else (err[-500:] or "no answer.json"),
        "seconds": round(seconds, 1),
        "turns": meta.get("num_turns"),
        "cost_usd": meta.get("total_cost_usd"),
        "input_tokens": usage.get("input_tokens", 0) + usage.get("cache_read_input_tokens", 0)
                        + usage.get("cache_creation_input_tokens", 0),
        "output_tokens": usage.get("output_tokens", 0),
        "session_id": meta.get("session_id"),
        "commands": session_commands(meta.get("session_id"), work),
    }
    (work / "record.json").write_text(json.dumps(rec, indent=1))
    return rec


def session_commands(session_id, work):
    """Every Bash command the agent ran, read from its transcript (~/.claude/projects/<cwd>/<id>.jsonl)."""
    if not session_id:
        return []
    projects = pathlib.Path.home() / ".claude" / "projects"
    for f in projects.glob(f"*/{session_id}.jsonl"):
        cmds = []
        for line in f.read_text().splitlines():
            try:
                e = json.loads(line)
            except Exception:
                continue
            c = e.get("message", {}).get("content")
            if isinstance(c, list):
                for b in c:
                    if b.get("type") == "tool_use" and b.get("name") == "Bash":
                        cmds.append(b["input"].get("command", ""))
        return cmds
    return []


def audit(rec, forbidden):
    """The commands that touched a forbidden path (the benchmark's answers, its grader)."""
    return [c for c in rec.get("commands", []) if any(f in c for f in forbidden)]
