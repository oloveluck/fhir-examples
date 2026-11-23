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

## V-measure. Verifying against the source of truth: measures (2026-11-22)

The protocol's amendments "after D: V" and "V is every kind of artifact" state it. S's forty
implementations of four quality measures (twenty written from the narrative, twenty from the
CQL), each checked and corrected by three more agents — one that can only read what the
implementer had (R), one that also has the authors' expected answers for the sample patients
(T), one that can also run the measure's published CQL over any patient it writes and see the
four answers (O: cql's engine; nothing of the CQL's text beyond what the implementer had) —
and held to the authors' 151 held-out cases before and after. 120 sessions, one model, at most
60 turns each; no session's commands named anything outside its directory (the audit: 0
flags). The bar was set on the twenty written from the narrative: O above R by 5 points, the
interval above zero.

`racket verify.rkt report verify/results/2026-11-22-measure-run.json` (the scored run, kept as
one file), as printed:

```
implementations checked in every arm: 40 (20 written from the narrative, 20 from the CQL); held-out cases: 151

right on the held-out cases          before    after R    after T    after O
  all                                95.7%     96.0%      96.0%      96.1%
  written from the narrative         93.0%     93.6%      93.2%      93.0%
  written from the CQL               98.4%     98.4%      98.7%      99.2%
  breast                             93.5%     94.6%      93.5%      94.3%
  cervical                           95.7%     95.7%      95.7%      98.3%
  diabetes                           95.9%     95.9%      96.8%      95.3%
  pressure                           97.7%     97.7%      97.9%      97.3%

read (R): of 65 answers wrong before, 5 right after (7.7%); of 1445 right before, 0 wrong after
tested (T): of 65 answers wrong before, 6 right after (9.2%); of 1445 right before, 2 wrong after
oracle (O): of 65 answers wrong before, 31 right after (47.7%); of 1445 right before, 25 wrong after
implementations right on every held-out case: before 10; after R 10, T 10, O 17 (of 40)

read (R): said the implementation is right 22 times, and it was right on every held-out case 7 times; said errors remain 18 times (they did 15 times); no verdict 0
tested (T): said the implementation is right 17 times, and it was right on every held-out case 4 times; said errors remain 23 times (they did 17 times); no verdict 0
oracle (O): said the implementation is right 25 times, and it was right on every held-out case 12 times; said errors remain 10 times (they did 8 times); no verdict 5

written from the narrative: O − R = -0.7 points (95% interval -4.4 to +2.8; label swap p = 0.717)
written from the narrative: O − T = -0.3 points (95% interval -4.1 to +3.2; label swap p = 0.9307)
written from the narrative: T − R = -0.4 points (95% interval -1.9 to +0.7; label swap p = 0.6218)
written from the CQL:       O − R = +0.8 points (95% interval -0.8 to +2.6; label swap p = 0.061)
all:                        O − R = +0.1 points (95% interval -2.3 to +2.3; label swap p = 1.0)
all:                        O − T = +0.1 points (95% interval -2.5 to +2.6; label swap p = 0.9289)
all:                        T − R = -0.1 points (95% interval -0.9 to +0.7; label swap p = 1.0)

a session, read (R): 304.7k input and 5.3k output tokens, 12.2 turns, 45 s
a session, tested (T): 272.4k input and 4.6k output tokens, 11.0 turns, 40 s
a session, oracle (O): 2134.9k input and 35.4k output tokens, 43.0 turns, 265 s

verdict (written from the narrative, O against R)   no difference shown
```

