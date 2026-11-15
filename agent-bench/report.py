#!/usr/bin/env python3
"""One table of a run of both benchmarks: per arm, what the graders said and what it cost.

usage: report.py RUN_DIR   (holds mab-<arm>/grades.json from mab/grade.py and fab-<arm>/eval/*_eval.json
                            from fab/score.sh, plus each item's record.json)
Prints markdown: the MedAgentBench table (overall and per task kind), the FHIR-AgentBench table, and
the misses of each arm (MedAgentBench task ids; FHIR-AgentBench questions with both answers).
"""
import glob, json, pathlib, statistics, sys

run = pathlib.Path(sys.argv[1])


def records(d):
    out = {}
    for f in d.glob("*/record.json"):
        r = json.loads(f.read_text())
        out[r["id"]] = r
    return out


def mab():
    arms = sorted(p for p in run.glob("mab-*") if (p / "grades.json").exists())
    if not arms:
        return
    print("## MedAgentBench\n")
    print("| arm | correct | cost | input tokens / task | agent time / task |")
    print("|---|---|---|---|---|")
    kinds = {}
    for a in arms:
        g = json.loads((a / "grades.json").read_text())
        n, c = len(g), sum(r["correct"] for r in g)
        cost = sum(r["cost_usd"] or 0 for r in g)
        toks = [r["input_tokens"] for r in g if r.get("input_tokens")]
        secs = [r["seconds"] for r in g if r.get("seconds")]
        print(f"| {a.name[4:]} | {c}/{n} ({100*c/max(n,1):.1f}%) | ${cost:.2f} | "
              f"{statistics.mean(toks)/1000:.0f}k | {statistics.mean(secs):.0f} s |" if toks else
              f"| {a.name[4:]} | {c}/{n} ({100*c/max(n,1):.1f}%) | ${cost:.2f} | — | — |")
        for r in g:
            k = r["id"].split("_")[0]
            kinds.setdefault(k, {}).setdefault(a.name[4:], []).append(r["correct"])
    names = [a.name[4:] for a in arms]
    print("\n| task kind | " + " | ".join(names) + " |")
    print("|---|" + "---|" * len(names))
    for k in sorted(kinds, key=lambda s: int(s[4:])):
        print(f"| {k} | " + " | ".join(f"{sum(kinds[k].get(n, []))}/{len(kinds[k].get(n, []))}" for n in names) + " |")
    print()
    for a in arms:
        g = json.loads((a / "grades.json").read_text())
        miss = [r["id"] for r in g if not r["correct"]]
        print(f"- {a.name[4:]} misses ({len(miss)}): {', '.join(miss)}")
    print()


def fab():
    arms = sorted(p for p in run.glob("fab-*") if glob.glob(str(p / "eval" / "*_eval.json")))
    if not arms:
        return
    print("## FHIR-AgentBench\n")
    print("| arm | correct | retrieval precision | retrieval recall | cost | input tokens / q | agent time / q |")
    print("|---|---|---|---|---|---|---|")
    for a in arms:
        ev = json.loads(pathlib.Path(glob.glob(str(a / "eval" / "*_eval.json"))[0]).read_text())
        recs = records(a)
        n, c = len(ev), sum(int(e["answer_correctness"]) for e in ev)
        prec = statistics.mean(e["precision"] for e in ev if e["precision"] is not None)
        rec = statistics.mean(e["recall"] for e in ev if e["recall"] is not None)
        cost = sum((r["cost_usd"] or 0) for r in recs.values())
        toks = statistics.mean(r["input_tokens"] for r in recs.values())
        secs = statistics.mean(r["seconds"] for r in recs.values())
        print(f"| {a.name[4:]} | {c}/{n} ({100*c/max(n,1):.1f}%) | {prec:.2f} | {rec:.2f} | ${cost:.2f} | {toks/1000:.0f}k | {secs:.0f} s |")
    print()
    for a in arms:
        ev = json.loads(pathlib.Path(glob.glob(str(a / "eval" / "*_eval.json"))[0]).read_text())
        miss = [e for e in ev if not int(e["answer_correctness"])]
        print(f"### {a.name[4:]} misses ({len(miss)})")
        for e in miss:
            print(f"- `{e['question_id'][:8]}` {e['question']}  \n  truth: {e['true_answer_extracted']}  ·  answer: {str(e['agent_answer'])[:160]}")
        print()


mab()
fab()
