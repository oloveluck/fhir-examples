#!/usr/bin/env python3
"""Grade MedAgentBench runs with the benchmark's own reference solution (refsol.py, unmodified).

refsol's graders read a session history (the agent's `POST <url>\\n<json>` messages, each followed by
"POST request accepted") and the FINISH text, and query the benchmark's FHIR server for the reference
values. A run here records its POSTs and its FINISH text (`mab`), so the history is rebuilt from them;
a POST's url is moved from the arm's server base to the grading base.

usage: grade.py RUN_DIR GRADE_BASE   (RUN_DIR holds <task id>/record.json, posts.jsonl)
       needs refsol.py and the benchmark's utils.py in $MAB_REFSOL_DIR (the grader is not vendored)
"""
import importlib, json, os, pathlib, sys, types

run_dir = pathlib.Path(sys.argv[1])
grade_base = sys.argv[2]
refsol_dir = pathlib.Path(os.environ["MAB_REFSOL_DIR"])
tasks = {t["id"]: t for t in json.load(open(os.environ["MAB_TASKS"]))}

# refsol is written as a module of a package (`from .utils import *`)
pkg = types.ModuleType("mabgrade"); pkg.__path__ = [str(refsol_dir)]; sys.modules["mabgrade"] = pkg
refsol = importlib.import_module("mabgrade.refsol")


class Msg:
    def __init__(self, role, content): self.role, self.content = role, content


class Results:
    def __init__(self, history, result): self.history, self.result = history, result


def results_of(task_dir, arm_base):
    h = task_dir / "history.json"
    if h.exists():                                # the benchmark's own protocol (run_official.py)
        history = []
        for m in json.loads(h.read_text()):
            c = m["content"]
            if m["role"] == "agent" and arm_base and c.strip().startswith("POST"):
                c = c.replace(arm_base, grade_base, 1)
            history.append(Msg(m["role"], c))
        return Results(history, json.loads((task_dir / "answer.json").read_text()).get("finish"))
    posts = []
    p = task_dir / "posts.jsonl"
    if p.exists():
        posts = [json.loads(l) for l in p.read_text().splitlines() if l.strip()]
    history = []
    for post in posts:
        url = post["url"]
        if arm_base and url.startswith(arm_base):
            url = grade_base + url[len(arm_base):]
        history.append(Msg("agent", f"POST {url}\n{json.dumps(post['payload'])}"))
        history.append(Msg("user", "POST request accepted and executed successfully."))
    answer = None
    a = task_dir / "answer.json"
    if a.exists():
        answer = json.loads(a.read_text()).get("finish")
    return Results(history, answer)


def main():
    arm_base = (run_dir / "arm_base.txt").read_text().strip() if (run_dir / "arm_base.txt").exists() else \
        json.loads((run_dir / "run.json").read_text()).get("base", "")
    rows = []
    for d in sorted(p for p in run_dir.iterdir() if p.is_dir() and p.name in tasks):
        rec = json.loads((d / "record.json").read_text()) if (d / "record.json").exists() else {}
        res = results_of(d, arm_base)
        task = tasks[d.name]
        grader = getattr(refsol, d.name.split("_")[0])
        try:
            ok = res.result is not None and grader(task, res, grade_base) is True
        except Exception as e:
            print("grader error", d.name, e)
            ok = False
        posts = sum(1 for m in res.history if m.role == "agent" and m.content.strip().startswith("POST"))
        cost = rec.get("cost_usd")
        if cost is None and (d / "answer.json").exists():
            cost = json.loads((d / "answer.json").read_text()).get("cost_usd")
        rows.append({"id": d.name, "correct": bool(ok), "finish": res.result, "posts": posts,
                     "seconds": rec.get("seconds"), "cost_usd": cost,
                     "input_tokens": rec.get("input_tokens"), "output_tokens": rec.get("output_tokens"),
                     "turns": rec.get("turns")})
    (run_dir / "grades.json").write_text(json.dumps(rows, indent=1))
    n = len(rows); c = sum(r["correct"] for r in rows)
    print(f"{run_dir.name}: {c}/{n} correct ({100*c/max(n,1):.1f}%)")
    by = {}
    for r in rows:
        t = r["id"].split("_")[0]; by.setdefault(t, []).append(r["correct"])
    for t in sorted(by, key=lambda s: int(s[4:])):
        print(f"  {t:7} {sum(by[t])}/{len(by[t])}")


if __name__ == "__main__":
    main()