**The bar is not met: no difference shown.** After an oracle's checker the implementations are
right as often as after a reader's (O − R: −0.7 points on those written from the narrative,
−4.4 to +2.8; +0.1 over all forty). The prediction (V's amendment: O clearly above R) was
wrong.

What the average hides is that the arms did very different things:

- **Reading and labelled samples changed almost nothing.** R fixed 5 of the 65 wrong answers
  and broke none; T fixed 6 and broke 2. A checker with nothing to run the measure on mostly
  re-reads the code and agrees with it (R said "right" of 22 implementations; 7 were).
- **The oracle's checkers found half of what was wrong, and broke nearly as much.** They fixed
  31 of the 65 wrong answers (48%), and the implementations right on every held-out case went
  from 10 to 17 of 40 (R: 10, T: 10). They also turned 25 right answers wrong, at seven times
  the tokens (2.1M input a session against 0.3M).

`racket verify.rkt broken verify/results/2026-11-22-measure-run.json` tells the 25 apart:

```
read (R): 0 answers right before and wrong after
tested (T): 2 answers right before and wrong after
  another patient of a measure where, for a sample patient, the specification executed does not give the authors' answer: 2, in 2 implementations (diabetes-S-1, diabetes-S-3)
oracle (O): 25 answers right before and wrong after
  the session was cut off at the turn limit (no verdict written): 8, in 1 implementations (pressure-N-3)
  the specification executed does not give the authors' answer for the patient: 8, in 8 implementations (diabetes-N-1, diabetes-N-2, diabetes-N-3, diabetes-N-4, diabetes-N-5, diabetes-S-2, diabetes-S-4, diabetes-S-5)
  another patient of a measure where, for a sample patient, the specification executed does not give the authors' answer: 4, in 4 implementations (diabetes-N-1, diabetes-N-2, diabetes-N-4, diabetes-N-5)
  neither: 5, in 3 implementations (breast-N-1, breast-N-3, pressure-N-1)
```

- **12 of the 25 are the oracle's own disagreement with the truth, copied.** On two of the
  diabetes measure's 43 patients the CQL executed says "not in the numerator" where the authors
  expect "in" (cql's own test names both: the published bundle holds the HbA1c value as a
  SNOMED concept where the case's description gives a percentage, so there is no number to
  exceed 9%). One of the two is a sample patient, so every diabetes checker with the oracle saw
  it; eight of the ten diabetes implementations were changed to agree with the oracle on the
  other, and four of those were made wrong on a similar patient besides. (The same
  disagreement is why T broke two answers: its checkers were shown the authors' answer for
  that sample patient, which the CQL they were given does not produce.)
- **8 are one session cut off.** Five oracle sessions reached the 60-turn limit and wrote no
  verdict; one of them left its implementation half-changed (pressure-N-3: eight answers).
- 5 are neither.

So, read plainly: **an executable source of truth is what lets a checker find errors at all**
— without one, checking was close to a no-op — **and it is trusted completely, so whatever it
gets wrong is written into every implementation checked against it.** Here its two wrong
answers of 190 (by the authors' labels; by the data, arguably the labels') cost as much as its
fixes gained. An oracle's value in verification is bounded by its own agreement with the truth
more tightly than its 150 of 151 suggests, because its errors are systematic and its checkers
generalise from them.

What this does not show: that the gain and the loss would balance on another artifact. They
balance here because the implementations were already 93% to 98% right (65 wrong answers of
1,510), so one copied disagreement outweighs many fixes. The profile part is run for that
reason on implementations that start much further from the truth.

Costs: `a session` lines above. Limits: four measures, one model, the twenty implementations
written from the CQL had 12 wrong answers among them to fix; a patient the checker writes is
not a patient the authors wrote, and the held-out cases reward only fixes that generalise.
Files: `verify/results/2026-11-22-measure-*`; the sessions' directories are not kept in the
repository (262 MB), the scored run is.

## V-profile. Verifying against the source of truth: conformance to a profile (2026-11-22)

The protocol's amendment "V-profile in full" states it, and the one after it what the trial
changed. Six US Core 9.0.0 profiles; 741 resources judged by HL7's reference validator (their 28
published examples, and 713 copies with one change each), 158 of them a sample and 583 held out.
Thirty implementations of `valid(resource)` in Python, five a profile, each written by an
independent agent in one session from the profile's published definition and what it rests on;
then each checked and corrected by three more agents: R reads, T has HL7's verdicts for the
sample, O can ask this toolkit's validator whether any resource it writes is valid (the verdict,
nothing else). 120 sessions, one model, at most 60 turns each; the audit found no session whose
commands named the network, the toolkit or HL7's validator; two wrote scratch files outside
their directory (one R, one O), which are kept and change nothing they were given.

`racket profile-verify.rkt report verify/results/2026-11-22-profile-run.json`, as printed:

```
implementations built: 30; checked in every arm: 30, of 6 profiles; held-out cases: 583
the oracle itself, on those held-out cases: 578 of 583 as HL7's validator (99.1%)

right on the held-out cases            as built   after R    after T    after O
  all                                  96.3%     97.3%      97.2%      97.7%
  patient                              100.0%     100.0%      100.0%      100.0%
  medicationrequest                    93.4%     94.1%      95.7%      94.5%
  organization                         93.1%     93.5%      94.9%      94.9%
  practitioner                         93.3%     100.0%      93.3%      100.0%
  condition-problems-health-concerns   96.0%     96.5%      97.9%      96.7%
  servicerequest                       99.3%     99.5%      99.3%      99.7%

read (R): of 109 verdicts wrong as built, 33 right after (30.3%); of 2806 right as built, 2 wrong after
tested (T): of 109 verdicts wrong as built, 27 right after (24.8%); of 2806 right as built, 0 wrong after
oracle (O): of 109 verdicts wrong as built, 48 right after (44.0%); of 2806 right as built, 5 wrong after
implementations right on every held-out case: as built 10; after R 13, T 10, O 13 (of 30)

read (R): said the implementation is right 21 times, and it was right on every held-out case 10 times; said errors remain 9 times (they did 6 times); no verdict 0
tested (T): said the implementation is right 21 times, and it was right on every held-out case 8 times; said errors remain 9 times (they did 7 times); no verdict 0
oracle (O): said the implementation is right 17 times, and it was right on every held-out case 6 times; said errors remain 13 times (they did 6 times); no verdict 0

O − R = +0.4 points (95% interval -0.3 to +1.2; label swap p = 0.1932)
O − T = +0.5 points (95% interval -0.5 to +2.3; label swap p = 0.9774)
T − R = -0.1 points (95% interval -1.9 to +1.2; label swap p = 0.991)

a session, build: 316.3k input and 16.6k output tokens, 17.2 turns, 114 s
a session, read (R): 451.7k input and 10.7k output tokens, 18.8 turns, 103 s
a session, tested (T): 497.8k input and 11.1k output tokens, 20.4 turns, 79 s
a session, oracle (O): 645.3k input and 14.3k output tokens, 24.5 turns, 109 s

verdict (O against R)   no difference shown
```

**The bar is not met: no difference shown** (O − R = +0.4 points, −0.3 to +1.2). The prediction
was wrong twice: the implementations as built were right on 96.3% of the held-out cases, not
75% to 90%, and the oracle's checkers ended 0.4 points above the readers', not 5.

