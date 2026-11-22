# Results

## M. The toolkit's tools against the harness alone (2026-11-22)

The comparison of the protocol's amendment, run as stated there: one pass of each arm over the
150 questions of `agent-bench/fab/test-heldout-150.json`, which neither arm (nor the workspace
and MCP arms whose tools the toolkit's arm uses) had been run on; the same harness (the tools of
one process, no shell, the same system prompt, the same `python` and `answer` tools); the data
alone; the benchmark's own grader.

```
$ racket value-experiment/analysis.rkt fab toolkit=<m-mcp-tools> harness=<m-rest-tools> tables=<fab-tables19-held-a>
toolkit against harness, 150 tasks both ran
  right           toolkit 83.3%, harness 84.0%
  difference      -0.7 points (95% interval -4.0 to +2.7); McNemar p = 1.0
  input tokens    toolkit's are 0.85 of harness's (95% interval 0.69 to 1.05)
  verdict         no difference shown, and a clear null (the intervals are inside the protocol's bounds)
  by task         right under both 122, under toolkit only 3, under harness only 4, under neither 21
  a toolkit session: input tokens 25.5k (median 15.8k, 90th percentile 45.2k), output tokens 553, 3.4 tool calls, 7.9 s
    its calls: 254 query search, 150 answer, 62 describe, 30 query sql, 18 query find, 3 query fhirpath
  a harness session: input tokens 29.9k (median 17.7k, 90th percentile 62.1k), output tokens 736, 3.6 tool calls, 8.1 s
    its calls: 212 get, 174 python, 150 answer
tables on the same tasks (150 of them run): right on 148, 10.0k input tokens a task; of the 21 neither arm is right on, right on 19
```

| | the toolkit's tools (`mcp-tools`) | the harness alone (`rest-tools`) |
|---|---|---|
| right, as scored | 125 of 150 | 126 of 150 |
| input tokens a question, mean (median; 90th percentile) | 25.5k (15.8k; 45.2k) | 29.9k (17.7k; 62.1k) |
| output tokens | 553 | 736 |
| tool calls a question | 3.4 | 3.6 |
| seconds | 7.9 | 8.1 |
| citations: precision, recall | 0.92, 0.78 | 0.90, 0.79 |

Every figure here is printed by committed Racket: the comparison, the questions by arm, the
sessions' costs and calls and the third arm by `analysis.rkt` (above), the citations by
`agent-bench/report.rkt` from the benchmark's own grader. (The 90th percentiles and the
toolkit's calls a question were first written from a scratch script as 45.4k, 65.1k and 3.5; they
are `analysis.rkt`'s now, whose percentile is stated in its `quantile`.)

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

The scoring is Racket (`spec-first.rkt score`): it reads each case and its expected result from
the measure's published test cases, decides what an answer must look like, what counts as yes,
how long a patient may take, and whether the answer is the expected one. An implementation is a
Python function, so one thing is Python: `call-measure.py`, 40 lines that load the function,
call it for the patient given and pass back what it returned or raised. (The run was first
scored through the implementers' `try.py`; scored again this way, all 1,900 case results of
the 40 implementations are the same, and so are the report and the list of misses.)

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
every case   implementations right on every held-out case: N 0 of 20, S 10 of 20
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

## D. The definition as the implementation (2026-11-22)

The protocol's third amendment, run as stated there. Three clinical calculator operations — an
eGFR equation, a corrected QT interval, an anion gap — each written by an agent that has not
seen this toolkit, in four versions (as first published, then a new required input, an input
constrained, an output changed), with 752 test requests; a second agent, given the requests
alone, decided every one again and left four undecided, which were dropped. Five implementers
for each operation and arm built a server and, in three later sessions, brought it up to each
change: 30 lineages, 120 sessions, one model. Each of the 120 servers was started and sent the
requests of its version that its implementer had not been shown (549 over the three operations:
146, 254 and 149 a lineage).

