# Servers generated from published IGs, held to the IGs

fhir-server's `make-ig-server` generates a FHIR server from an Implementation Guide package: the IG's
server CapabilityStatement gives the resource types, interactions, search parameters, includes and
operations; its SearchParameters, profiles and OperationDefinitions drive search, write validation and
operation inputs. This directory checks that generator against IGs it was not written for, using
nothing but each IG itself as the oracle — no expectation here is written by hand.

```sh
racket ig-servers/main.rkt                     # fetch, generate, verify every IG below; results/*.json
racket ig-servers/main.rkt -v hl7.fhir.uv.ipa  # one IG, every failure printed
raco test ig-servers/verify-test.rkt           # the recorded results as floors (fetched IGs only, no network)
```

## The checks (`verify.rkt`)

| check | the oracle |
|---|---|
| unmet | what the IG's CapabilityStatement requires that the generated server does not do |
| profiles | every profile an example claims resolves — otherwise validation fell back to the base type and *accepted* would prove less |
| accepted | every published example is valid, so every one must load through the server's write validation |
| read back | `GET` returns each example as written (`meta.versionId`/`lastUpdated` aside: the server assigns them) |
| search | each example is found by each search parameter the IG advertises for its type, queried with the example's own value in the shape a client sends (token `system\|code`, reference `Type/id`, date `le`/`ge` its bounds, …) |
| includes | every `_include`/`_revinclude` the server's `/metadata` advertises returns each stored resource the example references (or is referenced by) through that parameter |
| rejected | each example made invalid must be refused (422): an element its profile requires removed, a max-1 field repeated, a fixed/pattern value changed, a date that is not one, an element FHIR does not define |

## Results

| IG | types | unmet | profiles | accepted | read back | search | includes | rejected |
|---|---|---|---|---|---|---|---|---|
| International Patient Access 1.1.0 | 11 | 0 | 15/15 | 15/15 | 15/15 | 56/56 | 19/19 | 61/61 |
| AU Core 2.0.0 | 19 | 0 | 65/65 | 65/65 | 64/64 | 264/264 | 11/11 | 283/283 |
| Da Vinci PDex Plan-Net 1.2.0 | 8 | 0 | 49/49 | 87/87 | 49/49 | 212/212 | 332/332 | 182/182 |
| Da Vinci Drug Formulary 2.1.0 | 4 | 0 | 22/22 | 43/43 | 22/22 | 104/104 | 22/22 | 106/106 |
| CARIN Blue Button 2.2.0 | 6 | 0 | 42/42 | 104/104 | 42/42 | 184/184 | 144/144 | 460/460 |
| SDC 4.0.0 (form manager) | 7 | 13 | 36/36 | 80/80 | 35/35 | 29/29 | — | 158/158 |

SDC's 13: composite search parameters (`context-type-quantity`, `context-type-value`, SHOULD, on six
types) and `Questionnaire/$assemble` (MAY) — neither is implemented. (*accepted* counts the IG's own
ValueSets and CodeSystems too; AU Core's Specimen allows no read, so it is not read back.)

## What it found

The first runs failed in five places; each was a defect in the generator, fixed in fhir-server:

- **Includes written as bare names.** Drug Formulary lists `formulary-coverage` where FHIR writes
  `InsurancePlan:formulary-coverage`; the server took them for unsupported includes. A bare name is now
  read as the resource's own parameter.
- **`_include=Type:*`** (CARIN BB, SHALL) was not implemented; it now follows every reference parameter,
  for `_revinclude` too.
- **IPA's `$docref`** is US Core's operation under IPA's canonical (same parameters); only US Core's
  was served.
- **`/metadata` advertised what was not served.** IPA lists includes on PractitionerRole, which it
  makes read-only; the server's CapabilityStatement kept them, and the includes returned 404.
- **Search parameters without `search-type`.** mCODE (Patient `_id`), IPA (PractitionerRole includes)
  and SDC (76 parameters) list search parameters on types whose interactions omit `search-type`. The
  server served no search there — and counted mCODE's `_id` as met. A type that lists search
  parameters or includes is now read as searchable, so these searches are served (SDC search: 0 → 29
  probes) and the CapabilityStatement says so.

The harness's own first mistakes are worth knowing too: the server rightly overwrites
`meta.lastUpdated`, so neither read-back nor `_lastUpdated` search can expect the example's value; and
removing `meta` removes the profile claim with it, so that mutation proves nothing.

## The packages (`fetch.rkt`)

Each IG and its dependencies, transitively, from packages.fhir.org into `packages/` (not committed),
checked against the registry's shasum and recorded in `packages.lock`. Version patterns (`3.3.x`)
resolve to the newest match. Core packages come from fhir-spec; terminology, extensions and VSAC
packages are not fetched (the server does not read them: what they define is validated fail-open). The
server finds the fetched dependencies through `current-package-directories`.