What the arms did is V-measure's pattern, milder. Every arm fixed some of the 109 wrong
verdicts — reading 33, labelled samples 27, the oracle 48 — and the oracle's checkers broke
five right ones, four of them the same way as in V-measure:

```
read (R): 2 verdicts right as built and wrong after
  the definition executed does not give HL7's validator's verdict for the resource: 1, in 1 implementations (organization-3)
  neither: 1, in 1 implementations (condition-problems-health-concerns-4)
tested (T): 0 verdicts right as built and wrong after
oracle (O): 5 verdicts right as built and wrong after
  the definition executed does not give HL7's validator's verdict for the resource: 4, in 4 implementations (condition-problems-health-concerns-1, condition-problems-health-concerns-2, condition-problems-health-concerns-3, condition-problems-health-concerns-4)
  neither: 1, in 1 implementations (condition-problems-health-concerns-2)
```

Four implementations of the Condition profile were changed to agree with the oracle on a
resource where the oracle is not HL7's validator. An oracle's own disagreement with the truth
is again what its checkers write into the code they check.

### Written by hand against running the definition

The build phase alone answers a question nobody had asked directly: how good is a check of
conformance that an agent writes for itself from the published definitions?
`racket profile-verify.rkt built verify/results/2026-11-22-profile-run.json`:

```
right on the held-out cases            written by hand  (least, most)     toolkit, before  toolkit, now  cases
  all                                  96.3%            (66.7%, 100.0%)   89.5%            99.1%         583
  patient                              100.0%           (100.0%, 100.0%)  81.6%            100.0%        87
  medicationrequest                    93.4%            (92.0%, 95.5%)    90.9%            98.9%         88
  organization                         93.1%            (91.2%, 95.1%)    93.1%            99.0%         102
  practitioner                         93.3%            (66.7%, 100.0%)   89.9%            100.0%        69
  condition-problems-health-concerns   96.0%            (92.9%, 100.0%)   74.1%            96.5%         85
  servicerequest                       99.3%            (99.3%, 99.3%)    99.3%            100.0%        152

written by hand: one session an implementation, 316.3k input and 16.6k output tokens, 17.2 turns, 114 s; right on every held-out case: 10 of 30
toolkit: this toolkit's validator holding the resource to the profile, no session. Before: as it was before any of HL7's
  verdicts was seen. Now: after its misses on the SAMPLE cases were fixed. HL7's validator is the truth all are held to.
implementations more often right than the toolkit was before: 21 of 30; than the toolkit is now: 1 of 30
```

- **An agent's own validator, written in two minutes, was more often right than this toolkit's
  validator had been** — 96.3% against 89.5% on resources neither had seen; 21 of the 30
  implementations were ahead of it, and all five of the Patient profile's were right on every
  held-out case where the toolkit's validator was right on 81.6%. The toolkit's validator had
  passed every corpus it was held to (330 published examples with no false alarm, HL7's
  validator test cases with none); none of those corpora asks about a resource that is wrong in
  one small way.
- **Held to a third party's verdicts, the toolkit's validator went from 89.5% to 99.1%** in a
  few hours: its misses on the 158 sample cases were read and fixed as classes (nothing inside
  an extension had ever been checked; a code its code system lacks; a slice's maximum; the
  invariants of datatypes …), and the held-out cases, which were not read, moved with them. It
  is now ahead of 29 of the 30. That is the largest gain in correctness measured anywhere in
  this programme, and no agent was compared to get it.
- The comparison is not like for like, and should not be read as one: the implementers were
  told what they would be judged on (examples of one profile, and copies changed in stated
  ways), and wrote for that; the toolkit's validator is one program for every profile and
  every resource. What it shows is narrower and still uncomfortable: for a stated, narrow
  conformance question, "write the check yourself from the definitions" was a better bet than
  "use the toolkit" until the toolkit had been held to the reference.

So the reading of V, over both parts: a source of truth that can be executed does make
checking find errors (it fixed 44% and 48% of wrong answers where reading and labelled samples
fixed 8% to 30%), it costs more tokens, and its checkers trust it completely — so its value is
its own agreement with the truth, which nobody knows until a third party's verdicts are set
beside it. Neither part shows implementations ending up right more often because of it. What
both parts did show is where the toolkit itself was wrong: two answers of 190 for the measures
(arguably the published data's), 61 verdicts of 583 for the profiles (ours, now 5).

Costs: the `a session` lines. Limits: one guide, one model, changes of five kinds made one at a
time; "valid" is HL7's validator without a terminology server; the implementations may read the
definitions at run time, so each is a small validator and the comparison with the toolkit's is
between programs written for different briefs. Files: `verify/results/2026-11-22-profile-*`
(the scored run as one file; HL7's verdicts are `verify/truth/`; the toolkit's verdicts before
the fixes are `2026-11-22-profile-toolkit-before.json`).


## H, part 1. FHIRPath held to HL7's Java engine (2026-11-23)

The protocol's entry "H begins" states it: no agents and no bar. This toolkit's FHIRPath engine
and the engine inside HL7's validator (validator_cli.jar as a library, through
`reference/FhirPathReference.java`, which calls it and prints what it returned) were each given
the same 172,527 pairs of a resource and an expression, and the answers compared in one form
(`reference/fhirpath-reference.rkt`). The pairs (`reference/fhirpath-cases.rkt`): 525 search
expressions and 221 invariants of the R4 core package and US Core 9.0.0 over US Core's 230
examples of 29 resource types; each search expression continued in 116 ways that between them
call the specification's functions and operators, over three examples; the same search and
invariant expressions over 483 of V-profile's changed copies; and, apart, the 853 expressions of
HL7's own R4 suite that name an input. A fifth of the published expressions (by the SHA-1 of
type and text) were the sample, whose disagreements were read; the rest were held out and only
counted. The reference evaluated all of them in eleven seconds; so did this engine.

