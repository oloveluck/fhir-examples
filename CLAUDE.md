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
  **Iteration 5: what the first call can leave to the tools** (2026-11-21, the same write-up).
  Read from iteration 4's sessions call by call. (1) The shape note (`answer.rkt` `shape-note`)
  is printed only beside another note: alone it fired on 479 of 2,090 first answers, changed
  none, and cost a third call in 23% of sessions. (2) The `kind` tool takes the names the
  question gives (`names`) and answers how the tables write each (`tables-server.rkt`
  `names-text`: exact spellings by column, in the columns train queries compare with a name —
  `query-checks.rkt` `name-columns`, checks.json `names`; else the names that hold it and the
  names it holds as whole words), so the first call asks `sql` nothing and the schema comes
  with the first example, not in the prompt (`run.rkt` `next-steps`; the prompt 10.0k -> 6.8k
  characters; the other arms' prompts unchanged to the byte). (3) The agents do not inherit the
  hosted session they are started from (`run-agent.rkt` `withheld`: CLAUDE_CODE_REMOTE,
  CLAUDE_CODE_REMOTE_SESSION_ID, CLAUDE_CODE_ENTRYPOINT — 1,380 tokens a call of reminders
  about this session; `AGENT_BENCH_KEEP_SESSION=1` keeps them). The look-up replaced what the
  agents' own queries had shown them, and the confirmation found three misses, each fixed
  from the train split: a name is given with what every train query states beside it
  (`name-companions`, checks.json `beside`: `d_items.label` with `d_items.linksto`, 449 of
  449); beside an exact match, a longer name of the same columns that the question's own
  words spell (`held-statement`: "ostomy (output)"); a word that, in ten train questions or
  more, always goes with one selected column holds a query that selects another
  (`said-columns`, checks.json `says`: specimen, sex, discharged, terms; said of none of the
  2,522 train and validation queries). The container was replaced mid-run (a faster machine:
  iteration 4's code takes 5.4 s a question here, 6.0 before), so the comparison is on one
  machine, the same 150 validation questions back to back: iteration 4's code 16.7k tokens and
  5.4 s; the toolkit's changes 13.4k and 4.6 s; with the session withheld 11.5k and 4.5 s.
  Whole test split, three passes: 1205 of 1227 as scored, 1202 of 1203 in scope (the one the
  judge's: an answer word for word that of the passes marked right), PASS, at 11.8k input
  tokens (17.0k; the 90th percentile 12.5k, was 24.2k) and 4.6 s a question; validation 414
  of 414 at 11.5k. `tool-server.rkt` is the tool protocol the two tool servers share
  (`tool`, `handle`, `serve-tools`). Scratch analysis (`timeline.py` over the sessions'
  timestamps): of a question's 4.5 s the model's two calls are 2.8, the tools 0.4, the
  runtime's start and end 1.2.
  **Iteration 6: MedAgentBench by the same two moves** (2026-11-21, the same write-up). Arm
  `workspace-tools` (`mab/run.rkt`, `mab/tools-server.rkt`, `mab/stop-when-finished.sh`): the
  agent's only tools are `query` (the workspace's verb, defined by the arm in fhir-mcp's words
  for search, find and SQL, so the server says its tools 0.17 s after it starts and opens the
  workspace behind them — `open-reader`, `delay/thread`; loading the toolkit first took 0.70 s,
  which the first call of the model waited for), `post` (the payload as its argument;
  `mab.rkt` `post!`) and `finish` (`finish!`; its definition says an answer is a bare value,
  and a number written as a string is held once: `quoted-numbers`). Its prompt
  (`tools-template`, `tools-prompt`) is the question, three sentences on reading, how to act
  and the benchmark's definitions of the three functions that write (`writing-functions`,
  `tasks.rkt` `functions-text`): the six reading functions and the reading card are not in it
  (agents made 347 searches, five finds and one describe in 300 tasks). One machine, each
  graded by `refsol.py` against our server (`results/2026-11-21-mab/`): `workspace` (shell)
  300 of 300 at 40.6k input tokens and 6.4 s a task; the actions as tools 300 at 21.4k and
  4.9 s; with the prompt of what the first call uses 300 and 300 at 9.7k and 3.7 s (83% of
  sessions two calls of the model). The other arms' prompts are unchanged to the byte
  (`analysis/mab-prompt.rkt` against a working copy at the commit before). After adding an
  export to `tasks.rkt`, `raco make mab/*.rkt`: `racket -l-` loads the other modules' stale
  compiled files and fails on the contract.
  **Iteration 7: what a POST takes, said by `post`** (2026-11-21, the same write-up). The three
  POST definitions were 1.9k of a first call's 4.2k tokens and three sessions in four post
  nothing: the prompt names the functions that write (`function-url`, `function-title`), and
  `post` with the url alone answers that one's definition (`tools-server.rkt`
  `post-definitions`, read from the task's `functions.json`, which `run.rkt`
  `post-definitions` writes) as lines — `tasks.rkt` `function-outline`: each value of the JSON
  schema by its path, with the benchmark's words (1.2k tokens for the three where the JSON is
  1.9k) — with the grader's note for that resource (`grader-notes`: the route as plain text,
  `note` as one object; they were in every prompt). A POST written before its definition was
  said is held once (0 of 600 sessions). Two passes: 300 and 300 at 6.2k input tokens and
  3.7 s a task (iteration 6: 9.7k, 3.7 s); a first call is 2.3k tokens; agents ask for the
  definition in the same call as their first search four times in five.
  **Iteration 8: what both calls re-read** (2026-11-22, the same write-up). Counted in the
  model's tokens (scratch `count-tokens.py`: a one-word session with and without a text): the
  tools arm's prompt was 2.3k, 1.5k of it the kinds list, and the second call re-reads it; the
  `kind` tool's answer 3.6k, 1.5k of it the schema. For the tools arm alone (the other arms'
  prompts unchanged to the byte): the kinds list without what every kind says (`run.rkt`
  `short-kinds-list`, `short-kind`: "patient {patient}" is P, "of P" and `[when]` left out, a
  slot one word; about 1.0k tokens; which kind is picked moves no more than between two runs
  of one code, 7 of 150); the schema a line a table (`fab/schema-lines.md`, `schema-lines`:
  0.8k tokens; `schema-columns` holds it to schema.md's tables and columns in a test); and
  what each tool does said by its definition alone. Tried and put back: a shorter step 3 —
  its list of what the notes are about works as an instruction (left out, two questions of 150
  were answered with a time where they ask whether, and held: a third call). Same machine,
  the same 150 validation questions: 11.6k -> 9.9k tokens, 4.7 to 4.9 s either way. Whole
  validation split 414 of 414 in scope at 9.9k; whole test split, three passes: 1206 of 1227
  as scored, 1203 of 1203 in scope, PASS, at 10.0k input tokens (11.8k; a first call 3.3k, a
  second 6.3k) and 4.8 s. A working copy run by `racket <copy>/…/run.rkt` must be compiled
  whole (`raco make fab/*.rkt *.rkt`): its tool server, started by path, otherwise compiles
  itself at every start (1.5 s a question, which looked like a slower prompt).
- **The value experiment** (2026-11-22; `value-experiment/PROTOCOL.md`, written and committed
  before any run): does the language route (the languages, checked and run by the toolkit) make
  an agent more often right, cheaper or safer than the general route (FHIR JSON over REST and
  Python), with everything else held equal — model, harness (tools of one process, no shell),
  training material, a preparing agent, the validator behind writes, tuning effort (an agent
  whose only goal is to make the general route win gets 5 iterations on the development tasks),
  rounds. Four experiments: A1 FHIR-AgentBench and A2 MedAgentBench (third-party truth, but L
  has been scored on every question of both), B writing under rules with traps and C computing
  over a population (truth by construction, tasks written by an agent that has not seen the
  toolkit: what a claim should rest on). "Significant value" is defined there (right more often
  by 5 points with the interval above zero; or not worse by 3 at two thirds of the cost).
  `value-experiment/analysis.rkt`: the paired bootstrap, McNemar's exact test, Holm, the
  verdict; `analysis.rkt fab L=RUN,… G=RUN,…` over scored runs. Built so far: arm `rest-tools`
  (`fab/rest-server.rkt`; the other arms' prompts unchanged to the byte). Its smoke, ten
  development questions, unprepared and untuned: 9 of 10 at 40k input tokens and 5 calls (the
  shell REST arm of round 4: 69k), so the harness alone is a large part of what the tools arms
  saved. Ten questions decide nothing.
  **Narrowed and run: M** (the same day; the protocol's amendment, `value-experiment/RESULTS.md`).
  The owner asked for just enough to tell whether the FHIR tools add value over the harness
  alone. Arm `mcp-tools` (`raco fhir-mcp`'s query and describe, the reading card; the same
  `python` and `answer` from `rest-server.rkt WORK -`, which then reaches no data) against
  `rest-tools`, one pass of `test-heldout-150` (never run on either, nor on the workspace or MCP
  arms): 125 and 126 of 150; the difference −0.7 points (interval −4.0 to +2.7); input tokens
  25.5k against 29.9k, ratio 0.85 (0.69 to 1.05). No difference shown, a clear null by the
  protocol's bounds: the generic reading tools add nothing significant over REST and Python
  under the same harness. 21 questions are missed by both, and `tables-tools` is right on 19 of
  them (148 of the 150 at 10k tokens) — but that arm also has the training split's examples and
  checks, so what carries it is not isolated (the protocol's A1 would). `analysis.rkt` says
  whether a null is a clear one (`clear-null?`). A first start was discarded: the REST server
  had died before it (started with `nohup … &` from a tool call; start it with `setsid`), and
  the run script now checks the server before and after each arm.
  **S: narrative first against spec first** (the same day; the protocol's second amendment, the
  same RESULTS.md). The owner's hypothesis: English lacks the specificity a language provides;
  the spec, not the narrative, is the source of truth. `value-experiment/spec-first/`:
  `materials.rkt` (cql's vendored ecqm-content-qicore-2024: four measures, each with its
  published English narrative, its CQL and included libraries, its terminology, its authors' 190
  test cases — a fifth shown to implementers without expected results and with names removed,
  the rest scored), `try.py` (the implementers' own check: a `measure.py` over their sample, no
  expected results), `call-measure.py` (the scorer's bridge: it loads an implementation, calls
  it for a patient and passes back what it returned or raised, and decides nothing),
  `spec-first.rkt`
  (`run`, `score`, `report`, `misses`, `reference`). Five independent implementers for each
  measure and description write a Python `evaluate` from the narrative (N) or from the CQL (S,
  read, not run); the two prompts differ in the sentences naming the description alone. Right on
  the 151 held-out cases: N 93.0%, S 98.4% (+5.4 points, interval +2.1 to +9.3, none of 20,000
  label shuffles as large); implementers giving the same answers: 88.1% and 96.0% of cases
  (+7.9, +2.6 to +13.2); implementations right on every case: 0 and 10 of 20; the CQL executed
  by cql's engine (X): 150 of 151. The protocol's bar (5 points, interval above zero) is met,
  narrowly. The narrative fails two ways: implementers differ (breast's exclusions: 74%
  agreement), and implementers agree on a reading the measure does not mean (four cases all
  five got wrong the same way: which encounter statuses are "a visit"; a diagnosis "during" a
  window that the CQL says STARTS in it). S's own misses are translation slips (do-not-perform
  through a function two libraries away), which executing the specification does not make.
  S reads 250k input tokens against N's 139k. Four measures, one model: to be repeated on
  other systems.
  **Scoring is Racket** (the owner, 2026-11-22: "Code for scoring things should still be written
  in racket"). `spec-first.rkt score` holds everything that decides a result (`call-measure`,
  `answer-of`, `yes?`, `case-seconds`: the cases and expected results from the published test
  cases, the answer's shape, Python's truth of a JSON value, 20 s a patient with the
  implementation started again after one it does not finish); the Python bridge only calls the
  candidate's function. Scored again this way the 1,900 case results, the report and the misses
  are what they were. `analysis.rkt fab L=… G=… [OTHER=…]` prints every figure of RESULTS.md's
  M (the questions by arm, a session's tokens, calls and seconds, each kind of call, a third
  arm on the same questions); a number in a write-up comes from committed Racket, not from a
  scratch script (two 90th percentiles and one rounding of M's table were corrected by that).
  **D: the definition as the implementation** (2026-11-22; the protocol's third amendment, which
  also states the programme: one claimed advantage to an experiment — D, then B and C, then E
  (an error said at its cause) and S2 (S on another kind of system) — each stated before its
  run). The owner: "Operation definition make the implementation." `value-experiment/
  definition-first/`: `tasks.rkt` (tasks/<slot>/v1…v4: an operation's OperationDefinition,
  statement, change and cases, written by an agent that has not seen the toolkit —
  `definition-first.rkt author` — and every request decided again by a second agent given the
  requests alone — `check`: what it decides otherwise is dropped; the contract; each arm's
  prompt and directory; `fault-kind`: what a request asks, read from the definition), `try.py`
  (the implementers' own check), `definition-first.rkt` (`run`: a lineage is four sessions, the
  build and then each change in a new session over what the one before left; `score`: each
  stage's server started and sent its version's requests, in Racket — `call-with-server`,
  `post`, `wrong`; `report`, `misses`). `../implementers.rkt` is the analysis S and D share
  (two-level bootstrap, cases drawn within strata, permutation, cost ratios; S's report
  unchanged to the byte). Three operations (eGFR, corrected QT, anion gap), 752 requests, 30
  lineages, 120 sessions: by hand in Python 100.0% in all 15 lineages; declared in the capability
  language 94.0% (−6.0 points, −8.1 to −4.1) at 2.46 times the input tokens. The prediction
  (level when built, apart after changes) was wrong both ways. Every miss is one kind of
  request, a value POSTed under the key of another type than declared, which the capability
  runtime converted as it converts a GET query's text; on the other 506 requests both arms are
  right every time. Most of the extra cost is one session (a decimal input became a Quantity:
  548k tokens against 46k), because the guide did not say how a handler reads a Quantity and
  implementers parsed its printed form. Both gaps were fixed in fhir-server after the run (a
  POSTed value held to its key's type; `field`/`fields`; a tested guide example) and the same
  120 servers scored again: every declared server 100%, level — reported apart, as after the
  fact. No advantage found for the declared route for an agent; two defects found in it. From
  the trial: the audit's list must not name the agents' own directory (`/tmp/agent-bench/`),
  and an implementer told only "use this directory" searched the toolkit's source (the prompt
  now says to read nothing outside it; 0 flags in the 120 sealed sessions).
  **V: verifying against the source of truth** (2026-11-22; the protocol's amendments "after D: V",
  "V is every kind of artifact", "V-profile in full"). The owner: "without a single source of
  truth it's impossible to verify correctness", and then "beyond measure implementations. Also
  FHIR spec implementation, mappings, valueset definitions". An implementation written outside
  the toolkit is checked and corrected by agents that can read (R), have a third party's
  expected answers for a sample (T), or can run the published artifact on any input (O); truth
  is the third party's on inputs no session sees; the oracle's own agreement with it is
  reported as its ceiling. `value-experiment/verify/`.
  *V-measure* (`oracle.rkt`: the CQL executed by cql's engine; `verify.rkt`: `run`, `score`,
  `report`, `changes`, `broken`, `keep` — a scored run kept as one JSON file that the reports
  read): S's forty implementations, 120 sessions. No difference shown on the bar (O − R −0.7
  points, −4.4 to +2.8, on the twenty written from the narrative). R and T changed almost
  nothing (5 and 6 of 65 wrong answers fixed); O fixed 31 (48%), took implementations right on
  every held-out case from 10 to 17 of 40, and broke 25 right answers at seven times the
  tokens: 12 by copying the oracle's own disagreement with the authors on two diabetes patients
  (data exported without the value the case describes; one of them a sample patient), 8 in one
  session cut off at the 60-turn limit. An oracle is what makes checking find anything, and
  whatever it gets wrong is written into every implementation checked against it.
  *V-profile*: six US Core 9.0.0 profiles by rule
  (`profile-cases.rkt`: `profiles`, `cases` — the 28 published examples and 713 copies with one
  change of five kinds —, `truth`: HL7's Java validator's verdicts, committed under
  `verify/truth/`, `label` to make them again with a validator_cli jar; `agreement`, `ceiling`),
  `profile-materials.rkt` (what a session is given, by a rule: `spec-files`), `profile-oracle.rkt`
  (valid or invalid, nothing more), `profile-verify.rkt` (`build`, `run`, `score`, `report`,
  `changes`; a Python `valid(resource)` called through `call-valid.py`, scored in Racket).
  Measuring the oracle first was itself a result: this toolkit's validator agreed with HL7's on
  659 of the 741 cases, refusing nothing HL7's passes; the misses on the 158 sample cases were
  read and fixed as classes in fhir-validation, and it agrees on 736 (578 of the 583 held out)
  — the module's test holds those as floors. Disk: a session directory is ~2.7 MB (spec/);
  HL7's validator keeps 1.2 GB under ~/.fhir.
  The run (thirty implementations built, each checked in the three arms; 120 sessions; `built`,
  `broken`, `keep` as for measures): no difference shown on the bar (O − R +0.4 points, −0.3 to
  +1.2). R, T and O fixed 33, 27 and 48 of 109 wrong verdicts; O broke 5 right ones, four by
  copying the oracle's own disagreement with HL7's validator. The by-product is the finding:
  **an agent's validator written from the published definitions in one two-minute session was
  right on 96.3% of the held-out cases, where this toolkit's validator, as it was before any of
  HL7's verdicts was seen, was right on 89.5%** (21 of the 30 implementations ahead of it;
  `results/2026-11-22-profile-toolkit-before.json`, made by `profile-cases.rkt verdicts`); held
  to those verdicts on the sample cases it is at 99.1%, ahead of 29 of 30. What V shows, both
  parts: an executable source of truth makes checking find errors (44% and 48% of wrong answers
  fixed, against 8% to 30%), its checkers trust it completely, so it is worth what its own
  agreement with a third party's truth is — and setting the toolkit beside a third party's
  verdicts on inputs changed in one small way is what found its errors (61 of 583 verdicts,
  now 5). A trial's lesson: a session may write beside its directory (`../t.py`); run-agent's
  `settle!` keeps such files under `_outside/` instead of failing. And one of process: run
  `raco test -p fhir-examples` (the fetched guides' gate) BEFORE committing a validator change,
  and `raco setup --pkgs …` the dependents after one (a stale compiled dependent fails with
  `instantiate-linklet: mismatch`).
  **H: each engine held to its reference implementation** (2026-11-23; the protocol's entries "H
  begins" and "H part 1 after its first read"). No agents and no bar: the method that found the
  validator's misses, applied to an engine at a time. `value-experiment/reference/`:
  `fhirpath-cases.rkt` (the Pairs — `fp-pair`: search parameters and invariants of R4 core and US
  Core over US Core's examples, each search expression continued by one of `continuations`,
  V-profile's well-formed changed copies, HL7's R4 suite; `sample-expression?`: a fifth of the
  published expressions by SHA-1, the rest held out), `FhirPathReference.java` (the bridge to the
  validator jar's own engine: it calls and prints), `fhirpath-reference.rkt` (`pairs`, `ask`,
  `keep`, `ours`, `report`, `read` — the sample only —, `classes`, `suite`; each engine's answer
  in one compared form; `classes`: rules over the expression, the two answers and the
  reference's message, each under `ours`, `reference` or `open`; its test runs the live engine
  over all 172,527 pairs against `answers/fhirpath-reference.jsonl.gz` with the write-up's
  agreement as floors, in twelve seconds). Part 1, FHIRPath: held-out agreement 85.5% -> 89.1%
  (99.1% with the reference's departures from the specification set aside); three defects of
  this engine fixed (toString() of a complex value raised; children() in a hash walk's order;
  type().name of a nested element), seven of HL7's engine named with the specification's
  sentence. A struct named `pair` hides Racket's `pair?` in every module that imports it: the
  class rules matched nothing for one run. The jar's packages are not HAPI's published ones
  (`org.hl7.fhir.services.fhirpath.FHIRPathEngine`, `…elementmodel.Element.getChildList`):
  find a class with `javap -cp validator_cli.jar`, and set `JAVA_TOOL_OPTIONS=` to quiet the
  JVM. **Second pass** (the protocol's entry of that name, stated first): part 1's 678 unread
  held-out pairs opened (`read-opened`) — one more defect of this engine (hasValue() of several
  items), three more departures of the reference (conversions of a value read from the
  resource answer nothing; a path rooted at another type is no error), three things left open —
  and a FRESH set under the same rules (`fresh-pairs DIR ips|mcode`: `current-guide`,
  `current-fresh?`), 142,488 pairs nobody read: the same answer on 89.7%, 99.5% with the
  reference's departures aside, 66 (0.05%) under no class, none under a class that is this
  engine's (`classes … fresh`). The test holds the live engine to all three kept sets (40 s).
  **Part 2, the mapping language** (the protocol's "H part 2"): `map-cases.rkt` (`map-pair`: the
  tutorial's 25 maps over its 18 sources; `source-changes`, `map-changes` — a rule removed, a
  list mode, a `where`, a transform, each a text change to one rule line; a changed map gets its
  own url; `sample-map?`: a third of the maps), `MapReference.java` (one validator engine per
  step: its logical models loaded, each map parsed by the engine's own parser and cached, then
  `transform`), `map-reference.rkt` (the same commands as part 1's; an Answer is `error` or the
  result as canonical JSON; the report says how many agreements are both engines raising). 887
  pairs: held-out agreement 88.0% -> 89.8%, the sample 92.5% -> 96.4%; three defects of fml
  fixed (a text that is no number written into a number's element; an implicit copy where the
  target names a variable; `check` after the list mode), one of the reference's (a FHIRPath
  variable with an underscore). 52 held-out pairs differed under no class: eight sample maps
  did not cover seventeen. **Its second pass** opened them (two more fixes in fml: `append` and
  `truncate` of a complex value; the check warns of a FHIRPath function that does not exist;
  one gap named, not fixed: a `types` group for a primitive type is never run) and ran a fresh
  set (`fresh-pairs DIR`, `current-fresh-maps?`: matchbox's seventeen top-level maps over FHIR
  resources, 667 pairs, none read): the same result on 74.1%, 168 of 173 differences under no
  class — the mapping engine is not covered yet, and that set is the next to open (with the
  reference run as R4). `keep-ours!` in both modules refuses to write answers when the engine
  raised on every pair (a stale compiled engine does, and `error` is an answer). Next, each with
  its own entry first: the fresh mapping set opened, SQL on FHIR, FSH.
- `model.rkt` is the shared model runner (`ask`, `extract-block`); `run-task!` and notes-to-fhir use it.
- `run-task!` talks to the model through files (`round-N.prompt.md` on stdin, `round-N.answer.txt`),
  kills the process group past `--timeout`, and feeds `check`'s diagnostics into the next round.
  (A `system` call with string ports once hung for 90 minutes after the model exited; do not go back.)
