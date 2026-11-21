# fhir-examples

> Examples and measurements for [fhir](https://github.com/oloveluck/fhir), a toolkit for AI agents
> on FHIR.

Worked examples for the [fhir](https://github.com/oloveluck/fhir) family of FHIR languages and
tools, from a short program that applies FHIR operations like functions to one written in seven of
FHIR's languages — and the measurements behind the toolkit's claims: agents on two published
benchmarks, and a model writing FHIR in its languages against writing the JSON they compile to.

```
$ racket screening/main.rkt
intake: 2 forms mapped and valid against http://example.org/StructureDefinition/screening-blood-pressure
panel codes (from bp-panels.vcl): 85354-9, 55284-4

patient  date        systolic  diastolic  hypertensive
ann      2026-09-14  152       96        yes
ann      2026-10-02  148       92        yes
bo       2026-10-03  124       79        no
```

| What | Shows | Run |
|---|---|---|
| [`examples/pipeline.rkt`](examples/pipeline.rkt) | FHIR operations applied like functions, no server | `racket examples/pipeline.rkt` |
| [`examples/intake-pipeline/`](examples/intake-pipeline/) | one form through a map, a profile and a rule | `racket examples/intake-pipeline/main.rkt examples/intake-pipeline/qr.json` |
| [`examples/intake-maps/`](examples/intake-maps/) | two structures and the map between them, checked as one project | `raco fsh check examples/intake-maps` |
| [`screening/`](screening/) | one program in seven languages | `racket screening/main.rkt` |
| [`notes-to-fhir/`](notes-to-fhir/) | clinic notes turned into FHIR by a model, held to a specification | `racket notes-to-fhir/main.rkt --replay notes-to-fhir/results/2026-11-03T2336-brief` |
| [`ig-servers/`](ig-servers/) | servers generated from six published guides, checked against them (needs the network) | `racket ig-servers/main.rkt` |
| `bench.rkt` | the benchmark: prose to a profile, scored | `raco spec-bench list ../fsh/tests/vendor/mcode-4.0.0` |

## Measurements

Each has its harness here, its runs' results in the directory named, and its misses listed by cause.

| What is measured | Result | Where |
|---|---|---|
| Agents on [MedAgentBench](https://github.com/stanfordmlgroup/MedAgentBench) and [FHIR-AgentBench](https://github.com/glee4810/FHIR-AgentBench): the workspace's tools against plain REST calls on the same data, by right answers and by tokens | 297 and 294 of 300 at 38k tokens a task (since: 300 of 300 at 9.7k tokens and 3.7 s, the benchmark's actions as three tools); 118 of 150 at 55k tokens a question against 109 at 69k | [`agent-bench/`](agent-bench/), `agent-bench/results/` |
| Each language beside the JSON it compiles to, in a model's tokens | CQL 13%, VCL 28%, the mapping language 52%, an FSH instance of its profile 75% | `dsl-sizes.rkt`, [`results/2026-11-16-dsl-vs-json.md`](results/2026-11-16-dsl-vs-json.md) |
| FHIR-AgentBench answered in SQL over tables an agent defined on the FHIR store (ViewDefinitions and `.sql` files), the whole test split three times | 401, 402 and 402 of 409 at 12k tokens and 4.6 s a question (45k and 10 s before the loop on tokens and time); every question whose recorded answer can be held to is right (`fab/gate`: PASS); 267 of 270 on validation questions nobody had read | [`agent-bench/results/2026-11-16-round7.md`](agent-bench/results/2026-11-16-round7.md), [`…-held-out-and-efficiency.md`](agent-bench/results/2026-11-17-held-out-and-efficiency.md) |
| A profile written from stated requirements, as FSH and as JSON, one oracle | 1427 and 1431 of 1431 constraints; 0.9k and 1.8k answer tokens | `bench.rkt`, `dsl-report.rkt`, the same write-up |
| One change to a stored resource, answered whole or as what changes | every arm 60 of 60; 535 tokens as JSON, 26 as FSH rules | `edit-bench.rkt`, the same write-up |

## Install

The examples are Racket programs. Install the [fhir family](https://github.com/oloveluck/fhir#install)
with Racket, clone this repository beside the others, add it with
`raco pkg install --link --auto fhir-examples`, and run the commands above from this directory.

## Documentation

**[oloveluck.github.io/fhir-examples](https://oloveluck.github.io/fhir-examples/)** walks through
the examples, smallest first, and explains the benchmark and its four scores.

- The tests and the benchmark's recorded results: [TESTING.md](TESTING.md); each directory's README
  has its own results. How it is built: [CLAUDE.md](CLAUDE.md).

Part of the [fhir](https://github.com/oloveluck/fhir) family. License: MIT. The guides used as
benchmark tasks keep their own licenses (mCODE: CC0-1.0).