**Agreement, before and after** (`reference/results/2026-11-23-fhirpath-report.txt`; "before" is
fhirpath 11e9b4b):

```
this engine's answer is the reference's:
  group      part      pairs    agree
  search     sample    950      926 (97.5%)
  search     held-out  6265     5909 (94.3%)
  invariant  sample    417      417 (100.0%)
  invariant  held-out  2688     2684 (99.9%)
  probe      sample    22504    18389 (81.7%)
  probe      held-out  124236   104070 (83.8%)
  changed    sample    2432     2363 (97.2%)
  changed    held-out  12182    11629 (95.5%)
  suite      sample    853      833 (97.7%)
  all but the suite sample    26303    22095 (84.0%)
  all but the suite held-out  145371   124292 (85.5%)

after:
  group      part      pairs    agree
  search     sample    950      926 (97.5%)
  search     held-out  6265     5909 (94.3%)
  invariant  sample    417      417 (100.0%)
  invariant  held-out  2688     2684 (99.9%)
  probe      sample    22504    19141 (85.1%)
  probe      held-out  124236   109342 (88.0%)
  changed    sample    2432     2363 (97.2%)
  changed    held-out  12182    11629 (95.5%)
  suite      sample    853      833 (97.7%)
  all but the suite sample    26303    22847 (86.9%)
  all but the suite held-out  145371   129564 (89.1%)
```

**The sample's disagreements, read and sorted** — each class a rule over the expression, the two
answers and the reference's error message, written from the sample and then counted over the
rest (`…-classes-before.txt`, `…-classes-after.txt`). Before:

```
class                                                                                        head       sample   held out
resolve(): the reference, run as its command line runs it, raises                            reference  1696     7007
toDate(): the reference does not know the function                                           reference  191      1068
toTime(): the reference does not implement it                                                reference  177      1014
hasExtension(): no function of the specification; this engine has it, the reference does not open       355      0
single() of nothing: the reference raises                                                    reference  83       496
convertsTo…() of nothing: the reference answers false                                        reference  664      3968
convertsToString() of a complex value: the reference answers true                            reference  0        0
division: the reference keeps too few digits                                                 reference  94       513
type().name of a FHIR primitive: the reference capitalises it                                reference  55       223
type().name of a nested element: this engine answered its own name for the type              ours       1        0
toString() of a complex value: this engine raised                                            ours       780      5460
children(): this engine's order was a hash walk's                                            ours       10       142
comparing values no order is defined for: an error here, nothing there                       open       78       546
a UTC dateTime as text: Z here, +00:00 there                                                 open       24       24
unclassified                                                                                 -          0        618

sample: 26303 pairs, 4208 differ — the reference's departure 2960, this engine's 791, open 457, in no class 0
  the same answer, or a difference that is the reference's departure: 25055 of 26303 (95.3%)
held-out: 145371 pairs, 21079 differ — the reference's departure 14289, this engine's 5602, open 570, in no class 618 (unread)
  the same answer, or a difference that is the reference's departure: 138581 of 145371 (95.3%)
```

After:

```
class                                                                                        head       sample   held out
resolve(): the reference, run as its command line runs it, raises                            reference  1696     7007
toDate(): the reference does not know the function                                           reference  191      1068
toTime(): the reference does not implement it                                                reference  177      1014
hasExtension(): no function of the specification; this engine has it, the reference does not open       355      0
single() of nothing: the reference raises                                                    reference  83       496
convertsTo…() of nothing: the reference answers false                                        reference  664      3968
convertsToString() of a complex value: the reference answers true                            reference  39       270
division: the reference keeps too few digits                                                 reference  94       513
type().name of a FHIR primitive: the reference capitalises it                                reference  55       223
type().name of a nested element: this engine answered its own name for the type              ours       0        0
toString() of a complex value: this engine raised                                            ours       0        60
children(): this engine's order was a hash walk's                                            ours       0        0
comparing values no order is defined for: an error here, nothing there                       open       78       546
a UTC dateTime as text: Z here, +00:00 there                                                 open       24       24
unclassified                                                                                 -          0        618

sample: 26303 pairs, 3456 differ — the reference's departure 2999, this engine's 0, open 457, in no class 0
  the same answer, or a difference that is the reference's departure: 25846 of 26303 (98.3%)
held-out: 145371 pairs, 15807 differ — the reference's departure 14559, this engine's 60, open 570, in no class 618 (unread)
  the same answer, or a difference that is the reference's departure: 144123 of 145371 (99.1%)
```

**What was this engine's** (three defects nobody knew of, fixed in fhirpath with a test each):

- `toString()` of a complex value (a CodeableConcept, a Reference) raised an error, and so did
  `convertsToString()`. The specification lists what converts and gives the rest no answer;
  `toInteger()` already did that here. 6,240 of the 172,527 pairs.
