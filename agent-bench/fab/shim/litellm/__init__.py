"""A stand-in for litellm, so FHIR-AgentBench's evaluation_metrics.py runs unmodified with Claude as
its judge: `completion(model=…, messages=…)` asks the local `claude` CLI (no tools, one turn) and
answers in litellm's shape. The judge model is FAB_JUDGE_MODEL (default the model asked for)."""
import json, os, subprocess, tempfile, types

suppress_debug_info = True
set_verbose = False


def completion(model, messages, temperature=None, **_):
    prompt = "\n\n".join(m["content"] for m in messages)
    judge = os.environ.get("FAB_JUDGE_MODEL", model)
    env = {k: v for k, v in os.environ.items() if k != "CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD"}
    with tempfile.TemporaryDirectory() as d:
        p = subprocess.run(["claude", "-p", prompt, "--model", judge, "--output-format", "json",
                            "--max-turns", "1", "--tools", ""],
                           cwd=d, env=env, capture_output=True, text=True, timeout=300)
    text = json.loads(p.stdout)["result"]
    msg = types.SimpleNamespace(content=text)
    return types.SimpleNamespace(choices=[types.SimpleNamespace(message=msg)])