```
$ racket value-experiment/definition-first/definition-first.rkt report <run>
lineages: 15 declared in the capability language (L), 15 by hand in Python (G); four sessions each
requests scored: 549 (v1 111, v2 137, v3 157, v4 144)

operation version  L right (each lineage)              G right (each lineage)
a v1  90.6% 90.6% 90.6% 90.6% 90.6%    100.0% 100.0% 100.0% 100.0% 100.0%
a v2  89.5% 89.5% 89.5% 89.5% 89.5%    100.0% 100.0% 100.0% 100.0% 100.0%
a v3  92.1% 92.1% 92.1% 92.1% 92.1%    100.0% 100.0% 100.0% 100.0% 100.0%
a v4  92.1% 92.1% 92.1% 92.1% 92.1%    100.0% 100.0% 100.0% 100.0% 100.0%
b v1  91.5% 91.5% 91.5% 91.5% 91.5%    100.0% 100.0% 100.0% 100.0% 100.0%
b v2  96.7% 96.7% 96.7% 96.7% 96.7%    100.0% 100.0% 100.0% 100.0% 100.0%
b v3  93.8% 93.8% 93.8% 93.8% 93.8%    100.0% 100.0% 100.0% 100.0% 100.0%
b v4  94.0% 94.0% 94.0% 94.0% 94.0%    100.0% 100.0% 100.0% 100.0% 100.0%
c v1  93.8% 93.8% 93.8% 93.8% 93.8%    100.0% 100.0% 100.0% 100.0% 100.0%
c v2  100.0% 97.4% 97.4% 97.4% 97.4%    100.0% 100.0% 100.0% 100.0% 100.0%
c v3  100.0% 94.9% 94.9% 94.9% 94.9%    100.0% 100.0% 100.0% 100.0% 100.0%
c v4  100.0% 97.4% 97.4% 97.4% 97.4%    100.0% 100.0% 100.0% 100.0% 100.0%

right, every version    L 94.0%, G 100.0%: L − G = -6.0 points (95% interval -8.1 to -4.1; permutation p = 0.0)
right, after a change   L 94.5%, G 100.0%: L − G = -5.5 points (95% interval -7.8 to -3.4; permutation p = 0.0)
right, as first built   L 91.9%, G 100.0%: L − G = -8.1 points (95% interval -13.5 to -3.6; permutation p = 0.0)
  requests that conform                  L 100.0%, G 100.0% (320 requests)
  a required input missing               L 100.0%, G 100.0% (32 requests)
  an input more times than its maximum   L 100.0%, G 100.0% (37 requests)
  a value under a key of another type    L 22.8%, G 100.0% (43 requests)
  a code outside its binding, or a rule  L 100.0%, G 100.0% (117 requests)
  requests about the change              L 99.5%, G 100.0% (184 requests)
after the fact: without the values under another type's key
                        L 100.0%, G 100.0%: L − G = +0 points (95% interval +0.0 to +0.0; permutation p = 1.0)

input tokens, a lineage      L 512.6k, G 208.7k: L/G = 2.46 (95% interval 2.24 to 2.66)
input tokens, the changes    L 405.7k, G 141.4k: L/G = 2.87 (95% interval 2.51 to 3.2)
input tokens, the build      L 106.9k, G 67.3k: L/G = 1.59 (95% interval 1.41 to 1.81)
a lineage, L and G: output tokens 8.4k and 5.9k; seconds 100 and 49 (the changes 74 and 25); model turns 35.13 and 20.2
  the session of v1, L and G: input tokens 106.9k and 67.3k; model turns 7.53 and 7.33; seconds 26 and 25
  the session of v2, L and G: input tokens 103.3k and 43.5k; model turns 7.53 and 3.93; seconds 21 and 8
  the session of v3, L and G: input tokens 233.6k and 52.2k; model turns 14.33 and 4.87; seconds 38 and 9
  the session of v4, L and G: input tokens 68.7k and 45.6k; model turns 5.73 and 4.07; seconds 14 and 8
  input tokens a session, a, L and G: v1 92.2k and 65.8k; v2 112.3k and 41.1k; v3 98.4k and 46.8k; v4 69.7k and 46.3k
  input tokens a session, b, L and G: v1 110.1k and 67.3k; v2 66.9k and 42.8k; v3 54.4k and 63.4k; v4 64.2k and 45.0k
  input tokens a session, c, L and G: v1 118.4k and 68.7k; v2 130.8k and 46.7k; v3 548.1k and 46.5k; v4 72.3k and 45.5k
the implementation, L and G: 48 and 106 lines at the end; 23 and 18 lines touched by the three changes
servers that did not start: L 0 of 60 stages, G 0 of 60
lineages right on every request: L 0 of 15, G 15 of 15

verdict, every version   the declared servers are right less often
verdict, after a change  the declared servers are right less often
```

| | declared in the capability language (L) | by hand in Python (G) |
|---|---|---|
| requests answered as the definition and the statement say | 94.0% | 100.0% |
| … after a change to the definition | 94.5% | 100.0% |
| lineages right on every request | 0 of 15 | 15 of 15 |
| input tokens, a lineage (the build; the three changes) | 513k (107k; 406k) | 209k (67k; 141k) |
| seconds of sessions, a lineage | 100 | 49 |
| the server, lines | 48 | 106 |

