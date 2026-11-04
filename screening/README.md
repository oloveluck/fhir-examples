# Language-oriented programming, with FHIR's languages

FHIR is specified in several languages, each made for its job: FHIR Shorthand for profiles, the FHIR
Mapping Language for transforms, CQL for clinical logic, VCL for value sets, SQL on FHIR for tabular
views, a CapabilityStatement for what a server does, and FHIR resources themselves for data. Each
usually needs its own tool, and gluing them together means files, command lines and formats in
between.

Language-oriented programming turns that around: give each language a `#lang`, and a file in it is an
ordinary module. It is compiled, and checked in that language's terms, when the program that uses it
compiles; it `provide`s values; and one program can `require` a profile, a map, a value set, a CQL
library, a view and a server declaration the way it requires any other module, and combine them with
plain Racket. This directory is one such program.

```racket
(require (only-in "profile.fsh"    [compiled clinic])            ; FHIR Shorthand
         (only-in "forms.fhir6"    [->json forms])                ; FHIR R6 resources
         (only-in "intake.fml"     [transform intake->reading] [fml bp-intake])   ; FHIR Mapping Language
         (only-in "bp-panels.vcl"  [valueset bp-panels])          ; ValueSet Compose Language
         (only-in "screening.cql"  [evaluate screen])             ; CQL
         (only-in "readings.sof"   [->json view-definitions]))    ; SQL on FHIR
```

| file | language | provides | used as |
|---|---|---|---|
| `profile.fsh` | FHIR Shorthand | `compiled`: the profile, patients, clinic readings (FHIR JSON) | the data contract and the existing records |
| `forms.fhir6` | `#lang fhir/r6` | `->json`: the intake forms | data, checked against FHIR R6 at compile time |
| `intake.fml` | FHIR Mapping Language | `transform`: form → Observation; `fml`: the map | a procedure, and a map to check |
| `bp-panels.vcl` | VCL | `valueset` | input to `$expand` |
| `screening.cql` | CQL | `evaluate`: the library over a patient's data | a procedure: define-name → value |
| `readings.sof` | SQL on FHIR | `->json`: the ViewDefinition | input to the view engine |
| `pipeline.rkt` | Racket | the composition: `intake-readings`, `screening`, `readings` | the program |
| `app.rkt` | `#lang fhir/capability` | `app`: the composition as a FHIR server; `$screen`: the pipeline as an operation value | served over HTTP, `/metadata` derived; applied in-process |

The glue is FHIR's own operations, applied like functions (`fhir/operation`), with `~>` threading a
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

## What a `#lang` gives each language

- **A reader and a module language.** The reader parses the language (brag grammars ported from the
  official ANTLR grammars where they exist); the module language turns the parse into Racket
  definitions. Requiring `"screening.cql"` compiles CQL to ELM; requiring `"profile.fsh"` compiles FSH to
  FHIR resources; requiring `"intake.fml"` lowers the map to its AST with real FHIRPath inside.
- **Errors are compile errors of this program**, positioned in the source file of that language:
  `file:line:col`, the line, a caret, in the same `fhir/diagnostic` shape for every language.
- **One currency: FHIR.** Every module's values are FHIR resources (JSON) or procedures over them, so
  nothing is converted between languages, and FHIR's operations are the function calls between them.

## The seams are checked too

A program in several languages is only as sound as the places where they meet. Here each seam is a
check, and each check is positioned in the language where the fix belongs:

- **The map against the structures.** `intake.fml` names the profile `profile.fsh` defines as its
  target structure, by canonical. Before any form is mapped, `main.rkt` runs `check-map` on it: an
  element the structure lacks, a value of the wrong type, a required element no rule assigns, each
  reported on its line in `intake.fml`. (`raco test` plants a misspelt element and checks the line.)
- **The mapped data against the profile.** Each reading the map produces is validated under the
  profile FSH defined (`ensure-valid`); a reading that does not conform stops the program with an
  OperationOutcome saying which element. While writing this example, a map that wrote the panel code
  without its display was rejected by the profile.
- **Data against the model.** The forms are checked against the FHIR R6 model as they compile (a
  QuestionnaireResponse without `questionnaire` does not compile); the view against the SQL on FHIR
  IG's model.
- **The module system is the FHIR registry.** Requiring a module registers what it defines, by
  canonical (`fhir/registry`): `profile.fsh` its profile, so `ensure-valid #:profile` and the map's
  `uses` find it with no data source to set up; `intake.fml` its map, so
  `(apply-operation "StructureMap/$transform" form #:source "http://…/bp-intake")` resolves it;
  `bp-panels.vcl` its value set. The only `current-data-source` left in the program is the data the
  rule and the view run over.
- **A failure at run time points at its rule.** A `check` in a map that does not hold raises a
  diagnostic positioned in `intake.fml`, and `$transform` returns it as an OperationOutcome with the
  line, exactly as a parse error is reported.

## The seventh language: the composition, served

`app.rkt` is a `#lang fhir/capability` module. It *declares* what a server supports — the profile's
Observations, the map as `StructureMap/$transform`, `$validate`, `$expand`, and the pipeline itself
as `$screen` — and the language *derives* the CapabilityStatement from the declarations, so
`/metadata` cannot drift from what runs. An inline declaration is also an operation *value*: `$screen`
is defined, registered by its canonical and provided, so `main.rkt` applies it in-process
(`($screen #:patient "ann")`, `(apply-operation "$screen" …)`) and a client POSTs to `/$screen`, through
one handler. `racket screening/app.rkt` prints the CapabilityStatement; `raco fhir-server serve
screening/app.rkt 8080` serves it; `raco test main.rkt` drives it through the router.

## The files

- `profile.fsh` — `ScreeningBloodPressure` (an Observation: LOINC panel code, a subject, a time, a
  systolic and a diastolic component in mm[Hg]), two patients, one clinic reading.
- `forms.fhir6` — two QuestionnaireResponses (systolic / diastolic answers).
- `intake.fml` — the map, targeting the profile by canonical; `cc` and `qty` build the coded and
  quantity values.
- `bp-panels.vcl` — `(http://loinc.org)(85354-9;55284-4)`.
- `screening.cql` — `Readings` (by panel code), `Highest Systolic`, `Hypertensive` (≥ 140).
- `readings.sof` — one row per reading: patient, date, systolic, diastolic (FHIRPath paths).
- `pipeline.rkt` — the composition: the map checked against the structures, the forms mapped and
  validated, the value set expanded, the rule and the view.
- `app.rkt` — the composition as a FHIR server, and the pipeline as the operation `$screen`.
- `main.rkt` — the program; `raco test main.rkt` checks its results, the seams, the operation in
  process and the server.

The same idea at the scale of a project rather than a program: `../examples/intake-maps/`, where
structures (FSH) and the map between them (FML) are checked and packed as one package by
`raco fsh check` and `raco fsh --pack`.
