# Does the language-oriented approach to FHIR add value for an agent?

Protocol, written 2026-11-22 before any run of it. What is fixed here is not changed after the
sealed tasks are run; a change made before that is dated in "Amendments" at the end.

## The question

An agent can work with health data in two ways.

- **L, the languages.** It writes FHIR's languages (FHIR Shorthand, CQL, the mapping language,
  VCL, FHIRPath, SQL on FHIR views and SQL over them) and a toolkit checks and runs them.
- **G, the general route.** It reads and writes FHIR JSON over REST and computes with a
  general-purpose language (Python). This is what an agent does today with any FHIR server.

Does L make the agent more often right, cheaper, or safer than G, by a margin that matters?

"No" is a possible answer and the protocol is written so that it can come out. What was measured
before this protocol (results/2026-11-16-dsl-vs-json.md, agent-bench/results/) says: writing a
small artifact from stated requirements, JSON and a language are equally correct and the language
is half the tokens; reading a record with the data alone, L is a little ahead (118 against 109 of
150); the large results (147 of 150 at 10k tokens) came from arms that differed from the REST arm
in more than the route: a tuned harness, the benchmark's training examples, weeks of iteration.

## What is held equal

Everything but the route:

1. **Model**, and its settings.
2. **Harness.** Each arm's actions are the tools of one process; no shell; the same system
   prompt; a prompt that holds the task and how to use the arm's tools; the session ends when the
   answer is given. (The token savings found earlier were mostly this, so both arms get it.)
3. **Material.** What one arm is given from a benchmark's training split, the other is given.
4. **Preparation.** Where an arm prepares once before the tasks (L: an agent defines tables over
   the store), the other arm gets a preparing agent with the same material, the same instruction
   ("make the task agents as right and as cheap as you can") and the same time limit, free to
   write whatever helps (notes, a Python library, cached extracts).
5. **Checking.** Where a write is checked, both arms' writes are checked by the same validator
   with the same rules. A third arm, G0, writes to a server that checks nothing, because many do.
6. **Tuning effort.** L has had weeks of tuning; G has had none. So before the sealed run an
   agent whose only goal is to make G win is given the development tasks and a fixed number of
   iterations (5) on G's prompt, tools and preparation. L gets the same 5 on tasks it has not
   been tuned on (experiments B and C), and none where it already has (A).
7. **Rounds.** The same limit of model calls and of feedback rounds.

## The experiments

| | task | truth | tasks (dev / sealed) | arms |
|---|---|---|---|---|
| A1 | answer questions of a hospital's records (FHIR-AgentBench) | the benchmark's recorded answers, its own grader | 150 valid / 409 test | L: SQL over tables defined on the store. G: REST and Python, prepared the same way. R: SQL on the original relational database (the ceiling: the form the questions were written for) |
| A2 | clinical tasks: look up, compute, record, order (MedAgentBench) | the benchmark's reference solutions | 30 / 270 | L: query, post, finish over the workspace. G: get, post, finish over REST, and Python |
| B | record and correct data under a clinic's rules, with traps (a unit the rule forbids, a code without its system, a patient that does not exist, a day off the calendar, a value for the wrong patient) | by construction: each task states the facts; what the store holds afterwards is compared with them | 20 / 80 | L: staged FSH, checked, committed. G: JSON to a validating server. G0: JSON to a server that checks nothing |
| C | compute over a population: who meets a rule, the latest value, a count in a window | by construction: a generator decides each patient's answer first and then writes records that give it, with the mess real records have (a Period where a dateTime is usual, two units, an entered-in-error result, two codings, a time zone at midnight) | 15 / 60 | L-cql: CQL. L-sql: views and SQL. G: Python over REST |

Already measured and reported as they are, not run again: a profile from requirements (FSH
1427, JSON 1431 of 1431 facets; 0.9k against 1.8k tokens) and one change to a resource (every
arm 60 of 60; 26 tokens as rules, 50 as a JSON Patch, 535 whole).

Tasks of B and C are written by an agent that is told the clinical setting and the kinds of trap
and has not seen this toolkit, its guides or its tests, so that they are not chosen for what L is
good at. The generator and the tasks are committed before any arm is run on the sealed set.

## Outcomes

For every task and arm, three passes.

