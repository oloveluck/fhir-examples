# Testing fhir-examples

Each example checks itself (`raco test`), and each example directory's README records its own
results. This file covers the tests at the top level and the spec-driven benchmark.

## Tests

| Test | What it checks |
|---|---|
| `screening/main.rkt` (its `test` submodule) | the seven-language program runs and the seams between the languages hold |
| `tests/intake-maps-test.rkt` | the intake-maps project checks clean, packs, and its map applies by canonical |
| `tests/bench-r4-test.rkt` | the benchmark's baselines on mCODE TumorSize: the IG's own FSH (the compiler's ceiling) and an empty answer (0) |
| `notes-to-fhir/replay-test.rkt` | the recorded notes-to-FHIR runs replay to the same scores without a model |
| `ig-servers/verify-test.rkt` | the IG servers' recorded results hold as floors, for the IGs that have been fetched |

```sh
raco test .
```

## The spec-driven benchmark (`raco spec-bench`)

A task is a published IG's FSH minus one profile and its examples. The prompt gives the IG's text
about the profile and names every element it constrains, never a constraint value. The answer is FSH:
the profile and an example. It is scored against what HL7 published, four ways: `fsh check` errors;
facet agreement with the published differential; the IG's examples validated against the answer's
profile; and the answer's examples validated against the published profile.

```sh
raco spec-bench list ../fsh/tests/vendor/mcode-4.0.0                                   # profiles a task can take out
raco spec-bench make ../fsh/tests/vendor/mcode-4.0.0 hl7.fhir.us.mcode-4.0.0 TumorSize task/
raco spec-bench score task/ answer.fsh                                                 # --oracle: the IG's own FSH; --empty
raco spec-bench run task/ --model 'claude -p' --rounds 3 --timeout 1200                # prompt on stdin, answer on stdout
```

`run` keeps each round's prompt, answer and score under `task/runs/<stamp>/`, and after a round with
`check` errors sends the diagnostics back with the next prompt.

### Results

Three mCODE 4.0.0 profiles with `claude -p`, 2026-11-03; every prompt and answer is in
[`results/`](results/). Fidelity is the facets agreed with the published differential; in parentheses,
the IG's own FSH through this compiler.

| Task | Rounds | Fidelity | Published examples accepted | Own examples conform |
|---|---|---|---|---|
| TumorSize | 1 | 30/34 (28/34) | 0/2 | 0/1 |
| CancerDiseaseStatus | 2 | 16/20 (14/20) | 0/3 | 0/1 |
| ECOGPerformanceStatus | 1 | 6/8 (5/8) | 2/2 | 1/1 |

These are the scores of 2026-11-03, with the compiler as it was that day. Two things have moved
since, so a recorded answer scored again today does not give the same numbers:

- **The baseline rose.** The IG's own FSH through this compiler now agrees on every facet: 34/34,
  20/20 and 8/8 (`raco spec-bench score task/ --oracle`), where the table's parentheses say 28/34,
  14/20 and 5/8.
- **The compiler writes what SUSHI writes.** A differential now states only what differs from the
  profile's own Parent. The recorded CancerDiseaseStatus answer chose another Parent than the
  published profile (`USCoreObservationSimple`, which already marks `status`, `code`, `subject` and
  `value[x]` must-support), so its `MS` rules no longer appear in its differential and it agrees on
  10/20 facets instead of 16/20. Fidelity compares differentials, so it rewards the published
  Parent as well as the published constraints. TumorSize is still 30/34 and ECOG 7/8 (was 6/8);
  each now also counts one `check` error, a duplicate example id the checker has reported since.

Every rejected example comes down to the code the published profile fixes (TumorSize: LOINC 21889-1,
where the answer chose SNOMED 246116008), which the prompt does not state. CancerDiseaseStatus's first
answer had one `check` error; the second round fixed it from the diagnostic.
