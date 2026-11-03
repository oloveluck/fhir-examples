# One program, six FHIR languages

FHIR is specified in several languages, each made for its job: FHIR Shorthand for profiles, the FHIR
Mapping Language for transforms, CQL for clinical logic, VCL for value sets, SQL on FHIR for tabular
views, and FHIR resources themselves for data. Usually each one needs its own tool, and gluing them
together means files, command lines and formats between them.

In Racket, each of these languages is a `#lang`. A file in any of them is an ordinary module: it is
compiled — and checked in that language's terms — by `raco make`, and it `provide`s values. So one
program can `require` a profile, a map, a value set, a CQL library and a view the way it requires any
other module, and combine them with plain Racket:

```racket
(require (only-in "profile.fsh"    [compiled clinic])            ; FHIR Shorthand
         (only-in "forms.fhir6"    [->json forms])                ; FHIR R6 resources
         (only-in "intake.fml"     [transform intake->reading])   ; FHIR Mapping Language
         (only-in "bp-panels.vcl"  [valueset bp-panels])          ; ValueSet Compose Language
         (only-in "screening.cql"  [evaluate screen])             ; CQL
         (only-in "readings.sof"   [->json view-definitions]))    ; SQL on FHIR
```

What each module gives the program:

| file | language | provides | used as |
|---|---|---|---|
| `profile.fsh` | FHIR Shorthand | `compiled`: the profile, patients, clinic readings (FHIR JSON) | the data contract and the existing records |
| `forms.fhir6` | `#lang fhir/r6` | `->json`: the intake forms | data, checked against FHIR R6 at compile time |
| `intake.fml` | FHIR Mapping Language | `transform`: form → Observation | a procedure |
| `bp-panels.vcl` | VCL | `valueset` | input to `$expand` |
| `screening.cql` | CQL | `evaluate`: the library over a patient's data | a procedure: define-name → value |
| `readings.sof` | SQL on FHIR | `->json`: the ViewDefinition | input to the view engine |

And the glue is FHIR's own operations, applied like functions (`fhir/operation`), with `~>` threading a
value through them:

```racket
(~> form intake->reading (ensure-valid #:profile profile))       ; FML, then validation against FSH
($expand #:valueSet bp-panels)                                    ; the VCL value set, expanded
(screen patient-data #:parameters (hash "Panel Codes" codes))     ; CQL over the data
(view-rows view)                                                  ; SQL on FHIR, over the same data
```

`racket main.rkt`:

```
intake: 2 forms mapped and valid against http://example.org/StructureDefinition/screening-blood-pressure
panel codes (from bp-panels.vcl): 85354-9, 55284-4

patient  date        systolic  diastolic  hypertensive
ann      2026-09-14  152       96        yes
ann      2026-10-02  148       92        yes
bo       2026-10-03  124       79        no
```

## Why it works

- **Every language compiles to a module.** The reader of each `#lang` parses the language; its module
  language turns it into Racket definitions. Requiring `"screening.cql"` compiles CQL to ELM; requiring
  `"profile.fsh"` compiles FSH to FHIR resources. Errors in any of them are compile errors of this
  program, positioned in the source file of that language.
- **They share one currency: FHIR.** Every module's outputs are FHIR resources (JSON) or procedures over
  them, so nothing needs converting between languages.
- **Each language checks what it knows.** The forms are checked against the FHIR R6 model as they
  compile (a QuestionnaireResponse without `questionnaire` does not compile); the view against the SQL
  on FHIR IG's model; a reading the map produces is validated against the profile FSH defined — while
  writing this example, a map that wrote the panel code without its display was rejected by the profile.
- **Operations are procedures.** `$expand`, `$validate` and `$sql-run` are applied by reference with
  keyword parameters checked against their OperationDefinitions; the same values serve over HTTP.

## The files

- `profile.fsh` — `ScreeningBloodPressure` (an Observation: LOINC panel code, a subject, a time, a
  systolic and a diastolic component in mm[Hg]), two patients, one clinic reading.
- `forms.fhir6` — two QuestionnaireResponses (systolic / diastolic answers).
- `intake.fml` — the map; `cc` and `qty` build the coded and quantity values.
- `bp-panels.vcl` — `(http://loinc.org)(85354-9;55284-4)`.
- `screening.cql` — `Readings` (by panel code), `Highest Systolic`, `Hypertensive` (≥ 140).
- `readings.sof` — one row per reading: patient, date, systolic, diastolic (FHIRPath paths).
- `main.rkt` — the program; `raco test main.rkt` checks its results.
