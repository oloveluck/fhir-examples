"""Run measure.py over a directory of test patients: the implementer's own check.

    python3 try.py                      measure.py over sample/, one line a patient

A patient is a directory of FHIR R4 resources, one JSON file each. For each patient the
function `evaluate(resources, valuesets, period_start, period_end)` of measure.py is called and
must answer a dict with the four keys below, each True or False.

This scores nothing: it has no expected results. An implementation is scored by spec-first.rkt
(in Racket), which calls the function through call-measure.py.
"""
import argparse
import importlib.util
import json
import os
import signal
import sys
import traceback

POPULATIONS = ["initial-population", "denominator", "denominator-exclusion", "numerator"]
SECONDS_A_PATIENT = 20


def load_measure(path):
    spec = importlib.util.spec_from_file_location("measure", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.evaluate


def resources_of(case_dir):
    out = []
    for name in sorted(os.listdir(case_dir)):
        if name.endswith(".json"):
            with open(os.path.join(case_dir, name)) as f:
                out.append(json.load(f))
    return out


def answer_of(evaluate, resources, valuesets, start, end):
    def too_long(_signum, _frame):
        raise TimeoutError("more than %d seconds for one patient" % SECONDS_A_PATIENT)

    signal.signal(signal.SIGALRM, too_long)
    signal.alarm(SECONDS_A_PATIENT)
    try:
        result = evaluate(resources, valuesets, start, end)
    finally:
        signal.alarm(0)
    if not isinstance(result, dict):
        raise TypeError("evaluate answered %r, not a dict" % (type(result).__name__,))
    missing = [p for p in POPULATIONS if p not in result]
    if missing:
        raise KeyError("the answer lacks " + ", ".join(missing))
    return {p: bool(result[p]) for p in POPULATIONS}


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser()
    ap.add_argument("--cases", default=os.path.join(here, "sample"))
    ap.add_argument("--measure", default=os.path.join(here, "measure.py"))
    ap.add_argument("--valuesets", default=os.path.join(here, "valuesets.json"))
    ap.add_argument("--period-start", default="2025-01-01")
    ap.add_argument("--period-end", default="2025-12-31")
    args = ap.parse_args()

    with open(args.valuesets) as f:
        valuesets = {name: {(s, c) for s, c in members} for name, members in json.load(f).items()}
    results = {}
    try:
        evaluate = load_measure(args.measure)
        load_error = None
    except BaseException as e:  # a measure.py that does not load is wrong on every patient
        evaluate, load_error = None, "measure.py did not load: %s: %s" % (type(e).__name__, e)
    for case in sorted(os.listdir(args.cases)):
        case_dir = os.path.join(args.cases, case)
        if not os.path.isdir(case_dir):
            continue
        if load_error:
            results[case] = {"error": load_error}
            continue
        try:
            results[case] = {"answer": answer_of(evaluate, resources_of(case_dir), valuesets,
                                                 args.period_start, args.period_end)}
        except BaseException as e:
            results[case] = {"error": "%s: %s" % (type(e).__name__, e),
                             "trace": traceback.format_exc(limit=3)}
    for case, r in results.items():
        if "answer" in r:
            print(case, " ".join("%s=%s" % (p, "yes" if r["answer"][p] else "no") for p in POPULATIONS))
        else:
            print(case, "ERROR", r["error"])
            if r.get("trace"):
                print(r["trace"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
