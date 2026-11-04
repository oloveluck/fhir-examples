# fhir-examples

Examples for the [fhir](https://github.com/oloveluck/fhir) family of Racket packages, and a benchmark
for writing FHIR profiles from prose with a model.
Reference: [oloveluck.github.io/fhir-examples](https://oloveluck.github.io/fhir-examples/).

| directory | what | run |
|---|---|---|
| [`screening/`](screening/) | language-oriented programming with FHIR's languages: one program in seven `#lang`s (FSH, FHIR R6, FML, VCL, CQL, SQL on FHIR, a capability app), the seams between them checked | `racket screening/main.rkt`; `raco test screening/main.rkt` |
| [`examples/pipeline.rkt`](examples/pipeline.rkt) | FHIR operations applied as procedures (`$transform`, `$validate`, `$validate-code`), no server | `racket examples/pipeline.rkt` |
| [`examples/intake-maps/`](examples/intake-maps/) | structures (a logical model, a profile) and the map between them as one project: checked, packed, the map applied by canonical | `raco fsh check examples/intake-maps`; `raco test tests/intake-maps-test.rkt` |
| [`notes-to-fhir/`](notes-to-fhir/) | clinic notes → FHIR with a model, held to an FSH IG by `$validate`, issues fed back by path; recorded runs replay without a model | `racket notes-to-fhir/main.rkt --replay notes-to-fhir/results/2026-11-03T2336-brief` |
| [`ig-servers/`](ig-servers/) | servers generated from six published IGs, checked against nothing but the IGs | `racket ig-servers/main.rkt` |
| `bench.rkt` | the spec-driven benchmark, `raco spec-bench` | below |

Each directory has its own README with its results.

## `raco spec-bench`: prose → FSH, scored against the published IG

A task is a published IG's FSH minus one profile and its examples. The prompt gives the IG's text
about the profile and names every element it constrains, never a constraint value. The answer is FSH:
the profile and an example. The score, against what HL7 published: `raco fsh check` errors; facet
agreement with the published differential; the IG's examples validated against the answer's profile;
the answer's examples validated against the published profile.

```sh
raco spec-bench list ../fsh/tests/vendor/mcode-4.0.0                                   # profiles a task can take out
raco spec-bench make ../fsh/tests/vendor/mcode-4.0.0 hl7.fhir.us.mcode-4.0.0 TumorSize task/
raco spec-bench score task/ answer.fsh                                                 # --oracle: the IG's own FSH; --empty
raco spec-bench run task/ --model 'claude -p' --rounds 3 --timeout 1200                # prompt on stdin, answer on stdout
```

`run` keeps each round's prompt, answer and score under `task/runs/<stamp>/`, and after a round with
`check` errors sends the diagnostics back with the next prompt.

Results for three mCODE 4.0.0 profiles with `claude -p`, 2026-11-03 (every prompt and answer is in
[`results/`](results/)). Fidelity is facets agreed with the published differential; in parentheses, the
IG's own FSH through this compiler.

| task | rounds | fidelity | published examples accepted | own examples conform |
|---|---|---|---|---|
| TumorSize | 1 | 30/34 (28/34) | 0/2 | 0/1 |
| CancerDiseaseStatus | 2 | 16/20 (14/20) | 0/3 | 0/1 |
| ECOGPerformanceStatus | 1 | 6/8 (5/8) | 2/2 | 1/1 |

Every rejected example comes down to the code the published profile fixes (TumorSize: LOINC 21889-1,
where the answer chose SNOMED 246116008), which the prompt does not state. CancerDiseaseStatus's first
answer had one `check` error; the second round fixed it from the diagnostic.

## Install

From source, with the family's repos side by side:

```sh
raco pkg install --link --auto fhir/fhir fhir/fhir-spec fhirpath vcl fhir/fhir-tx fhir/fhir-validation cql fml fsh fhir/fhir-server sql-on-fhir fhir-examples
```

License: MIT. The IGs used as tasks keep their own licenses (mCODE: CC0-1.0).
