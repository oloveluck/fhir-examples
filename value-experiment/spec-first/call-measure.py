"""call-measure.py — the bridge to an implementation, for the scorer (spec-first.rkt).

    python3 call-measure.py MEASURE.py

An implementation is a Python function, so something in Python has to call it. This does that and
nothing else: it holds no scoring. It loads MEASURE.py, reads the value sets (one JSON line) and
then one patient a line ({"resources", "start", "end"}), calls `evaluate`, and writes back, a JSON
line each, what the function returned ({"answer": …}) or the exception it raised ({"error": …}).
Whether an answer has the right shape, what counts as yes, how long a patient may take and
whether the answer is the expected one are the scorer's, in Racket. What the implementation
prints goes to standard error, so it cannot pass for an answer.
"""
import importlib.util
import json
import sys

out, sys.stdout = sys.stdout, sys.stderr


def say(message):
    out.write(json.dumps(message, default=bool) + "\n")
    out.flush()


try:
    spec = importlib.util.spec_from_file_location("measure", sys.argv[1])
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    evaluate = module.evaluate
except BaseException as e:
    say({"error": "measure.py did not load: %s: %s" % (type(e).__name__, e)})
    sys.exit(0)
say({"loaded": True})

valuesets = {name: {tuple(c) for c in members} for name, members in json.loads(sys.stdin.readline()).items()}
for line in sys.stdin:
    case = json.loads(line)
    try:
        say({"answer": evaluate(case["resources"], valuesets, case["start"], case["end"])})
    except BaseException as e:
        say({"error": "%s: %s" % (type(e).__name__, e)})
