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

### 2026-11-22, after D: V (verifying against the source of truth)

The owner, after D: "I want to show the value of the fhir tooling and have that value be real
… I'm thinking without a single source of truth it's impossible to verify correctness." It
takes the place of B in the programme's order; B, C, E and S2 follow as stated.

**What is tested.** M, S and D compared ways of *building*. In each, a model built the thing
by hand about as well as with the toolkit, and what told right from wrong was something that
could be run against it: the authors' test cases, a request suite. V asks about that part. An
implementation exists and may be wrong. Can an agent find and correct what is wrong with it
(a) by reading it against its description, (b) with the expected answers for a few test
patients, as a test suite gives, or (c) with the specification itself executed, which answers
for any patient? The claim: without something that decides, checking does not make an
implementation more right; and a specification that runs is worth more than a fixed set of
expected answers.

**Material.** S's forty implementations as their implementers left them (twenty written from a
measure's narrative, twenty from its CQL; ten of the forty are right on every held-out case),
committed as `spec-first/implementations/`; S's four measures, their descriptions, terminology
and sample patients; the authors' 151 held-out cases, which no session sees.

**Arms.** A checker is an agent given one implementation, the description its implementer had
(the narrative, or the CQL to read), the terminology, the sample patients and the script that
runs the implementation over a directory of patients, and told to check the implementation and
correct any error it finds. It may write further patients. The three arms differ in one thing:

- **R, read**: nothing more.
- **T, tested**: the measure authors' expected answers for the sample patients (a fifth of
  each measure's cases: 12, 6, 12 and 9).
- **O, oracle**: a command that runs the measure's CQL with this toolkit's engine over any
  directory of patients and prints its four answers for each. It prints answers only: a
  checker of an implementation written from the narrative still has the narrative alone to
  read.

One session for each implementation and arm: 120 sessions, the same model, tools (Python and
files in its directory; O's one command besides), prompt but for the sentence naming what the
arm adds. Each session ends by writing its belief: whether the implementation is now right for
every patient.

**Outcomes**, over the held-out cases, each implementation before and after its session:

- **Right** (primary): as in S, all four populations as the authors expect.
- **Fixed and broken**: of the answers wrong before, the share right after; of those right
  before, the share wrong after.
- **Belief**: how often a checker that says the implementation is right is left with one that
  is right on every held-out case.
- **Cost**: input and output tokens, seconds.

**Analysis.** Paired by implementation and case. O − R, O − T and T − R in the share right
after, each with a 95% interval from a bootstrap (implementations resampled within measure and
origin, cases within measure) and a test that swaps the two arms' labels within an
implementation. The forty are 95.7% right before, and the executed CQL is right on 150 of the
151 cases, so over all forty an arm can gain 3.6 points at most: the bar of 5 points cannot be
met there, and it is stated now that it is applied where there is room, to the twenty written
from the narrative (93.0% before). "Significant value" for V: among those twenty, O is right
more often than R by 5 points with the interval above zero. Over all forty the differences and
intervals are reported, with the share of wrong answers fixed.

**What can be wrong with it.**

- The oracle is this toolkit's engine and the truth is the authors' cases; they differ on one
  case of 151. A checker that follows the oracle follows it there too. That is what a single
  source of truth means, and it is counted against O.
- O with the narrative mixes two things: the narrative to read and the CQL to ask. It is the
  situation of someone holding a published measure they cannot read but can run.
- T's expected answers are the authors', which someone had to write; O's are computed. V does
  not price that.
- Forty implementations of four measures by one model; ten start with nothing to fix and can
  only be broken.
- The harness is tried on two implementations in each arm first; those sessions are not counted
  and the sealed run starts every session afresh.

### 2026-11-22, before V's sealed run: V is every kind of artifact the toolkit runs, not measures alone

The owner, on reading V: "This should go beyond measure implementations. Also FHIR spec
implementation, mappings, valueset definitions, all the things the toolkit provides."

V as stated above is its first part, **V-measure**, unchanged but for one thing learnt in the
trial: a session is given at most 60 model turns in every arm (the trial's oracle session on
one implementation took 78 turns and 3.5 million input tokens writing patients to ask about).

The same design is then run for each kind of artifact for which someone other than us has
published both the artifact and what it must answer. The common form:

- **The source of truth** is a published artifact in one of FHIR's languages.
- **The implementation** of it is code outside the toolkit (a Python function), written by an
  independent agent from the artifact and whatever English its publisher gives.
- **Checkers** correct it under R (read), T (the third party's expected answers for a sample
  of inputs) and O (the toolkit runs the artifact on any input).
- **Truth** is the third party's, on inputs no session sees. The toolkit's own agreement with
  that truth is reported beside the arms: it is the oracle's ceiling.
- Outcomes, analysis and the bar are V-measure's.

| part | the artifact | implemented as | truth (not ours) | the oracle |
|---|---|---|---|---|
| V-measure | four eCQMs' CQL | the four populations for a patient | the authors' MADiE cases | cql's engine |
| V-profile ("FHIR spec implementation") | profiles of published guides (StructureDefinitions) | whether a resource conforms | HL7's reference validator (the Java one), over the guides' own examples and resources changed from them | fhir-validation |
| V-view | the ViewDefinitions of the SQL on FHIR test suite | a view's rows for some resources | the suite's expected rows | sql-on-fhir's engine |
| V-map | the maps of the FHIR mapping tutorial and of HL7's structure-mapping test cases | the map's output for a source | their expected outputs | fml's engine |

Each part is stated in full (units, sizes, what is held out) in an amendment of its own before
its sealed run, in the order of the table. Two things are said now because they limit what
this can show:

- **Value set definitions are not a part of V.** A value set over a code system that is at hand
  is finite: asked of every code, the oracle states the whole truth, there is nothing to hold
  out, and an "implementation" is the list. What can be tested for a value set is whether a
  *definition* written from requirements means what was asked, checked by expanding it — the
  author's side, which is E's question (an error seen at its cause) and is run there, for value
  sets, maps and profiles as written in the toolkit's languages.
- **Mappings have little third-party truth.** Expected outputs exist for the tutorial's thirteen
  small steps and six HL7 test cases; no published real-world map comes with outputs someone
  else vouches for. V-map is run on what there is and will be read as that.


### 2026-11-22, before V-profile's sealed run: V-profile in full

**The artifact.** Six profiles of US Core 9.0.0, by a rule fixed before anything was run: of the
guide's resource profiles with at least four published examples, the six with the most elements
in their differential — Patient, MedicationRequest, Organization, Practitioner, Condition
(problems and health concerns), ServiceRequest (`verify/profile-cases.rkt` `profiles`).

**The cases** (741; `cases`). Each profile's published examples (28 in all), and copies of them
with ONE change: an element removed, a code or its system replaced, a list entry doubled, a value
replaced by text, an element the type lacks added — up to six of each kind an example, drawn by a
seeded choice from every place the change can be made.

**Truth.** HL7's reference validator (validator_cli 7.0.6, FHIR 4.0.1, the guide's package, no
terminology server — none is reachable from here —, example urls allowed): a case is valid when
it reports no error. Its verdicts are committed (`verify/truth/`): 393 cases valid, 348 not;
every published example valid.

