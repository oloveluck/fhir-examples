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
| Agents on [MedAgentBench](https://github.com/stanfordmlgroup/MedAgentBench) and [FHIR-AgentBench](https://github.com/glee4810/FHIR-AgentBench): the workspace's tools against plain REST calls on the same data, by right answers and by tokens | MedAgentBench: 300 of 300 at 6.2k tokens and 3.7 s a task with the benchmark's actions as three tools (the workspace's tools from a shell: 300 at 41k; REST: 294 at 38k). FHIR-AgentBench, 150 questions: 122 at 57k tokens a question through the workspace against 109 at 69k through REST (answered in SQL over tables: 147 at 10k, next row but one) | [`agent-bench/`](agent-bench/), `agent-bench/results/` |
| The toolkit's reading tools against a plain REST server and Python, everything else equal (one harness, the data alone, 150 questions neither had been run on; the protocol written first) | 125 and 126 of 150 right; 25.5k and 29.9k input tokens: no difference shown (−0.7 points, interval −4.0 to +2.7) | [`value-experiment/`](value-experiment/): `PROTOCOL.md`, `RESULTS.md` |
| A system built from its English narrative against the same system built from its formal specification: four published quality measures, five independent implementers of each, held to the authors' test cases | right 93.0% from the narrative, 98.4% from the CQL (+5.4 points, interval +2.1 to +9.3), 99.3% with the CQL executed; implementers agree on 88% and 96% of cases | [`value-experiment/`](value-experiment/) (`RESULTS.md`, S), `value-experiment/spec-first/` |
| An operation declared in the capability language against one built by hand in Python, through a build and three changes to its definition: three operations, five lineages of each, 752 requests written by an agent that had not seen the toolkit | by hand right on every request in all 15 lineages; declared 94.0% (−6.0 points, −8.1 to −4.1) at 2.5 times the tokens. Every miss one leniency of the framework, fixed afterwards: the same servers are then level | [`value-experiment/`](value-experiment/) (`RESULTS.md`, D), `value-experiment/definition-first/` |
| An implementation checked against its source of truth: forty Python implementations of four quality measures, each corrected by an agent that can only read, one given the authors' expected answers for sample patients, and one that can run the measure's CQL on any patient | no difference in how often they end up right (−0.7 points, −4.4 to +2.8). Reading and labelled samples fixed 5 and 6 of 65 wrong answers; the executable specification fixed 31 and broke 25, twelve of them by copying its own two disagreements with the authors | [`value-experiment/`](value-experiment/) (`RESULTS.md`, V-measure), `value-experiment/verify/` |
| This toolkit's validator against HL7's reference validator, on six US Core profiles: their 28 published examples and 713 copies with one change each | 659 of 741 verdicts the same when first measured, none refused that HL7's passes; 736 after the misses on the sample cases were fixed (578 of the 583 cases kept apart) | `value-experiment/verify/profile-cases.rkt` (`ceiling`), `verify/truth/` |
| This toolkit's FHIRPath engine against the engine inside HL7's validator: 172,527 pairs of a published expression (search parameters, invariants, each search expression continued in 116 ways) and a published resource; a fifth of the expressions read, the rest only counted | the same answer on 85.5% of the held-out pairs as first measured, 89.1% after three defects found in the sample were fixed; 99.1% when the differences that are the reference's own departures from the specification (no `toDate()`, `single()` of nothing an error, a division's digits …) are set aside | [`value-experiment/`](value-experiment/) (`RESULTS.md`, H part 1), `value-experiment/reference/` |
| A check of conformance to a profile written by an agent from the published definitions (thirty of them, one two-minute session each) against this toolkit's validator, both held to HL7's validator on 583 resources neither had seen; then each implementation corrected by a reader, a checker with labelled samples and one that can ask the toolkit's validator | written by hand: 96.3% right. The toolkit's validator: 89.5% as it was, 99.1% after its misses on the sample cases were fixed. Correcting: no difference between the three (+0.4 points for the oracle, −0.3 to +1.2) | [`value-experiment/`](value-experiment/) (`RESULTS.md`, V-profile) |
| Each language beside the JSON it compiles to, in a model's tokens | CQL 13%, VCL 28%, the mapping language 52%, an FSH instance of its profile 75% | `dsl-sizes.rkt`, [`results/2026-11-16-dsl-vs-json.md`](results/2026-11-16-dsl-vs-json.md) |
| FHIR-AgentBench answered in SQL over tables an agent defined on the FHIR store (ViewDefinitions and `.sql` files), the whole test split three times | 402, 402 and 402 of 409 at 10k tokens and 4.8 s a question (45k and 10 s before the loop on tokens and time); every question whose recorded answer can be held to is right (`fab/gate`: PASS); 267 of 270 on validation questions nobody had read | [`agent-bench/results/2026-11-16-round7.md`](agent-bench/results/2026-11-16-round7.md), [`…-held-out-and-efficiency.md`](agent-bench/results/2026-11-17-held-out-and-efficiency.md) |
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
