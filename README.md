# fhir-examples — examples for the Racket FHIR family

Worked examples for the [fhir](https://github.com/oloveluck/fhir) family of Racket packages: the FHIR
languages used together in one program, FHIR operations applied like functions, and FHIR as a framework
for spec-driven development with LLMs, measured against published Implementation Guides.

## One program, six FHIR languages

[`screening/`](screening/) is a blood pressure screening written in six FHIR languages — FHIR Shorthand,
FHIR R6 resources, the FHIR Mapping Language, VCL, CQL and SQL on FHIR — each file a Racket module in its
own `#lang`, composed by one Racket program:

```racket
(require (only-in "profile.fsh" [compiled clinic]) (only-in "intake.fml" [transform intake->reading])
         (only-in "bp-panels.vcl" [valueset bp-panels]) (only-in "screening.cql" [evaluate screen]) …)

(~> form intake->reading (ensure-valid #:profile profile))
(screen patient-data #:parameters (hash "Panel Codes" codes))
```

See [screening/README.md](screening/README.md); run it with `racket screening/main.rkt`.

## FHIR operations as procedures

`examples/pipeline.rkt` maps a QuestionnaireResponse to a Patient with an FML map, validates it, and
checks its gender against the core value set, with no server:

```racket
(apply-operation "http://hl7.org/fhir/OperationDefinition/StructureMap-transform" qr #:srcMap fml)

(define transform (operation "StructureMap/$transform"))
(~> qr (transform #:srcMap fml) (ensure-valid))

(apply-operation "ValueSet/$validate-code"
                 #:url "http://hl7.org/fhir/ValueSet/administrative-gender"
                 #:system "http://hl7.org/fhir/administrative-gender" #:code "female")
```

Operations are applied by reference to their OperationDefinition, with its parameters as keywords;
the same operations serve over HTTP with a CapabilityStatement derived from them (fhir-server's
`serve-operations`). Run it with `racket examples/pipeline.rkt`.

## Spec-driven development with LLMs

FHIR Implementation Guides are machine-readable specifications: profiles, value sets, invariants and
examples, published as data. That makes them a good contract for an LLM to work against, provided
the model gets precise feedback on what it wrote.

### The loop

```
requirement (prose) ──► model writes FSH ──► raco fsh check ──► diagnostics on the FSH lines ──┐
        ▲                                                                                       │
        └──────────────────────────── fixed FSH ◄──────────────────────────────────────────────┘
                                          │
                                          ▼
            raco fsh <dir> --pack  ──►  raco fhir-server serve-ig package.tgz
```

`raco fsh check` compiles the project, validates every example against the project's own profiles
(with the IG's dependencies and FHIR core in context), and puts each problem on the FSH line that
caused it, naming the profile rule it breaks:

```
./input/fsh/examples.fsh:5:3: fsh validate error: instance tumor-1: Observation.component.value[x]: valueString is not allowed in slice 'longest' (value[x]: Quantity) (constrained by profile TumorSize at ./input/fsh/profiles.fsh:10:3)
 5 | * component[longest].valueString = "big"
   |   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
```
(from the fixture in fsh's `tests/inputs/fsh-check-bad`)

`--format json` or `--format outcome` (a FHIR OperationOutcome) gives the same to a program.

### The benchmark: prose -> FSH, scored against the published IG

`raco spec-bench` turns a real, published IG into tasks. A task takes one profile out of the IG's own
FSH sources, with its examples, and asks for it back from words:

- **The prompt** gives what the IG publishes about the profile: its description and purpose, and the
  `short`/`definition`/`comment` text of every element it constrains. It names which elements are
  constrained (the stand-in for an IG's "key elements" page) but never a constraint itself: no
  cardinality, type, binding, fixed or pattern value, or slicing.
- **The answer** is FSH: the profile and at least one example.
- **The score**, four ways, all against the profile HL7 published:
  1. `check` errors in the answer (compile, rules, its examples against its profile);
  2. fidelity: agreement with the published profile's differential, facet by facet (min, max,
     mustSupport, types and target profiles, binding, fixed/pattern values, slicing), plus a count
     of elements constrained that the IG does not constrain;
  3. accepts: the IG's own published examples, validated against the answer's profile;
  4. conforms: the answer's examples, validated against the published profile.
- **Baselines**: the IG's own FSH for the profile (the ceiling this compiler allows) and an empty
  answer.
- **Rounds**: after a round with `check` errors, the next prompt carries the previous answer and the
  diagnostics. The run stops when the answer checks clean, or after `--rounds`.

```sh
raco spec-bench list ../fsh/tests/vendor/mcode-4.0.0                       # the profiles that can be taken out
raco spec-bench make ../fsh/tests/vendor/mcode-4.0.0 hl7.fhir.us.mcode-4.0.0 TumorSize task/
raco spec-bench score task/ --oracle                                       # or --empty, or answer.fsh
raco spec-bench run task/ --model 'claude -p' --rounds 3 --timeout 1200     # any command: prompt on stdin, answer on stdout
```

A run keeps every round's prompt, raw answer, extracted FSH and score under `task/runs/<stamp>/`
and appends to `task/results.jsonl`.

### Results

Three mCODE 4.0.0 profiles, `claude -p` (Claude Code's default model), up to 3 rounds, 2026-11-03.
Every prompt, raw answer and score is in `results/2026-11-03/`.

| task | rounds | `check` errors | fidelity (oracle) | accepts published examples | its examples conform |
|---|---|---|---|---|---|
| TumorSize | 1 | 0 | **30/34** (28/34) | 0/2 | 0/1 |
| CancerDiseaseStatus | 2 (1 error fixed from the diagnostics) | 0 | **16/20** (14/20) | 0/3 | 0/1 |
| ECOGPerformanceStatus | 1 | 0 | **6/8** (5/8) | **2/2** | **1/1** |

What the numbers say:

- **Structure is recovered from prose.** On all three the answer's profile agrees with the published
  one on more facets than the IG's own FSH does when compiled by this toolchain (the oracle column).
  The gap in the oracle is this compiler's, not the IG's: mCODE's RuleSet-heavy FSH loses facets our
  compiler does not yet reproduce, while the model's plainer FSH does not.
- **The loop works as intended.** CancerDiseaseStatus's first answer required `category` but its own
  example had none; `fsh check` put that on the instance's header line, and the second answer fixed
  the example.
- **What prose cannot carry is the IG's own choices.** Every rejection of a published example traces
  to one value: the code the profile fixes. ECOG has one standard LOINC code (89247-1); the model chose
  it and both published examples validate. For TumorSize (mCODE fixes LOINC 21889-1; the model chose
  SNOMED 246116008 "Lesion size") and CancerDiseaseStatus (97509-4; the model chose 88040-1 "Response
  to cancer treatment") the IG picked one plausible code among several, and the prompt only says that
  `Observation.code` is constrained. CancerDiseaseStatus also required `category`, which mCODE does
  not, so its profile rejects examples without one.

So the remaining disagreements are decisions a spec has to state, which is the argument for writing
them down as FSH in the first place. The next step for the benchmark is a prompt variant that gives
the IG's narrative page (which names the codes), to separate "the model cannot model this" from "the
prompt did not say".

An earlier run (2026-11-02, TumorSize) is recorded only in the development session's log: its first
answer failed to parse (`* status and code and subject and (component or dataAbsentReason) MS`, an
`or` FSH does not have); with the diagnostic fed back, the second compiled at 18/34. Its prompt then
omitted constrained elements that had no published description (`Observation.code` among them),
which is why the prompt now names every constrained element.

## Install

From source, with the family's repos side by side:

```sh
raco pkg install --link --auto fhir/fhir fhir/fhir-spec fhirpath vcl fhir/fhir-validation cql fml fsh fhir/fhir-server fhir-examples
```

License: MIT. The IGs used as tasks keep their own licenses (mCODE: CC0-1.0).
