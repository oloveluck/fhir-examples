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

## S. Narrative first against spec first (2026-11-22)

The protocol's second amendment, run as stated there. Four clinical quality measures published
by their steward, each described two ways by that steward: the English narrative of its Measure
resource, and its CQL. Five independent implementers for each measure and description wrote a
Python function from it (40 sessions, one model, the same tools, prompt, terminology, sample
patients and contract). Each function was run over the measure's test cases that were not in
its sample (151 of the authors' 190) and held to the authors' expected results.

```
$ racket value-experiment/spec-first/spec-first.rkt report <run>
implementations: 20 from the narrative (N), 20 from the specification (S)
held-out cases: 151

measure    N right (each implementer)          N agree  S right (each implementer)          S agree
breast  93.5% 91.3% 87.0% 87.0% 84.8%  73.9%  97.8% 97.8% 100.0% 97.8% 97.8%  97.8%
cervical  91.3% 91.3% 91.3% 91.3% 91.3%  100.0%  100.0% 100.0% 100.0% 100.0% 100.0%  100.0%
pressure  91.7% 93.8% 97.9% 97.9% 97.9%  89.6%  100.0% 97.9% 100.0% 100.0% 100.0%  97.9%
diabetes  97.1% 94.1% 97.1% 97.1% 94.1%  97.1%  97.1% 97.1% 97.1% 97.1% 91.2%  88.2%

right        N 93.0%, S 98.4%: S − N = +5.4 points (95% interval +2.1 to +9.3; permutation p = 0.0)
agreement    N 88.1%, S 96.0%: S − N = +7.9 points (95% interval +2.6 to +13.2)
cost         an implementation: N 139.1k input and 9.2k output tokens, 8.3 turns, 55 s; S 250.1k and 13.9k, 12.6 turns, 84 s
verdict      the specification's implementers are right more often (the protocol's "significant value")
```

| the measure described as | right, held-out cases | implementers giving the same answers | implementations right on every case |
|---|---|---|---|
| its English narrative, implemented by hand (N) | 93.0% | 88.1% of cases | 0 of 20 |
| its CQL, implemented by hand (S) | 98.4% | 96.0% of cases | 10 of 20 |
| its CQL, executed (X: this toolkit's engine, no model) | 99.3% (150 of 151) | one answer by construction | — |

**The hypothesis holds on these four systems.** Implementers given the formal specification
are right more often than implementers given the English (5.4 points, the interval 2.1 to 9.3;
in 20,000 shuffles of the arm labels within measure none gave a difference as large) and agree
with each other more often (7.9 points, 2.6 to 13.2). It meets the protocol's bar, narrowly: 5
points with the interval above zero. No implementation from the narrative got every held-out
case right; half of those from the specification did.

**What the English left open** (`results/2026-11-22-misses.txt` lists every case by its
authors' name). Two kinds of failure, and the second does not show as disagreement:

- *Implementers read it differently.* Breast cancer screening's exclusions (frailty with
  advanced illness, hospice, a nursing home): the five narrative implementers agree on 74% of
  the cases. "Taking dementia medications during the measurement period or the year prior",
  "an indication of frailty", "living long term in a nursing home" each became different code.
- *Implementers read it the same way, and it is not what the measure means.* On four cases all
  five narrative implementers gave the same wrong answer. "A visit during the measurement
  period": the CQL says which encounter statuses are a visit (`finished`, `arrived`, `triaged`,
  `in-progress`, `onleave`); four of the five took a visit to be a finished one, the fifth a
  finished or in-progress one, and a woman whose encounter is `arrived` is out of every one's
  initial population. "Advanced illness diagnosis during
  the measurement period or the year prior": the CQL says the diagnosis *starts* in that
  window; all five counted a condition that began the day before it and was still active.
  Nothing in the narrative decides either, and agreement among readers does not reveal it.

**What the specification did not fix by being read.** The spec arm's own misses are
translation slips, not open questions: four of five missed that an order marked
do-not-perform is not an order (the CQL says so, through a function two libraries away in
130 KB of text). The specification executed does not make that mistake. The rest of the spec
arm's misses are mostly one oddity of the test data: two diabetes cases whose result is
exported as a concept where the case's own description gives a number. No single reading of
such a result gets both cases, each spec implementer got one of the two wrong, and so does
the executed CQL (its one miss in 151). So the order is narrative 93, specification
read 98, specification run 99: most of the gain is in what is written down, the rest in not
re-implementing it.

**What it costs.** A specification is longer than its narrative: an implementer from the CQL
read 250k input tokens against 139k and took 84 s against 55. That is the price of the
description once, to an implementer; a system that executes the specification pays neither.

**What this does not show.**

- Four measures of one kind, one model, five implementers each. The interval is about these.
- The bar is met at 5.4 against 5: a result to repeat on other systems before leaning on it.
- The measures are public. A model that has read the CQL may recall it under the narrative arm
  (which works against the difference found), or under both.
- It compares descriptions, not ways of working: nothing here says an agent given this
  toolkit's tools does a task better (M above says it does not, for reading). It says a system
  whose source of truth is a formal specification is built more consistently and more correctly
  than one whose source of truth is prose, and that the same specification run is better still.