- `children()` and `descendants()` answered in the order of a hash walk, which can differ from
  one run to the next. The specification leaves the order undefined; it is now the order of the
  type's definition, which is also what the reference answers.
- `type().name` of a nested element (`Location.position`) was `LocationPosition`, this toolkit's
  own name for a generated type. It is `BackboneElement`.

**What is the reference's**, with what says so. None of these is a matter of taste: the
specification's text or HL7's own suite decides each.

- `toDate()` does not exist there and `toTime()` is "not implemented"; both are functions of the
  specification (5.5, Conversion).
- `single()` of an empty collection raises; the specification: "If the input collection is empty
  ({ }), the result is empty."
- `convertsToInteger()` and its seven siblings answer `false` for an empty collection; the
  specification, for each: "If the input collection is empty, the result is empty."
- `convertsToString()` of a complex value answers `true`; the specification: "If the item is
  not one of the above types, the result is false."
- A division keeps the digits of its operands: `1 / 3` is `0.3` and `1.0 / 3` is `0.33`. The
  specification's Decimal has a step of 10^-8.
- `type().name` of a FHIR primitive is capitalised (`Code`, `String`, `DateTime`). HL7's suite
  expects `Patient.active.type().name = 'boolean'` (below: the reference answers false).
- `resolve()` raises ("Parent not set") in the engine as the validator's own `fhirpath` command
  sets it up, so every search parameter written `.where(resolve() is Patient)` fails there:
  8,703 pairs, the largest class. FHIR's definition: an item that does not resolve "is ignored
  and nothing is added to the output collection".

**Open** (the specification does not decide; left as they were): `<` and `>=` between two complex
values is an error here and nothing there; a dateTime written with `Z` keeps it when it becomes
text here and reads `+00:00` there; `hasExtension()` is no function of the specification, yet a
published US Core search parameter (`QuestionnaireResponse.item-subject`) calls it — it exists
here and not there.

**HL7's own suite, by both engines** (`…-suite.txt`). This engine gives the suite's expected
outcome on every one of these 20 (it fails two other tests of the suite, both named in its
manual), so on each the suite says which engine is right:

```
HL7's FHIRPath suite for R4, 853 expressions over its own resources: the two engines differ on 20
  name.given1
    reference: []
    ours:      error: fhirpath: no element HumanName.given1 (did you mean `given`?)
  Encounter.name.given
    reference: []
    ours:      error: fhirpath: no element Patient.Encounter
  Observation.valueQuantity.unit
    reference: [["string","lbs"]]
    ours:      error: fhirpath: direct access to choice element Observation.valueQuantity
  (Observation.value as Period).unit
    reference: []
    ours:      error: fhirpath: no element Period.unit
  Patient.children().skip(1)
    reference: [["complex",["status=generated"]],["complex",["assigner.display=Acme Healthcare","period.start=2001-05-06","system=urn:oid:1.2.36.146.595.217.0.1","ty…
    ours:      error: fhirpath: skip() on an unordered collection
  Patient.name.select(given | family).distinct()
    reference: [["string","Chalmers"],["string","Jim"],["string","Peter"],["string","James"],["string","Windsor"]]
    ours:      [["string","Peter"],["string","James"],["string","Chalmers"],["string","Jim"],["string","Windsor"]]
  iif('non boolean criteria', 'true-result', 'true-result')
    reference: [["string","true-result"]]
    ours:      error: fhirpath: expected Boolean
  Appointment.identifier.startsWith('rand')
    reference: []
    ours:      error: fhirpath: startsWith() applied to a complex type Identifier
  Appointment.identifier.endsWith('rand')
    reference: []
    ours:      error: fhirpath: endsWith() applied to a complex type Identifier
  Appointment.identifier.contains('rand')
    reference: []
    ours:      error: fhirpath: contains() applied to a complex type Identifier
  Patient.active.type().namespace = 'FHIR'
    reference: [["boolean","false"]]
    ours:      [["boolean","true"]]
  Patient.active.type().name = 'boolean'
    reference: [["boolean","false"]]
    ours:      [["boolean","true"]]
  Patient.active.is(Boolean).not()
    reference: [["boolean","false"]]
    ours:      [["boolean","true"]]
  Patient.active.is(System.Boolean).not()
    reference: [["boolean","false"]]
    ours:      [["boolean","true"]]
  Patient.type().namespace = 'FHIR'
    reference: [["boolean","false"]]
    ours:      [["boolean","true"]]
  Patient.is(System.Patient).not()
    reference: [["boolean","false"]]
    ours:      [["boolean","true"]]
  conformsTo('http://hl7.org/fhir/StructureDefinition/Patient')
    reference: error: Error: No parent on root resource
    ours:      [["boolean","true"]]
  conformsTo('http://hl7.org/fhir/StructureDefinition/Person')
    reference: error: Error: No parent on root resource
    ours:      [["boolean","false"]]
  Observation.valueQuantity.exists()
    reference: [["boolean","true"]]
    ours:      error: fhirpath: direct access to choice element Observation.valueQuantity
  Patient.name.as(HumanName).use
    reference: [["string","official"],["string","usual"],["string","maiden"]]
    ours:      error: fhirpath: as() requires a singleton input
```

**Reading.**

- Held out, the two engines gave the same answer on 85.5% of pairs before and 89.1% after. With
  the reference's own departures set aside the figure is 95.3% before and 99.1% after: the
  three fixes account for all but a fraction of a point of what was this engine's. 618 held-out
  pairs differ under no class and 60 still raise under the `toString()` rule; they are unread,
  as the protocol requires, and are the next thing to open (below).
