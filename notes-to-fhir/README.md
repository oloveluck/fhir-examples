# Clinic notes → FHIR that conforms to a spec

A model reads a doctor's note in plain text and writes FHIR. The spec decides whether it is right: a
small FHIR R4 Implementation Guide written in FSH (`ig/`), checked by the family's validator, with every
problem fed back to the model by resource and path until the data conforms. The conforming data then
flows on — here into the screening rule from [`../screening`](../screening) (a CQL library), unchanged.

```
clinic note (text) ─► model ─► FHIR Bundle ─► check against the FSH profiles ─► conforms ─► CQL screening rule
                        ▲                            │
                        └── issues, by resource and path ◄──┘ (until none)
```

```sh
racket notes-to-fhir/main.rkt                         # every note, live (claude -p), recorded under results/
racket notes-to-fhir/main.rkt --brief                 # the prompt names the profiles but leaves out the FSH
racket notes-to-fhir/main.rkt --replay notes-to-fhir/results/2026-11-03T2336-brief   # no model
```

## The contract (`ig/input/fsh/notes.fsh`)

Four profiles — `NotePatient` (name, gender, birth date required), `NoteBloodPressure` (the LOINC panel,
systolic and diastolic in mm[Hg], a date), `NoteProblem` (a Condition whose code must come from
`NoteProblemCodes`), `NoteMedication` (a MedicationStatement whose medication must come from
`NoteMedicationCodes`, with its dose as text) — and the two value sets (SNOMED CT diagnoses, RxNorm
ingredients). A code outside a value set is an error at its path.

## The notes (`notes/`)

Four synthetic notes in a realistic style ("HTN", "BP 152/96", "metformin 500mg twice daily"), each with
an answer key (`*.expected.json`). Each has a trap the profiles exclude: lipid and HbA1c results (not
part of the contract), "no history of hypertension or diabetes" (a negation), a father's diabetes (family
history), and a September reading with no date. No real patient data.

## What one run checks

For each answer: it is a Bundle; exactly one Patient, and every other resource's subject is that
Patient; every resource claims one of the IG's profiles and passes `$validate` against it, the IG's value
sets in context. Each failure becomes one line of feedback:

```
- Observation/bp-1: Observation.code: value does not match required pattern {"coding":[{"code":"85354-9","display":"Blood pressure panel","system":"http://loinc.org"}]}
- MedicationStatement/med-lisinopril: MedicationStatement.medication[x]: code not in required value set http://example.org/fhir/notes/ValueSet/note-medication-codes
```

The score compares the final answer's facts with the answer key: the patient's name, gender and birth
date; the blood pressure readings; the problems and the medications (right / expected, and anything
extra).

## Recorded runs (`results/`, replayed by `replay-test.rkt`)

| run | prompt | issues per round (alvarez, chen, ng, okafor) | facts |
|---|---|---|---|
| `2026-11-03T2322` | the FSH source | 0 · 0 · 0 · 0 | all right, nothing extra |
| `2026-11-03T2325-brief` | profile names and urls only | 1→1→1 · 3→2→2 · 3→1→1 · 2→1→1 | right, but never conformed |
| `2026-11-03T2336-brief` | profile names and urls only | 1→0 · 3→0 · 3→0 · 2→0 | all right, nothing extra |

- **With the spec in the prompt**, the model wrote conforming data on the first try, and avoided every
  trap.
- **Without it**, the model's first answers used RxNorm product codes (lisinopril *10 MG Oral Tablet*)
  where the value set lists ingredients, and LOINC's official display for the panel where the profile
  pins "Blood pressure panel". The value-set issues it fixed from the feedback at once. The display it
  could not: the first brief run's feedback said "value does not match required pattern" without saying
  which pattern. Naming the required value in that message (a change to the validator, made for this
  example) is the difference between the two brief runs — every note then conformed in round 2.
- The CQL screening rule then runs over each patient's extracted data: Ng (152) and Chen (158) are
  hypertensive, Okafor (124) and Alvarez (118) are not.

The point of the demo is in that middle row: the checks are only as useful to a model as their messages
are specific.
