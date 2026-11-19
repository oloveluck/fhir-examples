# Agent benchmarks

Two third-party benchmarks of LLM agents over FHIR data, run with headless Claude Code agents
(`claude -p`), each in an empty directory of its own (a short one, `/tmp/agent-bench/<n>/<id>` or
`$AGENT_BENCH_WORK`, moved into the run afterwards): no repository notes, only the benchmark's
prompt and the arm's tools. Every run records the answer, tokens, cost, time and every shell
command (`run-agent.rkt`), and is graded by the benchmark's own grader. Arms are compared by the
input tokens an item costs and its turns (`report.rkt`); cost is shown last, since prompt caching
makes the same tokens cost twice as much in one run as in the next.

| benchmark | what it asks | data | grader |
|---|---|---|---|
| [FHIR-AgentBench](https://github.com/glee4810/FHIR-AgentBench) (CC BY 4.0) | 2,931 questions from EHRSQL's templates over one patient each (values, dates, counts, names, "none") | MIMIC-IV Clinical Database Demo on FHIR 2.1.0 (PhysioNet), 929k resources | its `evaluation_metrics.py`, unmodified: an LLM judge for the answer, retrieval precision and recall for the resources |
| [MedAgentBench](https://github.com/stanfordmlgroup/MedAgentBench) (MIT; NEJM AI) | 300 clinical tasks in 10 kinds: look up, compute, record a vital sign, order a medication or a test | the benchmark's HAPI FHIR server image (695 patients, 785k resources) | its `refsol.py` (downloaded from the authors; not vendored) |

The harness is Racket. The only Python is the benchmarks' own graders and what reaches them:
`mab/refsol_bridge.py` (hands the runs to `refsol.py`) and `fab/shim/` (lets `evaluation_metrics.py`
call Claude in place of litellm and skip a tokenizer download).

## Arms
What changes between arms is only how the agent reaches the data.

- **rest** — curl against a plain FHIR R4 REST server over the store (`serve-store.rkt`: read and
  search with the R4 core SearchParameters). For MedAgentBench also **rest-hapi**: curl against the
  benchmark's own HAPI server.
- **workspace** — the fhir-mcp workspace verbs (`raco fhir-mcp call …`) over the same store. Its
  prompt carries the product's one-page reading card (`raco fhir guide data`) where the rest arms'
  carry their curl lines.
- **mcp** — the same verbs as MCP tools: `raco fhir-mcp` is the agent's MCP server.
- **tables** (FHIR-AgentBench) — the benchmark's own relational schema, defined over the FHIR
  store by an agent beforehand, and questions answered in SQL over it (below).
- **official-hapi**, **official-ours** (MedAgentBench) — the benchmark's own protocol: the model
  answers each turn with one `GET`, `POST` or `FINISH` line, at most 8 rounds, no tools of its own.
  Against HAPI and against our server, it shows whether the server is a drop-in replacement.

In MedAgentBench a POST is recorded, not sent (`mab post`), as the benchmark's harness does. The
workspace arms may write the payload as one FSH Instance (`./mab post <url> p.fsh`: compiled by
`raco fsh` for R4, its problems said at their lines, recorded as the JSON). Since round 7 the
agent arms' prompt states two shapes the benchmark's grader reads and FHIR does not write: a
medication order's `route` as a plain string (the benchmark's own function list describes an
object, as FHIR does; three tasks were missed by every arm for it) and a ServiceRequest's `note`
as one object.

Every agent arm has the same built-in tools (Bash, Read, Write — `--tools`; Claude Code's default
set is most of each turn's context) and is told to end with one line once it has answered (harness
2, in each run's `run.json`; the baseline of 2026-11-15 ran with the default tools).

## Running
```sh
B=racket\ -l-\ fhir-examples/agent-bench
# data: MedAgentBench's server exported (searched patient by patient, 8 at once: 785,902 resources in 72 s from
# its HAPI server, where paging each type whole took ~14 min) and loaded (1 min 52 s)
$B/mab/export-server --parallel 8 http://localhost:8080/fhir/ mab/ndjson
raco fhir-server load mab/fhir.db mab/ndjson --fhir-version 4.0.1
racket serve-store.rkt mab/fhir.db 8766 Patient Observation Condition MedicationRequest Procedure ServiceRequest

# MedAgentBench (MAB_TASKS, MAB_FUNCS: the benchmark's data files; MAB_REFSOL_DIR: refsol.py + utils.py)
$B/mab/run --model sonnet workspace runs/r1/mab-workspace          # also mcp rest-hapi rest-ours official-hapi official-ours
$B/mab/grade runs/r1/mab-workspace                                 # graded against HAPI

# FHIR-AgentBench: the fixed sample (fab/valid-150.json: 150 valid questions over 62 templates)
racket serve-store.rkt mimic/fhir.db 8765 Patient Encounter Observation …
FAB_STORE=mimic/fhir.db $B/fab/run --model sonnet workspace fab/valid-150.json runs/r1/fab-workspace
FAB_REPO=… bash fab/score.sh runs/r1/fab-workspace sonnet           # their evaluation_metrics.py

$B/report runs/r1                                                  # both benchmarks, one table
```
## A relational schema, defined by an agent (the `tables` arm)
FHIR-AgentBench's answers are SQL over MIMIC-IV's tables (`fab/schema.md`: 15 tables, about 45
columns); its agents are given the same data as FHIR. When someone computes against a relational
schema, the schema's tables are defined over the store once, by an agent, and everything after is
SQL:

1. **`fab/setup-tables`** — one agent, given the schema, the workspace over the store and the
   guides (`raco fhir guide tables`), writes ViewDefinitions (`*.view.json`, one resource type
   each) and tables over them (`*.sql`) until the benchmark's own train-split queries, asked of the
   workspace unchanged, give the benchmark's answers. It checks itself with `./check`
   (`fab/check-tables`, no model in it). `--amend FROM "<change>"` starts a second agent from the
   first one's workspace with one stated change.
2. **`fab/make-examples`** — from the train split alone: the kinds of question (its 45 templates),
   a worked example or two of each (question, assumption, query), and how each kind of time phrase
   is written as a condition (the benchmark states that per question, in `val_dict`).
3. **`fab/run … tables`** — a question agent gets the schema and the kinds in its prompt, reads
   the example of its question's kind (`./kind N`: the example, then how each time phrase is
   written), fills in its query and gives it to one command, `./answer --kind N "SELECT …"`
   (`fab/answer.rkt`): it runs the query, states the answer as the benchmark's people state one,
   finds the resources behind the rows (their `fhir_id` columns) and writes the answer file.
   Its workspace is a copy of the setup agent's files with a link to the rows already computed.
   The agent has the shell tool alone, and its session ends when `./answer` writes the answer
   with nothing to look at again (`fab/stop-when-answered.sh`, a hook of the agent runtime): two
   calls of the model a question where there were three.
   **`fab/run … tables-tools`** is the same arm with the three commands as the three tools of one
   process (`fab/tables-server.rkt`, a Model Context Protocol server over the question's
   workspace: `kind`, `sql`, `answer`) and no shell: every call of the model carried the shell
   tool's definition and the runtime's own system prompt (3.3k tokens), and every command started
   a process that loaded the toolkit. 22k input tokens and 6.5 s a question where `tables` takes
   29k and 7.7 s, the same answers.
4. **`fab/query-checks`** — from the train split alone: what a question's query should hold (the
   condition each time phrase and averaging unit is written as, the names a question gives, a
   comparison where a question asks whether, a time exactly where it asks when). `./answer`
   prints a note where the query does not; under the decisive ones — those, and a first or last
   row picked from several that differ — it writes no answer until the query is corrected or
   given again, and shows the kind the note names. None is said of any train or validation
   query of the benchmark.
