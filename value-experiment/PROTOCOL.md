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

(none)
