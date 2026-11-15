#!/usr/bin/env python3
"""A fixed sample of FHIR-AgentBench questions: N from a split, spread over the question templates
(round-robin over templates in a seeded order), so a sample of 150 covers the question kinds the
split has. The test split is for reporting only; iterate on `valid`.

usage: make_sample.py <questions_answers_sql_fhir.csv> <split> <N> <seed> > sample.json
"""
import csv, json, random, sys

path, split, n, seed = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
rows = [r for r in csv.DictReader(open(path)) if r["split"] == split and r["mappable_to_fhir"] == "True"]
rng = random.Random(seed)
by = {}
for r in rows:
    by.setdefault(r["template"], []).append(r)
templates = sorted(by)
rng.shuffle(templates)
for t in templates:
    rng.shuffle(by[t])
out = []
while len(out) < min(n, len(rows)):
    for t in templates:
        if by[t] and len(out) < n:
            out.append(by[t].pop())
json.dump([{"question_id": r["question_id"], "question": r["question"], "assumption": r["assumption"],
            "patient_fhir_id": r["patient_fhir_id"], "template": r["template"]} for r in out],
          sys.stdout, indent=1)
