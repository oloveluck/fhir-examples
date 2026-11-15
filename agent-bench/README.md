# Agent benchmarks

Two third-party benchmarks of LLM agents over FHIR data, run with headless Claude Code agents
(`claude -p`), each in an empty directory of its own: no repository notes, only the benchmark's
prompt and the arm's tools. Every run records the answer, tokens, cost, time and every shell
command (`run-agent.rkt`), and is graded by the benchmark's own grader.

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
- **workspace** — the fhir-mcp workspace verbs (`raco fhir-mcp call …`) over the same store, with
  `raco fhir guide workspace`.
- **official-hapi**, **official-ours** (MedAgentBench) — the benchmark's own protocol: the model
  answers each turn with one `GET`, `POST` or `FINISH` line, at most 8 rounds, no tools of its own.
  Against HAPI and against our server, it shows whether the server is a drop-in replacement.

In MedAgentBench a POST is recorded, not sent (`mab post`), as the benchmark's harness does.

## Running
```sh
B=racket\ -l-\ fhir-examples/agent-bench
# data: MedAgentBench's server exported (searched patient by patient, in parallel) and loaded
$B/mab/export-server --parallel 8 http://localhost:8080/fhir/ mab/ndjson
raco fhir-server load mab/fhir.db mab/ndjson --fhir-version 4.0.1
racket serve-store.rkt mab/fhir.db 8766 Patient Observation Condition MedicationRequest Procedure ServiceRequest

# MedAgentBench (MAB_TASKS, MAB_FUNCS: the benchmark's data files; MAB_REFSOL_DIR: refsol.py + utils.py)
$B/mab/run --model sonnet workspace runs/r1/mab-workspace          # also rest-hapi rest-ours official-hapi official-ours
$B/mab/grade runs/r1/mab-workspace                                 # graded against HAPI

# FHIR-AgentBench: the fixed sample (fab/valid-150.json: 150 valid questions over 62 templates)
racket serve-store.rkt mimic/fhir.db 8765 Patient Encounter Observation …
FAB_STORE=mimic/fhir.db $B/fab/run --model sonnet workspace fab/valid-150.json runs/r1/fab-workspace
FAB_REPO=… bash fab/score.sh runs/r1/fab-workspace sonnet           # their evaluation_metrics.py

$B/report runs/r1                                                  # both benchmarks, one table
```
Iterate on the valid split; the test split is for reporting (`fab/make-sample.rkt` draws others).
