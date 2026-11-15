"""The only Python here: MedAgentBench's grader (refsol.py, the authors', not vendored) is Python, so
grade.rkt hands it the runs through this bridge. stdin: {"refsol_dir", "grade_base", "items": [{"id",
"task", "history": [{"role", "content"}], "result"}]}; stdout: {"<id>": true|false}. Each item is graded
by refsol's task<k> exactly as the benchmark's calculate_overall does (an exception is a miss)."""
import importlib, json, sys, types

req = json.load(sys.stdin)
answer, sys.stdout = sys.stdout, sys.stderr   # refsol prints as it grades: keep stdout for the verdicts
pkg = types.ModuleType("mabgrade"); pkg.__path__ = [req["refsol_dir"]]; sys.modules["mabgrade"] = pkg
refsol = importlib.import_module("mabgrade.refsol")


class Msg:
    def __init__(self, m): self.role, self.content = m["role"], m["content"]


class Results:
    def __init__(self, item): self.history, self.result = [Msg(m) for m in item["history"]], item["result"]


out = {}
for item in req["items"]:
    grader = getattr(refsol, item["id"].split("_")[0])
    try:
        out[item["id"]] = item["result"] is not None and grader(item["task"], Results(item), req["grade_base"]) is True
    except Exception as e:
        print(item["id"], "grader error:", e, file=sys.stderr)
        out[item["id"]] = False
print(json.dumps(out), file=answer)
