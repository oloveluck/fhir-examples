# fhir-examples

Worked examples for the [fhir](https://github.com/oloveluck/fhir) family of FHIR languages and tools,
and a benchmark for writing FHIR profiles from prose with a model. The examples are programs written
in the family's `#lang`s; to use the languages from the command line instead, see
[the command-line tools](https://github.com/oloveluck/fhir#command-line-tools).

| Directory | What | Run |
|---|---|---|
| [`screening/`](screening/) | one program in seven languages (FSH, FHIR R6, FML, VCL, CQL, SQL on FHIR, a capability app), the seams between them checked | `racket screening/main.rkt` |
| [`examples/pipeline.rkt`](examples/pipeline.rkt) | FHIR operations applied as procedures (`$transform`, `$validate`, `$validate-code`), no server | `racket examples/pipeline.rkt` |
| [`examples/intake-maps/`](examples/intake-maps/) | a logical model, a profile and the map between them as one project | `raco fsh check examples/intake-maps` |
| [`notes-to-fhir/`](notes-to-fhir/) | clinic notes turned into FHIR by a model, held to an FSH IG by `$validate` | `racket notes-to-fhir/main.rkt --replay notes-to-fhir/results/2026-11-03T2336-brief` |
| [`ig-servers/`](ig-servers/) | servers generated from six published IGs, checked against nothing but the IGs | `racket ig-servers/main.rkt` |
| `bench.rkt` | the spec-driven benchmark: prose to FSH, scored against the published IG | `raco spec-bench` |

Each directory's README has its results. [TESTING.md](TESTING.md) covers the tests and the
benchmark's method and results.

## Install

From source, with the family's repositories side by side:

```sh
raco pkg install --link --auto fhir/fhir fhir/fhir-spec fhirpath vcl fhir/fhir-tx fhir/fhir-validation cql fml fsh fhir/fhir-server sql-on-fhir fhir-examples
raco test fhir-examples
```

License: MIT. The IGs used as tasks keep their own licenses (mCODE: CC0-1.0).
