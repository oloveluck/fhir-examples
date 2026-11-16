# CLAUDE.md — fhir-examples

The examples repo of the fhir family (conventions, HTDP style and the package map live in the main
`fhir` repo's CLAUDE.md). Collection `fhir-examples`: `notes-to-fhir/` (free-text notes -> a model ->
FHIR checked against ig/ (FSH) with $validate, issues fed back by path; scored against answer keys;
recorded runs replayed by replay-test.rkt; `--brief` leaves the FSH out of the prompt), `screening/` (six FHIR languages — .fsh, .fhir6,
.fml, .vcl, .cql, .sof — each a module in its #lang, composed by main.rkt; `raco test` checks it),
`ig-servers/` (fetch.rkt: IG + transitive dependencies from packages.fhir.org into packages/,
gitignored, shasum-checked, packages.lock; verify.rkt: make-ig-server per IG, oracles from the IG
only — unmet, profiles resolve, examples accepted, read back, search by own values, includes,
mutations refused; main.rkt: the IG list + results/*.json; verify-test.rkt: results as floors, fetched
IGs only, no network), `examples/pipeline.rkt` (operations applied as
procedures, no server), `bench.rkt` (the spec-driven benchmark: tasks, scoring, model runs),
`cli.rkt` (`raco spec-bench`), `tests/bench-r4-test.rkt` (oracle/empty baselines on mCODE TumorSize),
`results/` (recorded runs: prompt, raw answer, FSH and score per round).

- A task = a published IG's FSH minus one leaf profile and its instances (`make-task!`), plus a prompt
  built from the published StructureDefinition's text: description/purpose and every constrained
  element's short/definition/comment — never constraint values (the test checks no pinned code leaks).
- `score-task` compiles the candidate inside the task's project with `fsh/check`, then: facet fidelity
  against the published differential (`facets`), the published examples against the candidate's
  profile, the candidate's examples against the published profile (fhir-validation, in the package
  context of the project / of the published IG).
- **A DSL against the representation it compiles to** (2026-11-16): a task has four prompts —
  `prompt.md`/`prompt-json.md` (DESIGN: the IG's words, the constraints for the model to decide) and
  `prompt-req.md`/`prompt-req-json.md` (REQUIREMENTS: the published differential in words,
  `requirements-text`: cardinality, must-support, types, bindings, patterns, slicing; neither FSH
  nor ElementDefinition syntax; only the definitions the profile uses are named) — and `score-task
  #:format 'fsh|'json`: a format's own front (`fsh-front`: `fsh check`; `json-front`: the resources
  validated as FHIR, the examples against the candidate's profile), then one FHIR-level tail.
  `json-oracle` (the published StructureDefinition and examples) scores as the IG's FSH does.
  `missed_facets` lists each published facet a candidate lacks; a primitive's fixed[x] and
  pattern[x] are one facet. `run-task! #:prompt 'requirements`, `raco spec-bench run … --format
  json --requirements`; a `claude -p --output-format json` answer is unwrapped and its tokens
  (thinking apart) recorded. `dsl-report.rkt --prompt requirements <task>…` sets the formats side
  by side over every run. The design prompt measures guessing (70% of its misses are shared by
  both formats) and names elements by ElementDefinition id, which favours JSON; the requirements
  prompt measures the encoding. Results: `results/2026-11-16-dsl-vs-json.md`.
- `model.rkt` is the shared model runner (`ask`, `extract-block`); `run-task!` and notes-to-fhir use it.
- `run-task!` talks to the model through files (`round-N.prompt.md` on stdin, `round-N.answer.txt`),
  kills the process group past `--timeout`, and feeds `check`'s diagnostics into the next round.
  (A `system` call with string ports once hung for 90 minutes after the model exited; do not go back.)