- The prediction was right about the probes (under 90%) and wrong twice: published search
  expressions agreed on 94.3% held out, not above 95%, because of `resolve()`; and the largest
  class was not this engine's static check — which never fired on a published expression — but
  the reference failing to follow a reference.
- Neither engine is a safe oracle for the other. Of 15,807 held-out differences after the
  fixes, 14,559 are cases where HL7's engine departs from HL7's specification, in functions a
  profile author can plausibly write (`single()`, `convertsTo…()`, a division, `toDate()`). This
  is V's finding again from the other side: what an executable reference is worth is its own
  agreement with the specification, and that has to be measured, not assumed — here it could
  be, because there is a specification text and a suite to appeal to.
- What a user of the toolkit can rely on: on published search parameters and invariants over
  published resources, the answer is HL7's engine's except where that engine cannot follow a
  reference; on the wider function library, the differences are listed, and the manual's Limits
  now say them.

**Three things about the harness, said because they were decided after the first read.**
(1) The compared form gained one rule: a dateTime in UTC written `Z` is the one written
`+00:00` (the reference prints the second for an element whose text is the first). The first
report, made before it, is kept (`…-before-first-form.txt`: search 93.5% and 93.4%); the tables
above use the final form for before and after alike. (2) The classes use the reference's error
message as well as the two answers; the protocol said "the expression and the two answers". The
messages are committed beside the answers. (3) Of this engine's own making: the first cut of the
`children()` fix listed an element twice, and the comparison showed it before anything was
committed — the harness doing for a fix what it does for the engine.

Limits: one reference implementation and one version of it; FHIR R4 and one guide's examples;
the continuations are a fixed list, so a function it does not call is not compared; an
expression's static rejection is this engine's alone (the reference was not asked to check
types), so the two differ there by construction and only the suite shows it. Files:
`reference/answers/` (the reference's answers and messages, this engine's before and after),
`reference/results/2026-11-23-fhirpath-*`; the module's test holds the live engine to the
reference's kept answers, with the agreement above as floors.

### Second pass: the held-out pairs opened, and a fresh set (after the outcome above)

The protocol's entry of the same name states it. Part 1's 678 held-out pairs that differed under
no class, or under a rule whose cause was fixed, were read. They held one more defect of this
engine, three more things the reference does that the specification does not, and three things
the specification leaves open:

- *This engine's*: `hasValue()` of several items answered for the first of them. FHIR's
  definition is about "a single value"; of several it is now false. Fixed in fhirpath, with a
  test.
- *The reference's*: `toInteger()`, `toDecimal()`, `toBoolean()`, `toQuantity()`, `toDateTime()`
  of a value read from the resource answer nothing, and their `convertsTo…()` false, even for
  `Patient.active.toBoolean()` — it converts literals and computed values only. And a path
  rooted at another type than the resource's (`DocumentReference.extension(…)` over a Patient:
  the core package's own example search parameter, whose base is not its expression's type)
  answers nothing where HL7's suite requires an error (`testSimpleWithWrongContext`); this was
  the class the prediction expected to be the largest, and it is 412 pairs.
- *Open*: FHIR's own invariant dom-3 calls `as()` on several items, which HL7's suite makes an
  error — this engine follows the suite, the reference answers; `Resource.id` is a
  System.String by its definition and an `id` to the reference, so `hasValue()`, `is string`
  and `type().name` differ on it (and `hasValue()` of a computed Boolean is true there); a
  step named `div` without backticks, which this harness wrote by joining an invariant's path to
  its expression, is a syntax error here (as the grammar reads it) and read there.

Part 1's pairs with every class (`reference/results/2026-11-23-fhirpath-second-classes.txt`;
a description now, since all of it has been read):

```
class                                                                                        head       sample   held out
resolve(): the reference, run as its command line runs it, raises                            reference  1696     7007
toDate(): the reference does not know the function                                           reference  191      1068
toTime(): the reference does not implement it                                                reference  177      1014
hasExtension(): no function of the specification; this engine has it, the reference does not open       355      0
single() of nothing: the reference raises                                                    reference  83       496
convertsTo…() of nothing: the reference answers false                                        reference  664      3968
convertsToString() of a complex value: the reference answers true                            reference  39       270
division: the reference keeps too few digits                                                 reference  94       513
type().name of a FHIR primitive: the reference capitalises it                                reference  55       223
type().name of a nested element: this engine answered its own name for the type              ours       0        0
a path rooted at another type than the resource's: an error here, as HL7's suite requires; nothing there reference  0        412
a step named div without backticks (this harness's own joining of an invariant's path): a syntax error here, read there open       0        2
as() of several items (FHIR's own dom-3 calls it so): an error here, as HL7's suite requires; an answer there open       0        38
toInteger(), toDecimal() … of a value read from the resource: the reference answers nothing  reference  0        46
convertsToInteger() … of a value read from the resource that converts: the reference answers false reference  0        78
hasValue() of several items: this engine answered for the first                              ours       0        0
hasValue() of a value that is no FHIR primitive (Resource.id, a computed Boolean): false here, true there open       0        50
Resource.id: a System.String here, as its definition says; an id there                       open       0        44
toString() of a complex value: this engine raised                                            ours       0        0
children(): this engine's order was a hash walk's                                            ours       0        0
comparing values no order is defined for: an error here, nothing there                       open       78       540
a UTC dateTime as text: Z here, +00:00 there                                                 open       24       24
unclassified                                                                                 -          0        0

sample: 26303 pairs, 3456 differ — the reference's departure 2999, this engine's 0, open 457, in no class 0
  the same answer, or a difference that is the reference's departure: 25846 of 26303 (98.3%)
held-out: 145371 pairs, 15793 differ — the reference's departure 15095, this engine's 0, open 698, in no class 0 (read in the second pass)
  the same answer, or a difference that is the reference's departure: 144673 of 145371 (99.5%)
all: 171674 pairs, 19249 differ — the reference's departure 18094, this engine's 0, open 1155, in no class 0
  the same answer, or a difference that is the reference's departure: 170519 of 171674 (99.3%)
```