- **Right** (primary). A1, A2: the benchmark's grader. B: after the task, the store holds
  exactly the stated facts, nothing invalid and nothing extra. C: every patient's answer is the
  generator's.
- **Harm** (B only, primary for safety): a wrong or invalid fact left in the store.
- **Cost**: input tokens, output tokens, model calls, seconds, per task; and the preparation's
  cost, once, per arm.

## Analysis

Paired by task. Correctness: the difference in the share right, with a 95% interval from a
paired bootstrap over tasks (a task's value is its share of three passes right), and McNemar's
exact test on tasks right in all three passes. Cost: the ratio of means with a bootstrap
interval. Five primary comparisons (A1 L-G, A2 L-G, B L-G harm, C L-cql-G, C L-sql-G), Holm's
correction at 0.05.

**"Adds significant value" means**, for a family of task: L is right more often than G with the
interval above zero and a difference of at least 5 points; or L is not worse (interval above −3
points) at two thirds of G's cost or less (interval of the ratio below 0.67). Anything else is
reported as "no difference shown", with the interval.

A1's R arm is not a comparison of routes. It says how far each route is from the form the
questions were written for.

## What can still be wrong with it

- The toolkit and both arms' harnesses are written by the same hands. The adversarial tuning of
  G (6 above) is the guard; its transcript is kept.
- One model family. A result is about that model.
- A1's questions come from SQL templates, which favours any route that ends in SQL. A2, B and C
  do not.
- B's and C's truth is by construction, so it is only as real as the generator's mess.
- A1 and A2 have no questions L has not been scored on: its iterations were confirmed on the
  whole validation and test splits of FHIR-AgentBench and on all 300 MedAgentBench tasks (its
  rules were read from the training split only, but a run that failed its gate was fixed and
  run again). G's tuner sees the development tasks only. So A1 and A2 can flatter L, and B and
  C, whose tasks neither arm has seen, are what a claim should rest on.

## Amendments

### 2026-11-22, before any sealed run: narrowed to one comparison (M)

The owner: "I want just enough to determine if there is significant value to using the FHIR
tools with the cli or mcp compared to the harness alone." So one comparison is run first, and
A1, A2, B and C above are run only if asked for afterwards.

**M. The toolkit's tools against the harness alone.** One agent harness (the tools of one
process, no shell, the same system prompt, the same `python` and `answer` tools, the session
ended when the answer is written); the data alone, no training material, no preparation.

- **T** (arm `mcp-tools`): the toolkit's reading tools, `query` and `describe`, served by
  `raco fhir-mcp` as it ships, and its one-page reading card in the prompt.
- **H** (arm `rest-tools`): `get` on a plain FHIR REST server over the same store, and Python
  that can fetch from it; the REST lines in the prompt.

Tasks: FHIR-AgentBench's `fab/test-heldout-150.json`, 150 questions that have been run only on
the tables arms: never on H, and never on the workspace or MCP arms whose tools and card T is.
Truth: the benchmark's recorded answers, its own grader, as scored. One pass of each arm.

Analysis and thresholds as above (paired by question; "significant value" = right more often by
at least 5 points with the interval above zero, or not worse by 3 points at two thirds of the
input tokens or less).

One extension, stated now: if the verdict is "no difference shown" and it is not a clear null
either (the difference's interval inside ±5 points and the cost ratio's inside 0.67 to 1.5), the
109 questions of `fab/test-fresh-109.json` are run on both arms and the 259 analysed together.
Nothing further is added after that.

What can flatter T: its tools and card were tuned on other questions of this benchmark
(rounds 1 to 6: `valid-150`, `test-150`); H has had no tuning. So if T shows value, H is then
given the tuning of point 6 (an agent whose goal is to make H win, 5 iterations on `valid-150`)
and run again on the same 150; the claim stands only if it survives that. If T shows no value
with this advantage, that is the answer.