**Sample and held out.** A profile's first example (by id) and its changed copies are the sample
(158 cases), shown to implementers and checkers under names that do not say what was changed.
The other 583 are held out: no session sees them.

**The implementations.** Five a profile, thirty in all, each written by an independent agent
(a build session) as one Python function, `valid(resource) -> bool`, from: the profile's
published StructureDefinition and the definitions it rests on (the resource type and every FHIR
R4 datatype, the extensions it names or its examples carry, the value sets those definitions
bind and their code systems, the code systems of the codes in its examples — a rule,
`verify/profile-materials.rkt` `spec-files`; all as published in the two packages the truth was
judged in), a statement of what valid means (HL7's validator's errors, as run), the contract,
the unlabelled sample, and a script that runs the function over files. The function may read
those definitions when it runs.

**The checkers.** Each implementation is then checked and corrected by three more agents, one an
arm, each with everything its builder had and the implementation:
- **R** nothing more;
- **T** HL7's validator's verdict for each sample resource;
- **O** a command that holds any resource the checker gives it to the profile's published
  definition and prints `valid` or `invalid` — this toolkit's validator. The verdict alone: what
  is wrong is not said (an error said at its cause is E's question, not this one).
Every session, building or checking: the same model, at most 60 turns, Python's standard library
and the files of its directory, no network; the oracle's one command for O. 120 sessions.

**Outcome and bar.** The share of held-out cases on which an implementation's verdict is HL7's,
as built and after each arm's session; V's bar on O − R (5 points, the 95% interval above zero;
implementations and cases resampled within profile, a case paired across arms and
implementations), with O − T and T − R, verdicts fixed and broken, implementations right on every
held-out case, what each checker said it believed, and a session's cost. The analysis is
V-measure's code (`verify.rkt`), read by `verify/profile-verify.rkt`.

**What the oracle was before this run, and what was done to it.** The oracle is a product under
test too, so its own agreement with the truth was measured first. As committed (fhir 011ee15) the
toolkit's validator agreed with HL7's on 659 of the 741 cases (522 of the 583 held out): it
refused nothing HL7's passes, and passed 82 that HL7's refuses. Its misses were read ON THE
SAMPLE CASES ONLY and fixed as classes in the validator (nothing inside an extension was checked;
`{}`; a code its code system lacks; a coding's system in a required binding; a slice told by a
value set; a slice's maximum; the invariants of datatypes), each gate of the validator holding.
It now agrees on 736 of 741, and on 578 of the 583 held out (99.1%) — the oracle's ceiling. Of
the held-out cases only that count was looked at, never which. So: the oracle has been improved
with the sample's verdicts, which are exactly what arm T is given; it has not seen the held-out
truth. A reader who thinks that still favours O should read O − R with it in mind; the same
fixes are in the toolkit for everyone, which is the point of having a third party's verdicts.

**What this can and cannot show.** Whether an executable definition, asked about inputs of the
checker's own making, leaves a hand-written check of conformance closer to the reference than
reading the definition or having a fixed set of labelled examples. One guide, one model, single
changes of five kinds; a function that may load the definitions is a small validator, and thirty
of them written in an hour each will be far from HL7's. If they are so far that no arm moves
them, or so near that there is nothing to fix, that is the result.

**Prediction, for the record.** As built, 75% to 90% right; R changes little; T fixes what the
sample shows (a few points); O is at least 5 points above R, because every "unknown element" and
"wrong code" case is a question the oracle answers and a reader has to derive.

A trial (one implementation of one profile, built and checked in the three arms) is run first to
find faults in the harness; its sessions are not counted and its directory is not the sealed
run's.

### 2026-11-22, after V-profile's trial and before its sealed run

The trial (one implementation of the Organization profile, built and checked in the three arms;
not counted) found one fault in the harness and nothing to change in the design:

- A checker wrote two scratch files beside its directory (`../t.py`), and the harness, which
  moves a session's directory into the run and removes what held it, failed on the directory
  that was not empty; that session left no record and was run again. The harness now keeps such
  files with the session, under `_outside/`, and the run's log marks the session
  (`agent-bench/run-agent.rkt` `settle!`). Another checker wrote its test resources under
  `/tmp`. Neither reads anything it was not given; both are counted and reported, not excluded.
- The implementation as built was right on 94.1% of its held-out cases — above the 75% to 90%
  predicted — and no arm changed it. The prediction and the bar stand as written.

One thing about the oracle changed between the trial and the sealed run, and is said here because
the oracle is part of what is tested: a gate of this repository (the six fetched guides'
examples through their generated servers) showed that one of the validator's new checks refused
published examples of two other guides — a code of a system that a value set takes whole but
whose content is not at hand was read as "not in the value set". That check now says "cannot
say" unless the value set's definition never names the system. Its agreement with HL7's
verdicts on the 741 cases is what it was: 736, and 578 of the 583 held out.

### 2026-11-22, after V-measure and V-profile: where the programme stands, and a proposal

Not run, and not to be run without the owner's word: this entry is a reading and a proposal.

**What five experiments have shown.** M: the toolkit's reading tools against REST and Python, no
difference. S: a system built from its formal specification is right more often than one built
from the narrative (+5.4 points), and the specification executed more often still. D: an
operation declared in the capability language was right less often than one written by hand,
until two defects the experiment found were fixed; then level. V-measure and V-profile: a
checker that can run the published artifact fixes more of what is wrong than one that reads or
has labelled samples, and breaks about as much by copying the artifact's executor where it
differs from the truth; no difference in how often implementations end up right. Across all
five, the one advantage that held is S's, and it is an advantage of having a formal
specification, not of this toolkit's tools.

**What was found beside the questions asked.** Each time the toolkit was set beside a third
party's verdicts on inputs it had not been built on, it was wrong somewhere nobody knew: two
defects in the capability runtime (D), and 61 of 583 verdicts of the validator (V-profile: an
agent's own two-minute validator was ahead of it), now 5. That is where measurable correctness
was gained in this programme.

**V-view and V-map are not run as stated.** Two parts gave one answer, and these two could add
little: the view suite's expected rows are the engine's own conformance target (its agreement
with that truth is 144 of 144 by construction, so there is no ceiling to measure), and the
mapping tutorial's outputs are 43 small cases the engine was built against.

**Proposed instead (H: held to the reference).** For each engine the toolkit ships, the method
that worked on the validator: a reference implementation run on published inputs and on copies
changed in one small way; this toolkit's answer beside it; the disagreements on a sample read
and fixed as classes, the rest held out and only counted. HL7's validator jar holds reference
implementations of FHIRPath and of the mapping language as libraries (its command line needs a
terminology server for a transform, which this environment's network does not reach; the
library does not); SQL on FHIR has a reference implementation in JavaScript; FSH has SUSHI.
The outcome is not an agent comparison: it is how often each engine gives the reference's
answer, before and after, on inputs nobody tuned it on — a number a user of the toolkit can
rely on, and the thing V showed an oracle's worth to be.

### 2026-11-23, H begins: FHIRPath held to HL7's Java engine

The owner's word on the proposal above: "Continue with your recommendation." H is run one engine
at a time, each part stated here before its first comparison is made. This entry is the first
part. Before it was written one thing was tried and nothing compared: that HL7's validator jar
(validator_cli, the one V-profile's truth came from) can be driven as a library, in one process,
to evaluate FHIRPath as its own `fhirpath` command does — it can (seven seconds to start, then
milliseconds a pair).

**The question.** How often does this toolkit's FHIRPath engine give the answer HL7's Java engine
gives, on published expressions over published resources and on both changed in one small way —
and, where the two differ, which of them the specification bears out?

**The reference.** `validator_cli.jar` as a library: the validator's own FHIRPath engine over its
element model of the resource, FHIR 4.0.1, the core package alone, no terminology server — what
`java -jar validator_cli.jar fhirpath` does. A bridge in Java
(`value-experiment/reference/FhirPathReference.java`) reads a list of (resource file, expression)
pairs and writes, for each, the items of the result or that the engine raised: an item's FHIR
type and its value when it is primitive, else its primitive leaves by path. The bridge calls the
engine and prints; it compares nothing and decides nothing. The reference's answers are
committed, so the comparison runs again without Java.

**The pairs**, each a resource and an expression, in four groups (the rules are code in
`value-experiment/reference/fhirpath-cases.rkt`, committed with this entry's harness before
any answer of the reference is read):

- *search*: every SearchParameter of the R4 core package and of US Core 9.0.0 that has an
  expression, for each of its base types of which US Core publishes an example — the expression
  whole, as published — over every US Core example of that type.
- *invariant*: every constraint, other than ele-1 and ext-1, in the snapshot of each such type's
  core StructureDefinition and of each US Core profile of it, at an element whose path names no
  choice (`[x]`) — the expression as published for a constraint on the resource, and
  `<path>.select(<expression>)` for one on an element — over every US Core example of the type.
- *probe*: a search expression E changed in one way: `(E)` followed by one of a fixed catalogue
  of continuations that between them call the functions and operators of the specification
  (existence, filtering, subsetting, combining, conversion, strings, math, tree navigation, types,
  equality, comparison, collections, boolean logic) — over the first three examples of the type
  in id order. Nothing that reads the clock.
- *changed*: the search and invariant expressions over V-profile's changed copies of the
  examples of its six profiles, of the three kinds that leave well-formed FHIR JSON (an element
  removed, a code or its system replaced, a list's first entry given twice). What an engine does
  with JSON that is not FHIR is not a question about FHIRPath.

Apart from these, and reported apart: the expressions of HL7's own FHIRPath suite for R4 over
its own input resources, by both engines. This toolkit passes that suite's expected outputs on
932 of 934; where the reference differs from it there, the suite says which is right.

**What is compared.** Each engine's answer is brought to one form, in Racket
(`fhirpath-reference.rkt`): `error` when the engine raised (messages are not compared); else the
list of items in order, each a kind and a value. The kinds: string (string, code, uri, id and
the other string-shaped primitives), integer, decimal, boolean, date, dateTime (with instant),
time, quantity, complex. A primitive's value is its text; two numbers are the same value when
they are numerically equal (`1.0` and `1`: precision is not compared); a complex item is the
sorted list of its primitive leaves, each with the path of element names that leads to it. Two
answers agree when they are the same list. This toolkit's engine is called as `raco fhirpath`
calls it (its static check on).

**Sample and held out.** A published expression (with its resource type) belongs to the sample
when the first byte of the SHA-1 of `<type> <expression>` is divisible by five — about a fifth —
and with it all its probes and every resource it runs over; the rest is held out. The suite
group is all sample: the engine was built on it.

**The procedure.** (1) Both engines over every pair, as committed (fhirpath 11e9b4b, fhir
1ba094c); the agreement counted, by group, sample and held out. (2) The sample's disagreements,
and only those, are read and sorted into classes; each class is put under one of three heads,
with its evidence: *ours* — this engine departs from the specification (FHIRPath N1 and FHIR's
additions; then HL7's suite): fixed, with a test that fails without the fix; *the reference's* —
the Java engine departs from the specification or from HL7's suite: kept, named, with the
sentence or the suite test that says so; *open* — the specification does not decide: named, and
the reference followed only where no test of this repository says otherwise. (3) The same pairs
again. A class is written down as a rule over a pair's expression and the two answers, read from
the sample alone; the held-out disagreements are counted by those rules and are not read.

**The outcome**, all from committed Racket: agreement before and after, by group, sample and
held out; the classes, with how many pairs of each part fall under each; the held-out
disagreements after that no class covers (a number, unread). Every gate of the family holds
throughout (the suites' floors: R5 1044/1044, R4 932/934; the 26 search parameters refused; the
validator's gates; every package's tests).

**What would count as what.** There is no bar and no agent here. The finding is the list: what
this engine got wrong that nobody knew (as the validator's 61 verdicts were), what HL7's own
engine gets wrong (a user who moves an expression between the two will meet it), and what is
left unread. A prediction, to be held to: the published expressions agree on more than 95% of
pairs before any fix; the probes on fewer than 90%; the largest class is this engine raising an
error — its static check — where the reference answers nothing.

**Then**, each with an entry of its own before it starts: the mapping language against the same
jar's StructureMap engine; SQL on FHIR against its JavaScript reference implementation; FSH
against SUSHI.

### 2026-11-23, H part 1 after its first read

Three things changed or were found after the first comparison (d0e77d3) and before the outcome
was written; RESULTS.md says each where it bears on a number.

- The compared form: a dateTime in UTC written `Z` and one written `+00:00` are the same value.
  The reference prints `+00:00` for an element whose text is `Z`, so every such element
  differed. The report made before this rule is kept beside the final one.
- The classes are rules over the expression, the two answers and the reference's error message
  (the entry above said the first two). A message is what tells "the reference does not know
  this function" from "the reference could not follow a reference".
- The harness had a defect that changed no count: a structure named `pair` hid Racket's `pair?`
  inside the module, so for one run the class rules matched nothing. The agreement figures never
  used it.

What the protocol does not provide for, and the outcome asks: 618 held-out pairs differ under no
class, and 60 raise under a rule whose cause in the sample is fixed. They have not been read.
Opening them ends their being held out, so it is a second pass with its own entry: the outcome
above stands as measured, and anything found there is reported as found after it.

### 2026-11-23, H part 1, second pass: the held-out pairs opened, and a fresh set

Stated before any held-out pair is read. Part 1's outcome (46c31fc) stands as measured; what
follows is after it and is reported as such.

**Opened.** The 678 held-out pairs of part 1 that differ under no class or under a rule whose
cause in the sample is fixed (618 and 60) are read, sorted into classes by the same three heads,
and what is this engine's is fixed with a test. Once read they are no longer held out, so the
agreement over part 1's pairs after this pass is a description, not a test.

**A fresh set, to test it.** The same rules of `fhirpath-cases.rkt` applied to two guides no
part of this programme has used for FHIRPath: IPS 2.0.1 and mCODE 4.0.0 — their published
examples; the search expressions of the R4 core package and of the guide for each type the
guide publishes an example of; the invariants of each such type's core definition and of the
guide's profiles of it; the same continuations over the first three examples of a type. No
changed copies, no suite. Both engines are run over it once, after this pass's fixes, with this
engine also as it was at part 1's outcome (fhirpath 36f52ff). None of its disagreements is read.
Reported: agreement before and after, and the differences counted by the classes as they stand
at the end of this pass — so the number of fresh pairs that differ under no class says how much
of what there is to find the two passes found.

**A prediction.** The unread 618 are mostly one or two more departures of the reference and a
handful of this engine's; on the fresh set, fewer than 1% of pairs differ under no class.

### 2026-11-23, H part 2: the mapping language held to the validator's StructureMap engine

Stated before any comparison. Tried first, nothing compared: the validator jar's mapping engine
runs as a library with no terminology server (its command line demands one) — one tutorial map
over its source gave the published result.

**The question**, as in part 1: how often does this toolkit's mapping engine (fml) give the
reference's result, on published maps over published sources and on both changed in one small
way; and where they differ, which the specification bears out.

**The reference.** `validator_cli.jar` as a library, FHIR 5.0.0, the core package, no terminology
server: a map's text parsed by its own parser, the source read against the map's source
structure, `transform`, the result written as JSON — what `java -jar validator_cli.jar transform`
does once it has a terminology server. A bridge (`reference/MapReference.java`) loads a step's
logical models, parses each map it is given, runs each (map, source) pair and prints the result
or that the engine raised; it compares nothing.

**The pairs** (`reference/map-cases.rkt`), over the FHIR mapping tutorial as ahdis/matchbox
ships it (fml's vendored corpus: 13 steps, each with its logical models, maps and sources —
the corpus fml was built on, so the published pairs are a calibration and the changed ones
are the test):

- *published*: every map of a step over every source of the step.
- *changed source*: every source with one change — a key removed, a string replaced by
  another, a number raised by one, a list's first entry given twice, a list reversed — over
  the step's maps.
- *changed map*: every map with one change to one rule, from a fixed catalogue — the rule
  removed; a list mode (`first`, `last`, `not_first`, `not_last`, `only_one`) put on a source
  that has none, or replaced by another; a `where` added to a source (`(true)`, `(false)`, a
  test of the variable); the value a target is given replaced by a transform of it (`copy`,
  `truncate`, `append`, `cast` to string and to integer, `evaluate`, a FHIRPath expression in
  parentheses) — over the step's sources. A changed map gets a url of its own.

**What is compared**, in Racket (`reference/map-reference.rkt`): `error` when the engine raised or
did not read the map; else the result as JSON with its keys in order of name and numbers by
value. Two answers agree when they are equal.

**Sample and held out.** A map belongs to the sample when the first byte of the SHA-1 of
`<step>/<map file>` is divisible by three; with it every pair made from it. The rest is held
out: counted, not read.

**The procedure and the outcome** are part 1's: both engines over every pair as committed (fml
db1ae85, fhirpath d24cd50, fhir a1d8c56); the sample's disagreements read and put under *ours*,
*the reference's* or *open*, each with the specification's sentence (the FHIR Mapping Language
page and its transform table, as shipped in the R5 core package) or the tutorial's own expected
result; fixes with tests; the same pairs again; classes as rules, counted over the held-out
pairs, which are not read. Gates: fml's corpus floors (`raco fml --tck`), every package's tests.

**A prediction.** Published pairs agree on more than 90% (this engine passes the tutorial's 37
expected results; the reference is what produced them, with two stale files); changed sources
on more than 85%; changed maps on fewer than 75%, the largest class being what each engine does
with a value that does not fit its target (a string truncated or cast into an integer element).

### 2026-11-23, H part 2, second pass: the held-out mapping pairs opened, and a fresh set

Stated before any held-out pair is read. Part 2's outcome (cdcace2) stands as measured.

**Opened.** The 55 held-out pairs that differ under no class, or under a rule whose cause in the
sample is fixed (52 and 3), are read, classed and — where this engine's — fixed with a test. The
agreement over part 2's pairs after this pass is then a description.

**A fresh set.** ahdis/matchbox's own top-level maps (fml's vendored corpus: maps over FHIR
resources — a QuestionnaireResponse to a Patient, a Bundle's entries, casts, narrative — where
the tutorial's are over small logical models), each with the source fml's own corpus test pairs
it with; the same change catalogues for the maps; for the sources, every single change down to
three levels (they are whole resources). Both engines once, after this pass's fixes, with this
engine also as it was at part 2's outcome (fml ab3d76e). None of its disagreements is read.
Reported: agreement before and after, and the differences by the classes as they stand.

**A prediction.** The 52 hold three or four more classes, at least one of them this engine's.
On the fresh set the engines agree less than on the tutorial (under 80%), because these maps
use FHIR's own types and the reference reads them as R5 where they were written for R4; more
than 10% of its pairs differ under no class. If so, the fresh set says the method has not yet
covered the mapping engine as it has FHIRPath, and that is the finding.

### 2026-11-23, H part 2, third pass: the fresh mapping set opened by its sample, both engines also as R4

Stated before any pair of the fresh mapping set is read. The second pass's outcome (dc03a89; fml
7b358c5) stands as measured: 494 of 667 pairs the same, 168 of the 173 differences under no
class, the reference raising on 137.

**Why another pass.** The set has a split nobody used: a map is in the sample when the first
byte of the SHA-1 of `matchbox/<map file>` is divisible by three (6 of the 17 maps, 325 pairs:
289 the same; the other 11 maps, 342 pairs: 205 the same). And both engines read these maps
as R5, where matchbox wrote them for R4.

**First, with nothing read: both engines as R4.** The same 667 pairs, the reference built with
FHIR 4.0.1 and its core package (the bridge takes the version as an argument), this engine with
the R4 types registered in place of R5's (a process holds one version). Kept beside the R5
answers. Reported: agreement of the like pairs (R5 with R5, R4 with R4), by group and part, and
on how many pairs each engine raises in each version. The version in which the two agree on more
of the SAMPLE is the one the rest of the pass is counted in; the other is reported as it stands.

**Then the sample is read**, in that version: its disagreements (36 as R5) put under *ours*,
*the reference's* or *open* with the specification's sentence, what is this engine's fixed in
fml with a test that fails without it, the classes written as rules. The 11 held-out maps'
pairs are not read: they are counted by the rules, before and after, and stay the measure of
whether six maps stand for seventeen.

**Gates**: fml's corpus floors (`raco fml --tck`), part 2's kept sets as floors (the tutorial's
887 pairs: sample 271, held out 544; the fresh set as R5: 494), every package's tests.

**A prediction.** As R4 the reference raises on fewer than 40 of the 667 pairs (as R5: 137), and
the two engines agree on more than 85% in both parts, so R4 is the version counted in. Of the
sample's differences that remain, more than half are this engine's, in at least two classes
(what a FHIR type's own shape asks of a target: a choice element, a primitive with its
extension, a resource created inside another). After the fixes the held-out maps agree on more
than they did, but stay under the sample: more than 10% of their pairs differ under no class.

**After the two runs, before any pair is read** (results/2026-11-23-map-fresh-r4-before.txt). The
sample is a tie: 289 of its 325 pairs agree as R5 and as R4. The held-out maps agree on 205 of
342 as R5 and 234 as R4; the reference raises on 137 pairs as R5 and 105 as R4. The rule above
does not decide a tie, so it is decided here: R4, the version the maps were written for. The
prediction's first part is already wrong (fewer than 40 raised, more than 85% agreeing).

### 2026-11-23, H part 2, fourth pass: the eleven held-out maps opened, and HL7's own mapping tests as the next fresh set

Stated before any pair of the eleven held-out maps is read. The third pass's outcome stands as
counted (results/2026-11-23-map-fresh-r4-classes-after.txt): the sample's 36 differences are two
causes, neither this engine's result (a `qty` of three arguments, which the specification does
not have and the reference refuses; `conformsTo()`, which the reference cannot evaluate as its
engine runs a transform); of the held-out maps' 108 differences, 98 are under no class. Six maps
did not stand for seventeen, and the third pass's prediction was wrong in every part.

**Opened.** The 108 held-out differences of matchbox's eleven other maps are read, as R4, put
under *ours*, *the reference's* or *open* with the specification's sentence; what is this
engine's is fixed in fml with a test that fails without it. After this pass every pair of the
matchbox set has been read: its agreement is a description.

**The next fresh set**: HL7's own structure-mapping test cases (fhir-test-cases
r5/structure-mapping, which fml vendors): the manifest's tests whose map is the mapping language's
text and whose expected result is JSON — six maps over one QuestionnaireResponse — under the same
change catalogues (a source changed in every single way down to three levels; a map with a rule
removed, a list mode, a `where`, a transform). Both engines as R5, which those tests are written
for; this engine as it is before this pass's fixes and after. No pair of it is read. The split
is kept for a later pass (a map is in the sample when the first byte of the SHA-1 of
`structure-mapping/<map file>` is divisible by three).

**Gates** as in the third pass.

**A prediction.** The 98 are few causes in few maps: maps the reference does not read or cannot
run without a terminology server (`translate`, `memberOf`), and one or two shapes of FHIR's own
types this engine writes differently (a narrative's xhtml, a Bundle's entries, a resource
resolved from a reference). At least two are this engine's. On the fresh set the engines agree
on more than 80% of the pairs: its maps are near kin of matchbox's QuestionnaireResponse maps,
and they are the reference's own tests.

### 2026-11-23, H part 3: the FSH compiler held to SUSHI

Stated before any output of the two compilers is compared. Parts 1 and 2 stand as measured.

**The reference**: SUSHI 3.21.1 (`fsh-sushi` from npm), HL7's compiler of FHIR Shorthand, run as a
library by a Node bridge (`reference/SushiReference.js`) that does what SUSHI's own
`sushiClient.fshToFhir` does, with SUSHI's own functions (the text into its tank, its external
definitions, its exporter), the definitions loaded once instead of for every text. The bridge
is held to `sushiClient.fshToFhir` itself on fifty texts (the same resources, the same error
count) before it is used: it calls and prints, and decides nothing. FHIR 4.0.1; canonical
`http://example.org`; version 1.0.0; the client's `FSHOnly`; no dependency beyond what SUSHI
loads by itself. This toolkit's compiler is given the same facts in a `sushi-config.yaml`
beside the text and run as `raco fsh <dir>` runs (`compile-project`: parse, lint, compile, every
diagnostic), as committed (fsh ca44330, fhir e2dbd6f).

**The pairs** are texts, each a whole FSH document:
- *published*: the 515 inputs of SUSHI's own importer tests (vendored by fsh, from SUSHI 3.21.0:
  written to test its parser, so many name elements that do not exist — which is what an
  author's mistake looks like); the 22 texts of fsh's golden corpus; the FSH blocks of fsh's
  guide.
- *changed*: each published text changed in one small way, each change a text edit of one rule
  line (`* …`): the line removed; a cardinality replaced by another (`1..1`, `0..1`, `1..*`,
  `0..*`, whichever it is not); a flag added (`MS`) where the rule has none, or removed; a
  binding's strength replaced (`required`, `extensible`, `preferred`, `example`: the next one);
  `(exactly)` added to an assignment or removed from it; an assigned code, text or number
  replaced by another of its kind.

**What is compared**, in Racket (`reference/fsh-reference.rkt`): `error` when the compiler
reported an error (SUSHI: a message logged at error level; this compiler: a diagnostic of
severity error), else the resources it wrote, each as JSON with its keys in order of name and
numbers by value, in order of type and id. Two answers agree when they are equal. Beside it the
VERDICT alone (error or not) is reported, since "is this text wrong" is the first thing a
compiler tells an author.

**Sample and held out.** A published text is in the sample when the first byte of the SHA-1 of
`<corpus>/<its name>` is divisible by three, with every text changed from it. Part 2's lesson
is applied: the sample's disagreements are read by cause (the reference's messages and the
shape of the difference), put under *ours*, *the reference's* or *open* with the sentence of
the FSH specification (or SUSHI's own test, where the specification is silent — SUSHI is the
language's reference implementation, and its tests are what the language's authors assert);
what is this compiler's is fixed in fsh with a test that fails without it; the classes are
rules, counted over the held-out texts, which are not read in this pass.

**Gates**: fsh's corpus floors (IPS 108/111, mCODE 339/348, Plan-Net 104/105, HRex 46/46,
Genomics 134/137, GoFSH 117 and 348, importer 514/515, golden 22/22), every package's tests.

