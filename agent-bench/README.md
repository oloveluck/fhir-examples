# Agent benchmarks

Two third-party benchmarks of LLM agents over FHIR data, run with headless Claude Code agents
(`claude -p`), each in an empty directory of its own: no repository notes, only the benchmark's
prompt and the arm's tools. Every run records the answer, tokens, cost, time and every shell
command (`run_agent.py`), and is graded by the benchmark's own grader.

| benchmark | what it asks | data | grader |
|---|---|---|---|
| [FHIR-AgentBench](https://github.com/glee4810/FHIR-AgentBench) (CC BY 4.0) | 2,931 questions from EHRSQL's templates over one patient each (values, dates, counts, names, "none") | MIMIC-IV Clinical Database Demo on FHIR 2.1.0 (PhysioNet), 929k resources | its `evaluation_metrics.py`, unmodified: an LLM judge for the answer, retrieval precision and recall for the resources |
| [MedAgentBench](https://github.com/stanfordmlgroup/MedAgentBench) (MIT; NEJM AI) | 300 clinical tasks in 10 kinds: look up, compute, record a vital sign, order a medication or a test | the benchmark's HAPI FHIR server image (695 patients, 785k resources) | its `refsol.py` (downloaded from the authors; not vendored) |

## Arms
What changes between arms is only how the agent reaches the data.

- **rest** — curl against a plain FHIR R4 REST server over the store (`serve-store.rkt`: read and
  search with the R4 core SearchParameters). For MedAgentBench also **rest-hapi**: curl against the
  benchmark's own HAPI server.
- **workspace** — the fhir-mcp workspace verbs (`raco fhir-mcp call …`) over the same store, with
  `raco fhir guide workspace`.
- **official** (MedAgentBench only) — the benchmark's own protocol (`run_official.py`): the model
  answers each turn with one `GET`, `POST` or `FINISH` line, at most 8 rounds, no tools of its own.
  Run against HAPI and against our server, it shows whether the server is a drop-in replacement.

In MedAgentBench a POST is recorded, not sent (`mab post`), as the benchmark's harness does.

## Running
```sh
# FHIR-AgentBench: a fixed sample of the valid split (iterate on valid; test is for reporting)
python3 fab/make_sample.py $FAB_REPO/final_dataset/questions_answers_sql_fhir.csv valid 150 20261115 > sample.json
racket serve-store.rkt mimic/fhir.db 8765 Patient Encounter Observation …     # the rest arm's server
FAB_STORE=mimic/fhir.db python3 fab/run_fab.py workspace sample.json runs/fab-ws --model sonnet
FAB_REPO=… bash fab/score.sh runs/fab-ws sonnet                                 # their scorer

# MedAgentBench
export MAB_TASKS=…/test_data_v2.json MAB_FUNCS=…/funcs_v1.json MAB_REFSOL_DIR=…/refsol MAB_STORE=mab/fhir.db
python3 mab/run_mab.py workspace runs/mab-ws --model sonnet
python3 mab/run_official.py http://localhost:8766/ runs/mab-official-ours
python3 mab/grade.py runs/mab-ws http://localhost:8080/fhir/                    # graded against HAPI
```