Not covered by M: writing data (safety), computing over a population, MedAgentBench, and the
command line (the same tools from a shell, which adds the shell's own cost to both sides).

### 2026-11-22, after M and before any run of it: the specification experiment (S)

The owner's hypothesis: "English specification language lacks the specificity and a programming
language provides this. Systems are described with the spec as the source of truth. Spec first
not narrative first. The language makes it possible to build systems with complex concepts
without ambiguity."

**What is tested.** One system described two ways by the same third party, and independent
implementers building it from each description. If English lacks specificity, implementers
working from the narrative will build systems that disagree with each other and with the
intended behaviour, and implementers working from the formal specification will not.

**Material** (`cql/tests/vendor/qicore-2024`, cqframework/ecqm-content-qicore-2024, CC0): four US
clinical quality measures published by their steward — breast cancer screening, cervical cancer
screening, controlling high blood pressure, diabetes glycemic status above 9% — each with

- its **narrative**: the measure's published English (description, the criteria of each
  population, guidance, rationale and recommendation statements), as in its Measure resource;
- its **specification**: the measure's CQL library and every library it includes;
- its **test cases**: 190 patients with the expected result of each (58, 29, 60 and 43), written
  by the measure's authors.

**Arms.** An implementer is an agent that writes one Python function, `evaluate(resources,
valuesets, period_start, period_end)`, answering for one patient whether they are in the
initial population, the denominator, the denominator exclusions and the numerator.

- **N, narrative first**: given the narrative.
- **S, spec first**: given the CQL, and which of its definitions is which population. It cannot
  run CQL; it reads it and implements what it says.
- **X** (no model): the CQL run by this toolkit's engine, as a reference for what a
  specification that is executed gives: 188 of the 190.

Everything else is the same for N and S: the model; the tools (Python, reading and writing
files in its own directory); the prompt but for the sentence naming the description; the
terminology (the value sets and codes the measure declares, by name, with their members: the
published measure lists them beside the narrative too); a sample of the test patients, a fifth
of each measure's (their records only, no expected results, names removed: one measure's test
patients are named after their expected result); the contract of the function, with the rules
of a proportion measure that hold for any measure (denominator only within the initial
population, exclusions only within the denominator, numerator only within the denominator and
not excluded); a script that runs the function over the sample. No network, nothing outside
its directory (each session's commands are audited for it).

Five independent implementers for each measure and arm: 40 sessions.

**Outcomes**, over the test cases that were NOT in the sample (four fifths):

- **Right** (primary): a case is right for an implementation when all four populations are the
  expected ones. An implementation that does not load or raises on a case is wrong on it.
- **Agreement** (primary for "without ambiguity"): the share of cases on which the five
  implementers of an arm give the same four answers.
- **Cost**: input and output tokens, model calls, seconds for an implementation.

**Analysis.** The difference S − N in the share right, pooled over implementations and cases,
with a 95% interval from a two-level bootstrap (implementations resampled within measure and
arm, cases within measure), and a permutation test of the arm labels within measure. The same
difference for agreement, bootstrapped over cases. "Significant value" as defined above: at
least 5 points with the interval above zero.

**What can be wrong with it.**

- Four measures. The intervals describe these four; whether it holds for other systems is an
  argument, not a result of this run.
- The measures are public and the model may have read them, the CQL included. That helps N
  (it may recall what the narrative does not say), so it works against the hypothesis.
- The narrative was written to be read beside the CQL, not to stand alone. It is still the
  English the steward publishes as the measure's description, and what narrative-first has.
- S's implementers translate a formal language by hand, which a spec-first system does not do
  (it runs the specification: X). S isolates the description from the engine: the same target
  language, the same hands, only the description differs.
- The expected results are the authors', with the two known oddities of this export (values
  written as concepts where the case describes a percentage); both arms are held to them alike.

### 2026-11-22, after S: a programme of experiments, and D (the definition as the implementation)

The owner: "I want to keep doing experiments to find the real advantages of the fhir language
ecosystem I've built", and of what those might be: "I can write real code with fsh. Operation
definition make the implementation."

**The programme.** One claimed advantage to an experiment, each stated here before it is run,
under the rules above: one factor differs; the truth is not this toolkit's where that can be
had; the thresholds of "significant value" are the ones already fixed; a null is reported as a
null. In this order, each with its own amendment before its run:

1. **D** (below): the definition is the implementation, so the two cannot drift apart.
2. **B** and **C** as first written: writes that are checked are safer; a rule computed over a
   population.
3. **E**: an error said at its cause. A defect planted in a specification (a profile, a map, a
   library); the turns and tokens to find and fix it from the toolkit's message, against a
   validator's.
4. **S2**: S on another kind of system (a guide's profiles described in its narrative and in
   FSH), since S was four measures.