5. **Held to more than the queries**: `fab/check-rows` compares each table with the relational
   database row for row, `fab/check-ids` a query's rows with the resources the benchmark cites;
   an amending setup agent works with either as its gate.
6. **`fab/gate`** — scored runs taken together: the score as scored, the questions of
   `fab/set-aside.json` apart (those whose recorded answer contradicts the question; the
   evidence is in `results/2026-11-17-note-to-benchmark-authors.md`), the rest as right every
   time, missed sometimes or missed every time, and what a question costs. An answer marked
   right in one run and wrong in another, word for word, is the judge's disagreement with
   itself and is listed apart. It passes when no question in scope is missed every time (and
   at most `--slips N` sometimes). The whole test split three times and the validation sample:
   PASS, at 45k input tokens and 10 s a question; the questions nobody had read (the other 274
   of the validation split) 267 of 270, and what followed from them and from the loop on tokens
   and time is `results/2026-11-17-held-out-and-efficiency.md`.

```sh
FAB_STORE=mimic/fhir.db FAB_REPO=… $B/fab/setup-tables runs/tables                 # ~1 h; writes runs/tables/workspace
FAB_REPO=… $B/fab/check-tables runs/tables/workspace                               # the train queries, each answer compared
$B/fab/make-examples $FAB_REPO/final_dataset/questions_answers_sql_fhir.csv runs/examples
$B/fab/query-checks $FAB_REPO/final_dataset/questions_answers_sql_fhir.csv runs/examples   # checks.json, beside the examples
FAB_TABLES=runs/tables/workspace FAB_EXAMPLES=runs/examples FAB_STORE=mimic/fhir.db \
  $B/fab/run --model sonnet tables fab/test-150.json runs/r7/fab-tables
$B/fab/check-rows mimic_iv.sqlite runs/tables/workspace                            # each table against the relational rows
FAB_REPO=… $B/fab/check-ids runs/tables/workspace                                  # the resources the benchmark cites
$B/fab/gate runs/r7/fab-tables-a runs/r7/fab-tables-b runs/r7/fab-tables-c         # passing? and what a question costs
```
The tables one setup run wrote are in `results/2026-11-16-tables/` (13 views, 15 `.sql` files,
11 KB in all), and as two amending agents left them — held to the relational rows and to the
benchmark's citations — in `results/2026-11-17-tables/`. `fab/test-heldout-150.json` is the next 150 test-split questions in the same seeded
order as `fab/test-150.json`, and `fab/test-fresh-109.json` the last 109: each was run before
anyone read its misses, and the three together are the whole test split.

Iterate on the valid split; the test split is for reporting: `fab/test-150.json` (150 questions over
59 templates, seed 20261115) was drawn before any run on it (`fab/make-sample.rkt` draws others).
