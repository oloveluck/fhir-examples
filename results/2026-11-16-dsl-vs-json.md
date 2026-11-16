# A language against the FHIR it compiles to, 2026-11-16

The question: does a model do better, and spend fewer tokens, writing and reading the family's
languages than the FHIR JSON they compile to? Four measurements, Claude Sonnet 5.5 throughout
(`claude -p`, no tools), code at fsh 90e6def, fhir 656bd5c. Tokens are the model's own count.

## 1. Sizes: each language beside its JSON (`dsl-sizes.rkt`)

Published material stated twice: IPS 2.0.1 and mCODE 4.0.0 profiles, examples and value sets
(FSH from the decompiler, which compiles back to exactly the resource; the JSON without narrative,
snapshot and expansion), fml's corpus maps, cql's corpus libraries (CQL without comments; ELM
without annotations or locators). Characters over every pair; tokens over a sample of each kind.

| artifact | pairs | language / compact JSON, chars | / indented | sampled | language, tokens | JSON compact | JSON indented | language / compact | / indented |
|---|---|---|---|---|---|---|---|---|---|
| library: CQL / ELM | 32 | 15% | 6% | 4 | 1.3k | 9.8k | 14k | **13%** | 9% |
| value set: VCL / compose | 139 | 15% | 10% | 64 | 6.5k | 24k | 32k | **28%** | 21% |
| map: FML / StructureMap | 18 | 53% | 24% | 18 | 5.8k | 11k | 17k | **52%** | 34% |
| value set: FSH / ValueSet | 139 | 95% | 65% | 26 | 21k | 26k | 33k | 78% | 62% |
| profile: FSH / StructureDefinition | 82 | 91% | 60% | 4 | 15k | 17k | 22k | 89% | 70% |
| instance: FSH / resource | 216 | 90% | 61% | 51 | 28k | 29k | 38k | 96% | 73% |

The 51 sampled instances again, with what the language can carry (each step kept only when the
text still compiles to exactly the resource):

| form | tokens | of compact JSON | of indented JSON |
|---|---|---|---|
| FSH as decompiled | 28k | 96% | 73% |
| FSH, code systems aliased once | 26k | 91% | 70% |
| FSH, an instance of its profile: entries by slice, what the profile fixes left out | 23k | 80% | 61% |
| FSH, of its profile and aliased | 21k | 75% | 57% |
| JSON compact | 29k | 100% | 76% |
| JSON indented | 38k | 131% | 100% |

Reading: the saving is where the language is at another LEVEL than the resource — a CQL
expression against its ELM tree (8x), a VCL expression against a compose (4x), a mapping rule
against a StructureMap rule (2x). An FSH instance is the resource's own data written a line to a
value; its characters are codes (39%) and references (19%), which no syntax shortens. It gains
only from what the language knows besides the text: the profile (20%) and an alias table (5%).
Indentation alone costs JSON 31%: a model that writes JSON should be asked for it compact.

## 2. Writing a profile (`bench.rkt`, `dsl-report.rkt`): 24 profiles of IPS and mCODE, FSH or JSON

One oracle for both: the published differential, facet by facet; the published examples against
the candidate; the candidate's examples against the published profile. Up to three rounds, each
format's own checker feeding back.

| prompt | arm | runs | facets right | answer tokens / run | rounds / run |
|---|---|---|---|---|---|
| design (the IG's prose; the constraints are the model's to decide) | FSH | 24 | 346/477 (72.5%) | 1.1k | 1.08 |
| | JSON | 24 | 373/477 (78.2%) | 2.2k | 1.04 |
| requirements (the differential in words), fsh as it was | FSH | 72 | 1202/1431 (84.0%) | 1.2k | 1.39 |
| | JSON | 72 | 1431/1431 | 1.8k | 1.03 |
| requirements, fsh fixed | FSH | 72 | **1427/1431 (99.7%)** | **0.9k** | 1.11 |
| | JSON | 72 | 1431/1431 | 1.8k | 1.03 |