**D. What is tested.** A FHIR operation is published as an OperationDefinition: its inputs and
outputs, their types, how many of each, the codes an input may take. In this toolkit's
capability language the operation is declared once and the server follows from the
declaration: the definition it serves, the checking of every request against it, the checking
of what the handler answers. The claim: an implementation built that way conforms to its
definition more often than one built by hand, and follows a change to the definition at less
cost. The prediction, stated and not a threshold: about level when first built, apart after the
definition has changed.

**Tasks.** Three clinical calculator operations, written by an agent that has not seen this
toolkit, its guides or this repository. For each: an OperationDefinition (system level, flat
input and output parameters) with a statement of the computation and its rules; then three
changes, one after another, each a new OperationDefinition with the change in words as a
changelog would say it — (1) a new required input that the computation uses, (2) an existing
input constrained (its type, its codes, how many), (3) an output changed (renamed, added or
retyped). For each of the four versions, a suite of requests with the expected answer of each:
requests that conform, with the outputs the statement gives, and requests that do not, one
fault each. A second agent, as independent, checks every case against the definition and the
statement; a case it disputes is dropped before any implementation exists (the count is
reported). A fourth operation, written first by the same author, is for trying the harness and
both arms' prompts; its results are not counted.

**The contract**, given word for word to the author, the checker and both arms. The operation is
called by `POST /$<code>` with a FHIR Parameters resource as JSON. A request that conforms is
answered 200 with a Parameters resource holding exactly the outputs the definition declares,
each of its declared type, with the values the statement gives. A request that does not conform
is answered with a 4xx status and an OperationOutcome; it does not conform when a required input
is missing, an input is given more times than its maximum, an input's value is of another type
than declared, a code is outside a binding the definition requires, or a value breaks a rule the
statement states. Not tested, because FHIR leaves them to the server: an integer where a decimal
is declared (and the reverse for a whole number), an input the definition does not name, GET.

**Arms.** An implementer is an agent that builds a server for the operation and, in three later
sessions (each a new session that finds the directory as the one before left it, the new
definition, the definition before, and the change in words), brings it up to each change.

- **L, declared**: `#lang fhir/capability`, served by `raco fhir-server serve`; given the
  language's guide as it ships (`raco fhir guide capability`) and the commands `racket` and
  `raco`.
- **G, by hand**: Python 3, standard library, written any way the implementer likes (it may
  read the definition at run time).

Everything else is the same: the model; the prompt but for the sentences naming the route; the
definition, the statement, the contract; a fifth of each version's requests as examples,
without their expected answers; a script that starts the server and sends it the examples;
`curl` to its own server; no network, nothing outside its directory (each session's commands
are audited). Five implementers for each operation and arm: 30 lineages of four sessions.

**Outcomes**, over the requests that were not examples:

- **Right** (primary): the status class, the resource type, and for a 200 the outputs — the
  names, each value's type, each value (a number within the case's tolerance). A server that
  does not start is wrong on every request. Pooled over the four versions; and, stated ahead as
  the second reading, over the three versions after a change.
- **Cost** (primary): input tokens of a lineage, and of its three change sessions alone; with
  output tokens, seconds and the lines of the implementation each change touched.

**Analysis.** L − G in the share right, with a 95% interval from a two-level bootstrap (lineages
resampled within operation and arm, requests within operation and version) and a permutation
test of the arm labels within operation; the ratio L/G of input tokens with a bootstrap interval
over lineages. "Significant value" as defined above: right more often by 5 points with the
interval above zero; or not worse by 3 points at two thirds of the input tokens or less.

**What can be wrong with it.**

- The suite tests conformance to the definition, which is what the declared route checks by
  construction. That is the claim, not a flaw, but it means D says nothing about how good the
  handlers' clinical logic is beyond the statement's computation.
- The model writes far more Python than Racket; L's handler is Racket. That works against L.
- L reads a guide G does not need. Its tokens are counted.
- A capable implementer by hand can build its own layer that reads the definition. If it does,
  and the arms are level, that is the answer: the layer is cheap to rebuild.
- Calculators with flat parameters. Operations over stored data, nested parameters and
  resources as inputs are not covered.
- The toolkit is used as it is at the commits recorded with the results: nothing in it is
  changed between this amendment and the end of D's run, whatever the trial operation shows.
- The expected answers are the author's; both arms are held to them alike.