**The fresh set**: the same rules over IPS 2.0.1's and mCODE 4.0.0's examples, search
parameters and profiles — 142,488 pairs no part of this programme had seen, evaluated once by
both engines, none of them read. "Before" is this engine at part 1's outcome (fhirpath 36f52ff),
"after" with the `hasValue()` fix. IPS:

```
this engine's answer is the reference's:
  group      part      pairs    agree
  search     sample    112      109 (97.3%)
  search     held-out  773      750 (97.0%)
  invariant  sample    84       84 (100.0%)
  invariant  held-out  357      357 (100.0%)
  probe      sample    8120     7153 (88.1%)
  probe      held-out  51852    46393 (89.5%)
  all but the suite sample    8316     7346 (88.3%)
  all but the suite held-out  52982    47500 (89.7%)

after:
  group      part      pairs    agree
  search     sample    112      109 (97.3%)
  search     held-out  773      750 (97.0%)
  invariant  sample    84       84 (100.0%)
  invariant  held-out  357      357 (100.0%)
  probe      sample    8120     7153 (88.1%)
  probe      held-out  51852    46393 (89.5%)
  all but the suite sample    8316     7346 (88.3%)
  all but the suite held-out  52982    47500 (89.7%)
```

```
all: 61298 pairs, 6452 differ — the reference's departure 6156, this engine's 0, open 230, in no class 66
  the same answer, or a difference that is the reference's departure: 61002 of 61298 (99.5%)
```

mCODE:

```
this engine's answer is the reference's:
  group      part      pairs    agree
  search     sample    595      584 (98.2%)
  search     held-out  4247     4100 (96.5%)
  invariant  sample    370      370 (100.0%)
  invariant  held-out  1854     1854 (100.0%)
  probe      sample    10904    9860 (90.4%)
  probe      held-out  63220    56179 (88.9%)
  all but the suite sample    11869    10814 (91.1%)
  all but the suite held-out  69321    62133 (89.6%)

after:
  group      part      pairs    agree
  search     sample    595      584 (98.2%)
  search     held-out  4247     4100 (96.5%)
  invariant  sample    370      370 (100.0%)
  invariant  held-out  1854     1854 (100.0%)
  probe      sample    10904    9860 (90.4%)
  probe      held-out  63220    56181 (88.9%)
  all but the suite sample    11869    10814 (91.1%)
  all but the suite held-out  69321    62135 (89.6%)
```

```
all: 81190 pairs, 8241 differ — the reference's departure 7883, this engine's 0, open 358, in no class 0
  the same answer, or a difference that is the reference's departure: 80832 of 81190 (99.6%)
```

(The sample and held-out rows of these tables are the same split by expression as before and
mean nothing here: nothing of the fresh set is read. The class tables are in
`…-fresh-ips-classes.txt` and `…-fresh-mcode-classes.txt`.)

**Reading.** On 142,488 fresh pairs the two engines give the same answer on 127,795 (89.7%);
with the reference's departures set aside, on 141,834 (99.5%); 588 differ under a class that is
open; none under a class that is this engine's; and 66 (0.05%, all in IPS) under no class at
all — the prediction said under 1%. So the classes read from a fifth of US Core's expressions,
then from the rest, describe what happens on two other guides almost completely: what there
was to find about this engine by this method, on this function list, the two passes found
(four defects), and what remains between the two engines is a list a user can read. The 66
are unread and are the next thing to open if this is taken further.

What the method cost: the reference answers 172,527 pairs in eleven seconds and this engine in
twelve, so the whole comparison — pairs, both engines, classes — runs in under a minute, and
the module's test now holds the live engine to all three kept sets.

## H, part 2. The mapping language held to the validator's StructureMap engine (2026-11-23)

The protocol's entry "H part 2" states it. This toolkit's mapping engine (fml) and the engine
inside HL7's validator (as a library, FHIR 5.0.0, no terminology server, through
`reference/MapReference.java`) were given the same 887 pairs of a map and a source
(`reference/map-cases.rkt`): the FHIR mapping tutorial's 25 maps over its 18 sources (40
published pairs), the sources changed in one way (133), and the maps changed in one way — a
rule removed, a list mode put on a source, a `where` added, a target's value replaced by a
transform of it (714). A third of the maps (8) were the sample; the other 17 held out.

**Agreement, before and after** (`reference/results/2026-11-23-map-report.txt`; "before" is fml
db1ae85):

