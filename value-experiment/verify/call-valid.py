"""call-valid.py — the bridge to an implementation, for the scorer (profile-verify.rkt).

    python3 call-valid.py VALIDATOR.py

An implementation is a Python function, so something in Python has to call it. This does that and
nothing else: it holds no scoring. It loads VALIDATOR.py, then reads one resource a line and
writes back, a JSON line each, what `valid` returned ({"answer": …}) or the exception it raised
({"error": …}). What counts as valid, how long a resource may take and whether the answer is the
expected one are the scorer's, in Racket. What the implementation prints goes to standard error,
so it cannot pass for an answer.
"""
import importlib.util
import json
import sys

out, sys.stdout = sys.stdout, sys.stderr


def say(message):
    out.write(json.dumps(message, default=bool) + "\n")
    out.flush()


try:
    spec = importlib.util.spec_from_file_location("validator", sys.argv[1])
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    valid = module.valid
except BaseException as e:
    say({"error": "validator.py did not load: %s: %s" % (type(e).__name__, e)})
    sys.exit(0)
say({"loaded": True})

for line in sys.stdin:
    try:
        say({"answer": valid(json.loads(line))})
    except BaseException as e:
        say({"error": "%s: %s" % (type(e).__name__, e)})
