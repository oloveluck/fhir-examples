#!/usr/bin/env python3
"""Run FHIR-AgentBench questions with headless Claude Code agents, one question per agent.

Arms (how the agent reaches the data; the instructions are otherwise the same):
  rest       curl against a plain FHIR R4 REST server over the store (fhir-server; read and search)
  workspace  the fhir-mcp workspace verbs (`raco fhir-mcp call …`) over the same store
Each agent writes answer.json: {"answer": "...", "resources": ["Type/id", ...]}.

usage: run_fab.py ARM SAMPLE.json OUT_DIR [--model M] [--parallel K] [--limit N]
env:   FAB_STORE (the store's fhir.db, for the workspace arm), FAB_REST (default http://localhost:8765)
"""
import argparse, concurrent.futures as cf, json, os, pathlib, subprocess, sys

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
from run_agent import run_item, audit

COMMON = """You are answering a question about a patient from a hospital dataset held as FHIR R4 resources (about 930,000 of them: Patient, Encounter, Observation, Condition, Procedure, Medication, MedicationRequest, MedicationAdministration, MedicationDispense, MedicationStatement, Specimen, Location, Organization). The dates are shifted far into the future on purpose.

Question: {question}
Assumption: {assumption}
The patient: Patient/{patient_fhir_id} (the number in the question is that patient's hospital identifier).

Find the answer in the data and note which resources it rests on. Answer as a clinician's assistant would: a value with its unit, a date-time, a name, a count, yes/no — or "none" when the data holds nothing that answers the question (a legitimate answer; do not guess). "Hospital visit", "hospital stay" and "hospital encounter" mean an inpatient hospital admission; "ICU visit" an intensive-care stay; "current hospital visit" one that has not ended at the assumed current time.

When done, write answer.json in this directory: {{"answer": "<your answer>", "resources": ["Type/id", ...the resources the answer rests on]}}.

{access}
Use only that access to read the data; you may use python3 or jq to compute over what it returned. Do not look for the benchmark's files or answers."""

ACCESS = {
    "rest": """Access: a FHIR R4 REST server, with curl. Base url: {rest}
  curl -s {rest}/metadata                       the types and the search parameters of each
  curl -s "{rest}/<Type>/<id>"                  read one resource
  curl -s "{rest}/<Type>?<param>=<value>&..."   search: a Bundle (`total`, `entry`, a `next` link when it is a page)
Standard FHIR search applies: _count, _sort (-date descending), _summary=count, date prefixes (date=ge2130-01-01), token system|code, :text, references (patient=Patient/<id>), _include. Read and search are all it offers.""",
    "workspace": """Access: the FHIR workspace in this directory, from the shell:
  raco fhir-mcp call <verb> key=value ...      (verbs: check, query, run, explain, describe, write, apply)
  raco fhir-mcp tools                          the verbs and their arguments
  raco fhir guide workspace                    the guide written for agents (read it first)
The workspace's data is this dataset (a store).""",
}

TOOLS = {
    "rest": ["Bash(curl:*)", "Bash(python3:*)", "Bash(jq:*)", "Read", "Write"],
    "workspace": ["Bash(raco fhir-mcp:*)", "Bash(raco fhir guide:*)", "Bash(python3:*)", "Bash(jq:*)",
                  "Read", "Write"],
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("arm", choices=["rest", "workspace"])
    ap.add_argument("sample")
    ap.add_argument("out")
    ap.add_argument("--model", default="sonnet")
    ap.add_argument("--parallel", type=int, default=4)
    ap.add_argument("--limit", type=int, default=0)
    a = ap.parse_args()
    qs = json.load(open(a.sample))
    if a.limit:
        qs = qs[:a.limit]
    rest = os.environ.get("FAB_REST", "http://localhost:8765")
    out = pathlib.Path(a.out); out.mkdir(parents=True, exist_ok=True)
    (out / "run.json").write_text(json.dumps({"arm": a.arm, "model": a.model, "questions": len(qs)}))

    def one(q):
        work = out / q["question_id"]
        prompt = COMMON.format(access=ACCESS[a.arm].format(rest=rest), **q)
        def prepare():
            if a.arm == "workspace":
                (work / "workspace.yaml").write_text(f"fhirVersion: 4.0.1\ndata: {os.environ['FAB_STORE']}\n")
        rec = run_item(q["question_id"], prompt, work, a.model, TOOLS[a.arm], prepare=prepare)
        subprocess.run(["pkill", "-f", f"mcp-daemon.*{work}"], capture_output=True)
        bad = audit(rec, ["FHIR-AgentBench", "final_dataset", "questions_answers", "pilot", str(out.parent)])
        if bad:
            (work / "AUDIT").write_text("\n".join(bad))
        print(f"{q['question_id']:>8} {rec['seconds']:6.1f}s ${rec['cost_usd'] or 0:.3f} "
              f"{'answered' if rec['answer'] else 'NO ANSWER'}{'  AUDIT' if bad else ''}", flush=True)
        return rec

    with cf.ThreadPoolExecutor(a.parallel) as ex:
        recs = list(ex.map(one, qs))
    # the benchmark's input format for evaluation_metrics.py
    rows = []
    for q, r in zip(qs, recs):
        ans = r["answer"] or {}
        res = {}
        for ref in ans.get("resources", []) if isinstance(ans, dict) else []:
            if isinstance(ref, str) and "/" in ref:
                t, i = ref.split("/")[-2:]
                res.setdefault(t, []).append(i)
        rows.append({"question_id": q["question_id"], "question_with_context": q["question"],
                     "agent_answer": ans.get("answer") if isinstance(ans, dict) else None,
                     "agent_fhir_resources": json.dumps(res), "error": r["error"] or "",
                     "trace": r["final_message"], "usage": {"input": r["input_tokens"], "output": r["output_tokens"],
                                                           "cost_usd": r["cost_usd"], "seconds": r["seconds"],
                                                           "turns": r["turns"]}})
    (out / "agent_results.json").write_text(json.dumps(rows, indent=1))
    print(f"total ${sum(r['cost_usd'] or 0 for r in recs):.2f}, {sum(r['seconds'] for r in recs):.0f} s of agent time")


if __name__ == "__main__":
    main()