- **The design prompt measures guessing.** 91 of FSH's 131 misses are JSON's too (what the IG
  decided and its prose does not say). The prompt names elements by ElementDefinition id
  (`Observation.value[x]:valueCodeableConcept`), which is the JSON arm's vocabulary: most of the 40
  FSH-only misses are elements so named and not translated into rules, and codes written with
  their display (a pattern that then holds the display).
- **With the requirements stated, every FSH loss but a handful was the compiler, silently.** A
  Parent given as a core canonical with its version (`…/Condition|4.0.1`, as a published
  baseDefinition reads) was taken for a type name — three tasks scored 0 and the checker's "InstanceOf
  not found" sent the model in circles; a `|version` on a profile, alias, extension or value set
  was looked up as part of the name; a type nothing defines became the type code as written. The
  same 72 first-round answers, scored again under the fixed compiler: 1134 -> 1416 facets.
- **What is left** (the fixed run): 4 facets — three are one model choice (the datatype profile of
  `medication[x]` written on a type slice instead of on the choice: the same constraint, another
  differential), one a type left off a type slice. 8 second rounds against JSON's 2: three were the
  pinned value set (fixed since: the recorded first-round answers, scored again, are clean in 67 of
  72 where they were in 64), one a `Reference(A | B)` list SUSHI refuses too, four an example
  lacking what the PARENT profile requires (`Observation.category`, us-core-21), which JSON meets
  as well (2).
- **Tokens**: the FSH answers are half the JSON answers; thinking (0.6k) and input (4k) are the
  same, so a run's output is 1.5k against 2.4k.

## 3. Changing an instance (`edit-bench.rkt`): 60 published examples, one change each

A status set, a date moved, a note added, a value's number changed — stated in words; the resource
shown as FSH or as compact JSON; one round; the oracle is the resource the change gives, whole.

| arm | correct | prompt tokens | answer tokens |
|---|---|---|---|
| FSH shown, the whole instance answered | 60/60 | 546 | 484 |
| JSON shown, the whole resource answered | 60/60 | 583 | 535 |
| FSH shown, **the rules that change** answered (laid over the instance) | 60/60 | 598 | **26** |
| JSON shown, a JSON Patch answered | 60/60 | 603 | 50 |

Whole for whole, FSH saves 9%: the size table's result again. The saving is in answering with
what changes — twenty times fewer tokens — which both forms can do; an FSH instance is already a
list of independent assignments, so its "patch" is the same language and half a JSON Patch. No arm
made a mistake: for small changes to a resource in front of it, the form does not decide correctness.

## 4. Reading a store (agent-bench, round 4)

`agent-bench/results/2026-11-16-round4.md`. In short: over the same server and data the workspace
verbs and plain REST calls are level on MedAgentBench (297 and 294 of 300, 38k input tokens a
task), and on FHIR-AgentBench's test split the workspace answers 118 of 150 at 55k tokens a
question against REST's 109 at 69k. 26 of the workspace's 32 misses are every arm's.

## What this says

- **Correctness lives in the compiler and its checker, so their defects are the model's errors.**
  The requirements run went from 84% to 99.7% without a word of the prompt changing. A language
  that is to carry a model must read everything a published artifact writes (a pinned canonical)
  and must refuse what it cannot resolve at the line, with the nearest name — a silent wrong
  answer costs rounds or is never seen.
- **Tokens are saved by level, by context, and by saying only what changes** — not by syntax. CQL,
  VCL and FML are the first kind. FSH for a profile is in between (requirements are one rule each:
  half of JSON as a model writes it). FSH for data is the second and third: the profile's fixed
  values, an alias table, and a change as a rule.
- **What to build next, in the order the numbers give**: the decompiler writing an instance OF its
  profile, entries by slice (the 20% above, and the form in which a model need not write, and
  cannot get wrong, what the profile fixes); answers and stages taking rules laid over a stored
  instance; computing in CQL or SQL in one call where an agent now takes two or three (81 of 150
  FHIR-AgentBench questions took more than one data call, and a turn is 11k tokens).
- Not measured here: writing CQL, VCL or FML against their JSON with a model (the sizes say where
  the gain would be largest; ELM by hand is not something anyone asks of a model).

Runs are kept outside the repository; the tables are `dsl-report.rkt`, `dsl-sizes.rkt --count`
and `edit-bench.rkt` printed as they came.