**A prediction.** The verdicts agree on more than 85% of the published texts and fewer of the
changed ones; the whole answers agree on 55 to 70%. The largest class is errors SUSHI reports
that this compiler does not: a path whose later step is no element, a value of the wrong type
for its element, a cardinality wider than the base's. Among the texts both compile, most
differences are in what a differential states (SUSHI writes only what changes) rather than in
instances. At least five causes are this compiler's.

### 2026-11-23, H part 3 after its first read

The baseline is kept as measured (90092e6: the same answer on 1,074 of 2,802 texts, the same
verdict on 2,116). The prediction was wrong on both counts (85% and 55 to 70% predicted).
Reading the sample showed one thing about the comparison itself, stated here before any class
is counted:

- **`status`.** SUSHI's client gives its configuration no status, so every resource it writes
  has none; SUSHI's command line, given a `sushi-config.yaml` without one, writes `draft` (run
  here on a three-entity project). The bridge mirrors the client. So where the reference wrote
  no `status` on a resource, this compiler's is left out of the compared form; what this
  compiler writes for a configuration without a status is held to the command line's `draft`
  by a test instead. The first report is kept as `results/2026-11-23-fsh-before-first-form.txt`.
- **Numbers** in the compared form are written so that JSON reads them back (`1.5`, where the
  first kept files wrote the exact `3/2`): the reader parses an answer to say where two differ.
  Equality is as it was; both kept files are written again in this form.
