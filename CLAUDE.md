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
- **Sizes and edits** (2026-11-16): `dsl-sizes.rkt [--count '<model command>']` sets each language
  beside the JSON it compiles to over published material (IPS and mCODE profiles, examples, value
  sets; fml's corpus maps; cql's corpus libraries), in characters and in the tokens the command
  reports (its input tokens less an empty prompt's); instances also with code systems aliased
  once (`aliased`) and as instances of their profile (fsh's `fhir->fsh/of-profile`: entries by
  slice, a lone `[0]` and what the compiler fills left out, each step kept only when the text
  compiles to exactly the resource). `edit-bench.rkt --model c --out d` is the paired test for instances: one
  change in words (status, date, note, quantity; `changes-of`) to a published example the
  languages round-trip, four arms (`fsh`, `fsh-rules` — the rules that change, compiled after the
  instance's own —, `json`, `json-patch`), one round, the changed resource compared whole.
  Findings: CQL is 13% of its ELM in tokens, VCL 28% of a compose, FML 52% of a StructureMap; an
  FSH instance is 96% of compact JSON as decompiled and 75% as an instance of its profile with
  aliases; every edit arm 60/60, the rules-only answer 26 tokens against 535 for the whole JSON
  (a JSON Patch: 50). Rounds 4 to 6 of the agent benchmarks: `agent-bench/results/2026-11-16-round4.md`
  (round 6, after a zone-less search date means the record's day and the summary says when no stay
  was open: FHIR-AgentBench 122 of 150; `…-misses-by-cause.md` sorts the misses).
- **A relational schema, defined by an agent** (2026-11-16, round 7; `agent-bench/results/2026-11-16-round7.md`).
  FHIR-AgentBench's truth is SQL over MIMIC-IV's tables, so: `fab/setup-tables.rkt` (one agent
  writes ViewDefinitions and `.sql` tables over the store until the benchmark's train queries give
  its answers: 2,074 of 2,098; `--amend` for one stated change; options before OUT_DIR),
  `fab/check-tables.rkt` (those queries asked of a workspace, no model; `--ids` for any list of
  questions), `fab/make-examples.rkt` (from the train split: kinds.md, `<n>.md`, phrases.md — the
  time phrases come from the CSV's `val_dict`, a Python literal read by `read-python`),
  `fab/run.rkt`'s arm `tables` (FAB_TABLES, FAB_EXAMPLES). Development 144 and 145 of 150 (round
  6: 122), unseen (`fab/test-heldout-150.json`) 145 and 144, at 72k input tokens a question;
  MedAgentBench 300 of 300 once the prompt says the grader's `route` shape. What moved agents from
  136 to 145 was the instruction to copy the example's query whole and change three things; told
  to "adapt" it they rewrote it. A question's `template` column is never given to an agent.
  The fourth prompt (2026-11-17: current ICU stay, exact name look-up, calendar "last year",
  value-only answers) over the WHOLE test split (`test-150`, `test-heldout-150`,
  `test-fresh-109`): 400 and 399 of 409. Eight are missed every time and none can be learnt from
  the train split (six of a kind only the test split has, whose query looks a label up in lower
  case; one organism query without the upper bound train always writes; one admission type the
  export does not carry). The tables, asked the benchmark's own queries, are right for 408 of
  409. The plan for the rest is in the round's write-up ("Plan for what remains").
- `model.rkt` is the shared model runner (`ask`, `extract-block`); `run-task!` and notes-to-fhir use it.
- `run-task!` talks to the model through files (`round-N.prompt.md` on stdin, `round-N.answer.txt`),
  kills the process group past `--timeout`, and feeds `check`'s diagnostics into the next round.
  (A `system` call with string ports once hung for 90 minutes after the model exited; do not go back.)
