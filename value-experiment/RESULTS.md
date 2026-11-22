# Results

## M. The toolkit's tools against the harness alone (2026-11-22)

The comparison of the protocol's amendment, run as stated there: one pass of each arm over the
150 questions of `agent-bench/fab/test-heldout-150.json`, which neither arm (nor the workspace
and MCP arms whose tools the toolkit's arm uses) had been run on; the same harness (the tools of
one process, no shell, the same system prompt, the same `python` and `answer` tools); the data
alone; the benchmark's own grader.

```
$ racket value-experiment/analysis.rkt fab toolkit=<m-mcp-tools> harness=<m-rest-tools>
toolkit against harness, 150 tasks both ran
  right           toolkit 83.3%, harness 84.0%
  difference      -0.7 points (95% interval -4.0 to +2.7); McNemar p = 1.0
  input tokens    toolkit's are 0.85 of harness's (95% interval 0.69 to 1.05)
  verdict         no difference shown, and a clear null (the intervals are inside the protocol's bounds)
```

| | the toolkit's tools (`mcp-tools`) | the harness alone (`rest-tools`) |
|---|---|---|
| right, as scored | 125 of 150 | 126 of 150 |
| input tokens a question, mean (median; 90th percentile) | 25.5k (15.8k; 45.4k) | 29.9k (17.7k; 65.1k) |
| output tokens | 553 | 736 |
| tool calls a question | 3.5 | 3.6 |
| seconds | 7.9 | 8.1 |
| citations: precision, recall | 0.92, 0.78 | 0.90, 0.79 |

**The answer to the question asked: no.** For answering questions of a patient's record, the
toolkit's reading tools through MCP (search with digested rows, `find`, the census, SQL over the
search indexes, the reading card) add no significant value over an agent that has a plain FHIR
REST server and Python in the same harness. They are equally right — the interval excludes a
difference of 5 points either way — and the toolkit's 15% fewer input tokens is not shown to be
a difference (the ratio's interval reaches 1.05) and is far from the two thirds the protocol
asks. By the protocol, a clear null ends M: no extension, and no tuning of the harness arm
(which was the untuned one).

What the agents did: with the toolkit, 254 searches, 62 describes, 30 SQL statements, 18 finds
and 3 FHIRPath queries; with the harness alone, 212 GETs and 174 Python programs. The two miss
mostly the same questions: 122 right under both, 3 under the toolkit only, 4 under the harness
only, 21 under neither.

**Where a difference does lie, and what it is not yet evidence of.** The `tables-tools` arm,
run earlier on these same 150 questions, has 148 right at 10k input tokens, and is right on 19
of the 21 that neither arm here answers. That arm differs from both in three things at once:
the benchmark's relational schema defined over the store as views (the toolkit's doing), an
example query of the question's kind from the benchmark's training split, and checks read from
that split. M does not say which of the three carries it; the protocol's A1 (a general-route
arm prepared from the same training material, and SQL on the original relational database as
the ceiling) is the comparison that would.

So, of what the toolkit claims for an agent, what is measured stands as follows.

| claim | measured |
|---|---|
| generic reading tools beat REST and Python | no: level (this result) |
| writing in a language costs fewer tokens than writing the JSON | yes: a profile at half the tokens for the same facets; a change as rules 26 tokens, as a JSON Patch 50, whole 535 (`results/2026-11-16-dsl-vs-json.md`) |
| writing in a language is more often right | no: level on profiles (1427 and 1431 of 1431) and on edits (60 of 60 every arm) |
| tables defined over the store make questions answerable | 148 of 150 here, but not separated from the training examples given with them |
| checked writes are safer | not measured (the protocol's B) |

Not covered by M: writing data, computing over a population, MedAgentBench, and the same tools
from a shell.

An earlier start of the run was discarded: the REST server had stopped before it began, and
the first sessions of the harness arm could reach no data. The run script checks the server
before and after each arm since.