- **Reading by cause** needs more than the first difference of two answers (a difference in
  `status` hid 166 others): the reader lists every path at which two answers differ.

### 2026-11-26, V-profile's validator, second pass: the held-out misses opened, and a fresh set

Stated before any held-out case is read. V-profile's outcome stands as measured, and so does
the ceiling after its sample was read (736 of 741, 578 of the 583 held out). The validator has
changed since in ways no held-out case was read for (the fhir repository's 15e03cc: dom-3, a
compose's absolute systems, derived Questionnaires), so the ceiling is measured again at that
commit, first, and reported as the baseline of this pass.

**Opened.** The held-out cases on which the two validators disagree are read, by cause, with
HL7's messages beside this validator's issues. What is this validator's is fixed as a class,
with a test of its own, under the same gates as before (IG validation 0 errors, the validator
differential 0 false positives, the R5 core's invariants, the guides of fhir-examples). What
is HL7's validator departing from the specification is named with the sentence it departs
from. Once read, these cases are no longer held out: the agreement over the 741 after this pass
describes; it does not test.

**A fresh set, to test it.** The same rule (`profiles`) applied to the profiles that come next
in its ranking: of US Core 9.0.0's profiles with at least four published examples, the six
ranked seventh to twelfth by the elements in their differential; their examples, and the same
changes made the same way (`changes`, `chosen`, the same seeds). HL7's validator judges them
once, offline and with the same options; its verdicts are committed under `truth/fresh/`.
This validator, as it is at the end of this pass and as it was at its start (15e03cc), is
held to them. None of the fresh disagreements is read in this pass. Reported: the agreement,
both validators, by profile and by kind of change, and how many disagreements say valid where
HL7's says invalid and the other way.

**A prediction.** The five held-out misses are two or three causes, one of them HL7's. On the
fresh set this validator agrees on at least 97% of cases and refuses none that HL7's passes.

### 2026-11-26, H part 3, second pass: the named causes fixed, the held-out texts opened

Stated before any held-out text is read. Part 3's outcome stands as measured (SUSHI's answer on
2,355 of 2,802 texts, its verdict on 2,453; 183 held-out differences under no class). The
compiler is measured again first, as it is now (fsh and fhir at their current commits), and that
is this pass's baseline.

**Fixed, as classes.** The causes the sample showed and part 3 named without fixing — a path
whose later step is no element, an index in a profile's path, a RuleSet, a Mapping's Source, an
instance to embed or a concept's ancestor that nothing defines, a value that does not fit its
element — are fixed in fsh, each with a test, where the FSH specification or SUSHI's own tests
say what is right. What SUSHI reports as an error and the specification leaves open is followed
where no published guide of fsh's corpora breaks (the corpus floors are the gate).

**Opened.** Then every held-out disagreement is read by cause (`read-opened`), the 183 under no
class first, and what is this compiler's is fixed as a class with a test. Once read, the
held-out texts describe; they do not test. The two open classes (an instance without a required
element, a quantity's `unit`) are decided in this pass: followed, or kept with the reason.

**What tests it afterwards** is a set no part of this programme has used, built and run in a
pass of its own with its own entry: the FSH of the guides fsh vendors (IPS, Plan-Net, HRex,
Genomics), each a whole project given to both compilers with its dependencies, and changed in
one rule line by the same rules, compared resource by resource.

**A prediction.** The 183 are a dozen causes or fewer, most of them errors SUSHI reports that
this compiler does not; after the pass the same verdict on at least 95% of all texts and the
same answer on at least 92%, and still no text on which this compiler alone errs.

### 2026-11-26, V-profile's validator, third pass: the fresh set's over-reports opened

Stated before any fresh case is read. The fresh set's outcome stands as measured (3,111 of
3,145 verdicts agree; 5 resources refused that HL7's validator passes, 29 passed that it refuses).
The validator has changed since (issues now carry where they are in the instance), so the fresh
set is measured again first, at the current commits, and that is this pass's baseline.

**Opened: the refusals alone.** Refusing what is valid is the worse of the two errors (the
family's rule is fail-open), so only the cases this validator refuses and HL7's passes are read,
by cause, with HL7's messages beside this validator's issues. What is this validator's is fixed
as a class with a test of its own, under the same gates as before (IG validation 0 errors, the
differential 0 false positives, the R5 core's invariants, the guides of fhir-examples). What is
HL7's departing from the specification is named with the sentence it departs from. The 29
passed that HL7's refuses stay unread and held out; once read, the five describe and no longer
test.

**Reported**: the agreement on the fresh set before and after, the refusals by cause, and the 29
as a count only.

**A prediction.** The five are one cause, in the QuestionnaireResponse rules (resource-rules.rkt,
added after the first pass: a derived Questionnaire, or an item checked against a Questionnaire
that the case's changes leave unchanged); after the pass the fresh set refuses none that HL7's
passes, and agrees on at least 3,111.
