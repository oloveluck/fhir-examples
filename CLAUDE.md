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
  **Carried out, and the gate** (2026-11-17): the tables are held to the benchmark's rows and
  resource ids, not only its answers (`fab/check-rows.rkt`, `fab/check-ids.rkt`; workspace
  `tables4`: 409 of 409 test queries); an agent answers with `./answer --kind N "SELECT …"`
  (`fab/answer.rkt`: runs the query, writes answer.json with the rows' `fhir_id`s — three turns
  where there were five), which says what the train split's queries of that kind would not do
  (`fab/query-checks.rkt`, checks made from the train split by `make-checks`: a time phrase
  without its condition, a name not as stored, a value selected where the question asks whether
  …). Two notes are decisive (`hold?`: the phrase belongs to other kinds than the one given; a
  value where every train query of such a question selects a comparison): the answer is NOT
  written until the query is corrected or given a second time. `fab/gate.rkt RUN_DIR…` is the
  one verdict over scored runs: as scored; `fab/set-aside.json`'s 18 questions apart (the
  recorded answer contradicts the question or needs a value the export lacks: 8 test, 10
  validation; evidence in `results/2026-11-17-note-to-benchmark-authors.md`; never given to an
  agent); the rest right every time, missed sometimes, missed every time, or JUDGED BOTH WAYS
  (the same answer, word for word, marked right in one run and wrong in another: the judge is
  a model — one such in 4,147 repeated judgements); PASS = none missed every time and at most
  `--slips` (0) missed sometimes; then what a question costs. Whole test split, three passes:
  402, 401, 402 of 409 as scored, 1202 of 1203 in scope (the one is the judge's), PASS;
  validation sample 144 of 150, 144 of 144 in scope, PASS; 45.5k input tokens, 3.2 turns, 10 s a
  question — the baseline performance work is compared with (the gate must stay PASS).
  MedAgentBench run again on the same code, graded against our own server (`mab/grade RUN
  http://localhost:<port>/` over `serve-store.rkt`; it reproduces the benchmark server's grade
  of the earlier run): 300 of 300 at 39k tokens, 3.4 turns, 7.8 s a task.
  **Held out, then the loop on tokens and time** (2026-11-17/18;
  `agent-bench/results/2026-11-17-held-out-and-efficiency.md`). The 274 validation questions
  nobody had run or read (`fab/valid-rest-274.json`): 268 of 274 as scored, 267 of 270 in scope —
  the number for unseen questions; the three misses were questions of kinds the train split
  lacks (112 of 424 validation questions are), answered with the nearest example's SELECT. For
  them, each read from the train split and said of none of its 2,522 train and validation
  queries: `./answer` holds a time selected where the question does not ask when, or none where
  it opens with "when" (`when-regular?`: 471 of 471, 350 of 350), and a first or last row picked
  from several that differ (`tie-note`; kinds whose examples return every such row:
  `same-time-kinds`); a held answer prints the kind its note names (an agent in four had given
  the held command twice, which writes it); two prompt lines (no example selects what is asked:
  the schema's column; when a visit was is when it began). `transfers` rows name the Location
  (`location_fhir_id`): citation recall 0.971 -> 0.990. Tokens and time: the tables agent has
  the shell tool alone (`builtin`: Read and Write were 950 tokens a turn); `./kind N…` prints the
  kinds asked for and the time phrases once (they were in every turn's prompt); `./answer --say`;
  and when `./answer` writes the answer with no note it ends `done: …`, on which a PostToolUse
  hook (`fab/stop-when-answered.sh`, `run-agent.rkt` `#:settings`) ends the session — the closing
  turn was pure re-reading in 74% of 1,651 replayed sessions. Whole test split, three passes:
  1205 of 1227 as scored, 1202 of 1203 in scope (the one the judge's), PASS, at 29.1k input
  tokens (45.5k before) and 7.7 s (10.0) a question; whole validation split 415 of 424, 414 of
  414 in scope, PASS. Nothing is held out any more. Next, named there: the tool's cold start
  (0.45 s opening a workspace, half of it the search catalogue SQL does not use — a change to
  fhir-mcp's sources, so the kept views are computed again once), the kinds list and the schema
  in the prompt. A
  call of the model re-reads ~11k tokens at first (4.6k the runtime and its shell tool, the rest
  the prompt: kinds.md is in every one). Do not edit the modules agents invoke (`answer`,
  `query-checks`, `run`, the `kind` script), the examples or the toolkit's sources while a run
  is going: kept views are keyed by the engine's sources. A container restart kills a run;
  `fab/run --resume` picks it up from the records.
  **Iteration 3: three tools of one process** (2026-11-19, the same write-up). Arm
  `tables-tools`: `fab/tables-server.rkt` is an MCP server over the question's workspace whose
  tools are the arm's commands (`kind`, `sql`, `answer`: answer.rkt's `answer!`, the text
  `./answer` prints in tool wording, `tool-wording`); the agent has those alone (`--tools ""`,
  `mcp__tables`), a one-sentence system prompt (`run-agent.rkt` `#:system`), and the stop hook
  on `mcp__tables__answer`. Measured before building: a call carries 4.7k tokens with the shell
  tool and the runtime's system prompt, 1.4k with neither. Whole test split, three passes: 1206
  of 1227 as scored, 1203 of 1203 in scope, PASS, at 22.4k input tokens (29.1k) and 6.5 s (7.7)
  a question; validation 414 of 414 in scope at 22.0k. The `tables` arm's prompt is unchanged to
  the byte (the two run side by side). Tried and dropped first: picking a question's kinds by
  the words it shares with train questions (the kind used is in the top 3 for 350 of 424
  validation questions, the top 8 for 405). A second working copy (`git worktree`) is where the
  next iteration is written while a run uses this one.
  **Iteration 4: the prompt holds what the first call needs** (2026-11-19, the same write-up).
  A call of the model re-reads everything before it, so the tools arm's prompt keeps what the
  first call uses (schema, kinds, how to pick one and look names up) and the `kind` tool says
  the rest with the first example, once (`examples/next.md`, written by `tables-workspace!`):
  how to write the query and give it to `answer`, and the conditions of the time phrases the
  question's own words hold (`query-checks.rkt` `time-forms`, `said-times`: 424 of 424
  validation questions' phrases found, 1.7 kinds a question, where all 31 were printed;
  `every_phrase` lists them all). kinds.md names a slot by what it holds (`[when]`,
  `[first/last]`, `{patient}`: `make-examples.rkt` `shown-template`; two time slots of one
  question read alike — numbered, one answer compared them the wrong way round). Four checks
  came with it, each said of no train query: more than one thing selected, or every column
  (`one-selected?`: held); a name compared through `lower(trim(…))` is a name
  (`name-comparisons`); an empty answer under a name that is another name of its column plus
  the kind's own next word ("tf residual output": `own-word-readings`, `answer.rkt`
  `own-word-note`); a name matched by pattern (`by-pattern`, `exact-names?`: held — 0 of 2,098
  train queries use `LIKE`). Whole test split, three passes: 1206 of 1227 as scored, 1203 of
  1203 in scope, PASS, at 17.0k input tokens (22.4k) and 6.3 s (6.5) a question; validation
  414 of 414 at 16.7k. The confirming run was started three times (a validation miss, then a
  test-pass miss, each fixed by one of the checks above from the train split).
- `model.rkt` is the shared model runner (`ask`, `extract-block`); `run-task!` and notes-to-fhir use it.
- `run-task!` talks to the model through files (`round-N.prompt.md` on stdin, `round-N.answer.txt`),
  kills the process group past `--timeout`, and feeds `check`'s diagnostics into the next round.
  (A `system` call with string ports once hung for 90 minutes after the model exited; do not go back.)
