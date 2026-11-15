#!/usr/bin/env python3
"""Run MedAgentBench tasks with headless Claude Code agents, one arm at a time.

Arms (how the agent reaches the EHR; everything else is the same):
  rest-hapi   curl against the benchmark's own server (HAPI FHIR, from its Docker image)
  rest-ours   curl against this family's fhir-server over the same data
  workspace   the fhir-mcp workspace verbs (`raco fhir-mcp call …`) over the same data
In every arm a POST is recorded, not sent (`./mab post`), and the answers end the task (`./mab finish`),
as the benchmark's harness does; the prompt is the benchmark's own, with the access added.

usage: run_mab.py ARM OUT_DIR [--model M] [--ids task1_1,task2_3 | --per-task N] [--parallel K]
env:   MAB_TASKS (test_data_v2.json), MAB_FUNCS (funcs_v1.json), MAB_STORE (the fhir.db of our store),
       MAB_HAPI (default http://localhost:8080/fhir/), MAB_OURS (default http://localhost:8766/)
"""
import argparse, concurrent.futures as cf, json, os, pathlib, shutil, subprocess, sys

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
from run_agent import run_item, audit

PROMPT = """You are an expert in using FHIR functions to assist medical professionals. You are given a question and a set of possible functions. Based on the question, you will need to make one or more function/tool calls to achieve the purpose.

Here is a list of functions in JSON format that you can invoke. Note that you should use {api_base} as the api_base.
{functions}

Context: {context}
Question: {question}

How to act here:
- {access}
- A POST is recorded, not sent: write the JSON payload to a file (with the Write tool), then run `./mab post <url> <file>`, for example `./mab post {api_base}Observation payload.json`. Make only the POSTs the question calls for, before you finish.
- When you have the answers and have done what was asked, run `./mab finish '<JSON list>'`, the equivalent of FINISH([answer1, answer2, ...]): the list must be JSON-loadable, and holds the answers themselves (values), not sentences. That ends the task.
Use only the access described here; do not look for the benchmark's files or answers."""

ACCESS = {
    "rest": "Read the EHR with curl, for example: curl -s '{api_base}Patient?identifier=S1234567'. Any FHIR search the server supports works; answers are JSON.",
    "workspace": ("Read the EHR through the FHIR workspace in this directory with `raco fhir-mcp call …` "
                  "(`raco fhir guide workspace` explains the verbs; e.g. "
                  "raco fhir-mcp call query language=search text='Observation?patient=S1234567&code=MG'). "
                  "There is no other access to the EHR."),
}

TOOLS = {
    "rest": ["Bash(curl:*)", "Bash(./mab:*)", "Bash(python3:*)", "Bash(jq:*)", "Read", "Write"],
    "workspace": ["Bash(raco fhir-mcp:*)", "Bash(raco fhir guide:*)", "Bash(./mab:*)", "Bash(python3:*)",
                  "Bash(jq:*)", "Read", "Write"],
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("arm", choices=["rest-hapi", "rest-ours", "workspace"])
    ap.add_argument("out")
    ap.add_argument("--model", default="sonnet")
    ap.add_argument("--ids", default="")
    ap.add_argument("--per-task", type=int, default=0)
    ap.add_argument("--parallel", type=int, default=4)
    a = ap.parse_args()

    tasks = json.load(open(os.environ["MAB_TASKS"]))
    funcs = json.load(open(os.environ["MAB_FUNCS"]))
    if a.ids:
        want = set(a.ids.split(","))
        tasks = [t for t in tasks if t["id"] in want]
    elif a.per_task:
        from run_official import first_of_each
        tasks = first_of_each(tasks, a.per_task)
    hapi = os.environ.get("MAB_HAPI", "http://localhost:8080/fhir/")
    ours = os.environ.get("MAB_OURS", "http://localhost:8766/")
    base = hapi if a.arm == "rest-hapi" else ours
    kind = "workspace" if a.arm == "workspace" else "rest"
    out = pathlib.Path(a.out); out.mkdir(parents=True, exist_ok=True)
    (out / "arm_base.txt").write_text(base)
    (out / "run.json").write_text(json.dumps({"arm": a.arm, "model": a.model, "base": base, "tasks": len(tasks)}))

    def one(t):
        work = out / t["id"]
        prompt = PROMPT.format(api_base=base, functions=json.dumps(funcs), context=t["context"],
                               question=t["instruction"], access=ACCESS[kind].format(api_base=base))
        setup = []
        def prepare():
            shutil.copy(HERE / "mab", work / "mab"); os.chmod(work / "mab", 0o755)
            if kind == "workspace":
                (work / "workspace.yaml").write_text(f"fhirVersion: 4.0.1\ndata: {os.environ['MAB_STORE']}\n")
        rec = run_item(t["id"], prompt, work, a.model, TOOLS[kind], prepare=prepare)
        subprocess.run(["pkill", "-f", f"mcp-daemon.*{work}"], capture_output=True)
        bad = audit(rec, ["refsol", "test_data", "funcs_v1", "medagentbench", str(out.parent)])
        if bad:
            (work / "AUDIT").write_text("\n".join(bad))
        print(f"{t['id']:12} {rec['seconds']:6.1f}s  ${rec['cost_usd'] or 0:.3f}  "
              f"{'answered' if rec['answer'] else 'NO ANSWER'}{'  AUDIT' if bad else ''}", flush=True)
        return rec

    with cf.ThreadPoolExecutor(a.parallel) as ex:
        recs = list(ex.map(one, tasks))
    print(f"total ${sum(r['cost_usd'] or 0 for r in recs):.2f}, {sum(r['seconds'] for r in recs):.0f} s of agent time")


if __name__ == "__main__":
    main()
