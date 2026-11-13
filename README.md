# fhir-examples

> Examples for [fhir](https://github.com/oloveluck/fhir), a FHIR implementation designed to be used by
> AI agents.

Worked examples for the [fhir](https://github.com/oloveluck/fhir) family of FHIR languages and
tools, from a short program that applies FHIR operations like functions to one written in seven of
FHIR's languages. Also a benchmark: a language model is asked to write a FHIR profile from the prose
that describes it, and the answer is scored against the profile HL7 published.

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