**The hypothesis does not hold, and the result goes the other way.** The servers built by hand
answered every request of every version as the definition says, in all fifteen lineages. The
declared servers were right less often (6.0 points, the interval 4.1 to 8.1) and cost two and a
half times the input tokens. The prediction — level when first built, apart after the
definition changes — was wrong on both counts: the arms were apart from the first build, the
other way, and no change made a hand-built server fall behind its definition.

**Where the declared servers failed: one kind of request, and it is the toolkit's doing.**
Every miss is a value sent under the key of another type than the definition declares
(`valueString` where a decimal, an integer, a code or a date is declared): 43 of the 549
requests, of which the declared servers refused 23%. The capability runtime reads a POSTed
Parameters the way it reads a GET query, where every value is text, and converts it — so
`"valueString": "1.2"` for a decimal input is taken as 1.2 and answered 200. The implementer
has no say in it: the check runs before the handler, and the handler is given the converted
value. On everything else the declaration is meant to give — a required input missing, an
input given too often, a code outside its binding, a rule of the statement, the outputs after
each change — the declared servers were right on every one of the other 506 requests, in every
lineage. So were the hand-built ones.

**Why the declared route cost more.** Not the build (107k tokens against 67k: the guide is
read once) but the changes: 406k against 141k, and most of that is one session of one
operation. The anion gap's third version changed an input from a decimal to a Quantity; that
session took 548k tokens declared and 46k by hand. The guide says how to *answer* a Quantity
and nowhere how a handler *reads* one: four of the five implementers of that operation printed
the value and took it apart with regular expressions. One of them had also noticed the
wrong-type requests among its examples and got them right from the second version on, by
printing the whole request and parsing that. The other change sessions cost the declared arm
from a little less to nearly three times the hand-built one's (54k to 131k against 41k to
63k): the guide is read again by each new session.
No session read outside its directory (the audit found nothing in 120 sessions).

**What the declaration did buy.** Half the code (48 lines against 106), and the server
publishes the definition it implements. Neither is something the suite scores, and neither
made the server more often right.

**What this says about the claim.** "The definition makes the implementation" is true of
this toolkit in the narrow sense that the declared checks ran and were right. It is not an
advantage an agent needs: a model writes those checks by hand, from the definition, correctly
and for fewer tokens, and keeps them right through three changes. And a check the framework
owns is a check the implementer cannot fix: where the framework was lenient, every server
built on it was wrong the same way, which is the other side of "by construction".

**What it does not show.** Calculators with flat parameters; operations over stored data,
with nested parameters or resources, are not covered, and the cost of hand-written checks
grows with the definition. One model, which writes far more Python than Racket. Fifteen
lineages an arm; the hand-built arm's 100% leaves no variance to estimate from, so its
interval is the declared arm's. The toolkit was used as it was at fhir `c587dcb` (and the
language repositories' commits of the same day); the two gaps this run found are fixed after
it, and that is reported apart, below.

### After the run: the two gaps closed, and the same servers scored again

Not part of D's result: the tasks had been seen by then. Reported because the servers are the
same 120 the implementers left, and nothing in them was touched.

- The capability runtime now holds a POSTed value to the type its key names (a `valueString`
  for a declared decimal, code or date, a `valueDecimal` for a declared Quantity, is a 400
  naming the key to send) and converts only what came as text in a GET query. Number kinds
  stay interchangeable, as FHIR leaves a server free to take them.
- A handler reads the parts of an input that is not one value with `field` and `fields`
  (`(field q 'value)`, `(field q 'code)`), and the guide has a tested example of an operation
  that takes a Quantity.

Scored again under that toolkit (`results/2026-11-22-report-after-the-fix.txt`), every
declared server answers every request as its definition says: 100.0% in all fifteen lineages,
level with the hand-built ones. The cost is the run's (the sessions happened before the fix),
so what the fix would do to the 548k-token session is not measured.

So D, read with what followed it: declaring an operation is not more often right than writing
it by hand, and was less often right while the framework had a leniency no implementer could
correct; with that closed the two are level, and the declared route costs an agent more
tokens, mostly reading the language's guide in every session. The experiment found no
advantage for the declared route. What it did was find two defects in it, which a suite
written by someone who had not seen the toolkit caught and its own tests had not.