```
this engine's result is the reference's:
  group           part      pairs   agree
  published       sample    14      14 (100.0%)
  published       held-out  26      24 (92.3%)
  changed-source  sample    44      41 (93.2%)
  changed-source  held-out  89      81 (91.0%)
  changed-map     sample    223     205 (91.9%)
  changed-map     held-out  491     428 (87.2%)
  all             sample    281     260 (92.5%)
  all             held-out  606     533 (88.0%)
  of the 793 pairs that agree, both engines raise on 80; the reference raises on 149 of the 887 pairs

after:
  group           part      pairs   agree
  published       sample    14      14 (100.0%)
  published       held-out  26      24 (92.3%)
  changed-source  sample    44      43 (97.7%)
  changed-source  held-out  89      85 (95.5%)
  changed-map     sample    223     214 (96.0%)
  changed-map     held-out  491     435 (88.6%)
  all             sample    281     271 (96.4%)
  all             held-out  606     544 (89.8%)
  of the 815 pairs that agree, both engines raise on 100; the reference raises on 149 of the 887 pairs
```

**The sample's 21 disagreements, read and sorted** (`…-map-classes-before.txt`,
`…-map-classes-after.txt`). Before:

```
class                                                                                                head       sample   held out
a FHIRPath expression that names a variable with an underscore: the reference does not read the map  reference  9        7
a text that is no number put into a number's element: this engine wrote it as it stood               ours       8        9
check and the list mode: this engine picked by the list mode first, the reference checks every element ours       2        2
a target that names a variable, with nothing after it: this engine copied the source value into it   ours       2        3
a value that is no integer, put into an integer element and then replaced: an error here, the last value there open       0        0
unclassified                                                                                         -          0        52

sample: 281 pairs, 21 differ — the reference's departure 9, this engine's 12, open 0, in no class 0
  the same answer, or a difference that is the reference's departure: 269 of 281 (95.7%)
held-out: 606 pairs, 73 differ — the reference's departure 7, this engine's 14, open 0, in no class 52 (unread)
  the same answer, or a difference that is the reference's departure: 540 of 606 (89.1%)
all: 887 pairs, 94 differ — the reference's departure 16, this engine's 26, open 0, in no class 52
  the same answer, or a difference that is the reference's departure: 809 of 887 (91.2%)
```

After:

```
class                                                                                                head       sample   held out
a FHIRPath expression that names a variable with an underscore: the reference does not read the map  reference  9        7
a text that is no number put into a number's element: this engine wrote it as it stood               ours       0        1
check and the list mode: this engine picked by the list mode first, the reference checks every element ours       0        0
a target that names a variable, with nothing after it: this engine copied the source value into it   ours       0        2
a value that is no integer, put into an integer element and then replaced: an error here, the last value there open       1        0
unclassified                                                                                         -          0        52

sample: 281 pairs, 10 differ — the reference's departure 9, this engine's 0, open 1, in no class 0
  the same answer, or a difference that is the reference's departure: 280 of 281 (99.6%)
held-out: 606 pairs, 62 differ — the reference's departure 7, this engine's 3, open 0, in no class 52 (unread)
  the same answer, or a difference that is the reference's departure: 551 of 606 (90.9%)
all: 887 pairs, 72 differ — the reference's departure 16, this engine's 3, open 1, in no class 52
  the same answer, or a difference that is the reference's departure: 831 of 887 (93.7%)
```

**What was this engine's** (three defects, fixed in fml with every corpus floor held):

- A text that is no number, put into a number's element, was written as it stood:
  `tgt.a21 = append(a, 'x')` gave an integer element the string `"12345x"`, and a source value
  `"changed"` copied into an integer element stayed a string. The tutorial's own step 4 says
  this is an error; it is one now, at the rule.
- A target that names a variable and has nothing after it (`src.e as s -> tgt.e as t then { }`)
  copied the source value into the element. The implicit copy belongs to the simple form
  `src.x -> tgt.x`, with no variables; a target with a variable creates its element and no
  more.
- `check` was tested after the list mode had picked among the elements; the reference tests it
  on every element the source selects. The specification does not state an order, and nothing
  in fml's corpus depended on it, so the reference's is followed.

**What is the reference's**: it does not read a map whose FHIRPath expression names a variable
with an underscore (`where (s_e.exists())`: "Found s_e expecting a token name"), though the
mapping language's own rule names it without complaint and FHIRPath's grammar allows the
character. **Open**: a value that is no integer, put into an integer element and replaced by a
later one, is an error here at its rule and the last value there — the reference's error comes
only when the result is written out.

**Reading.**

- Held out, the two engines agreed on 88.0% of pairs before and 89.8% after; on the sample
  92.5% and 96.4% (99.6% with the reference's one departure aside). The prediction was wrong
  about the changed maps: they agreed on 87% to 92% before any fix, not under 75%. It was right
  about what the largest class of this engine's would be: a value that does not fit its
  target.
- Unlike FHIRPath, the sample did not cover the rest: 52 of the 606 held-out pairs (8.6%)
  differ under no class. Eight maps are too few to stand for seventeen that each teach a
  different feature of the language — the tutorial is built that way. Those pairs are unread;
  a second pass is the next entry.
- Three more defects nobody knew of, in an engine that passes every expected result of the
  corpus it was built on. The published pairs alone showed nothing (they are that corpus); the
  changed ones did.

Limits: one reference, the tutorial's small logical models (strings and integers, little of
FHIR's own types), a catalogue of changes written by this harness, 887 pairs. Files:
`reference/answers/map-*`, `reference/results/2026-11-23-map-*`; the module's test holds the
live engine to the reference's kept answers.
