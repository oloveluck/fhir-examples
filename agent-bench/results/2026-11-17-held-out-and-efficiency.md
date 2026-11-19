# The held-out check, and the loop on tokens and time (2026-11-17)

FHIR-AgentBench, the tables arm (round 7: `2026-11-16-round7.md`). Before this the gate passed over
the whole test split three times and over the validation sample of 150. Both had been read to
write prompt lines and checks, so nothing said how the arm does on questions nobody had looked at.

## The held-out check

The 274 validation questions outside the sample (`fab/valid-rest-274.json`) had never been run or
read. One pass, with the code as the gate had passed it:

```
runs 1, questions 274, answers 274
as scored       268 of 274 (97.8%)
set aside       4 questions (set-aside.json): 1 of 4 marked right
in scope        267 of 270 (98.9%) over 270 questions: 267 right every time, 0 missed sometimes, 3 missed every time
a question costs  input tokens: mean 45139, median 42210   turns: mean 3.18   seconds: mean 10.3
citations         precision 0.961   recall 0.971
FAIL (allowed: 0 missed every time, 0 missed sometimes)
```

**98.9% in scope on unseen questions, against 99.9% on the test split the prompt was tuned on.**
That is the number to quote for what the arm does on new questions of this benchmark.

The three misses are one kind of mistake. Each is a question of a template the train split does
not have (112 of the 424 validation questions are), so the agent took the nearest kind's example
and kept what that example selects:

| question | the benchmark's answer | answered | what happened |
|---|---|---|---|
| `fd246114…` "What was the microbiology test given to patient … for the last time in the last hospital visit?" | `GRAM STAIN`, `RESPIRATORY CULTURE` | `SPUTUM` | the specimen kind's example: `spec_type_desc` selected where the test's name (`test_name`) is asked |
| `6a0f9787…` "When was patient …'s last hospital visit?" | `2181-10-25 10:44:00` (the admission) | `2181-10-27 15:30:00` (the discharge) | the discharge-time kind's example: no train query selects `admittime` |
| `a49efc1c…` "What microbiology tests did patient … have last in 12/this year?" | `URINE CULTURE` | `2110-12-07 03:05:00` | the "when was the last microbiology test" kind's example: a time where names are asked |

## What was changed for them

Each change is read from the train split or is a general reading; none names a question.

1. **A time is selected exactly where the question asks for one** (`fab/query-checks.rkt`
   `when-regular?`, `time-select`, `says-when`). In the train split every query that selects a time
   column answers a question that says "when", "time" or "date" (471 of 471; the validation
   split's own queries: 105 of 105), and every question that opens with "when" is answered by a
   query that selects one (350 of 350; 79 of 79). `./answer` holds a query that breaks either,
   as it holds a value where the question asks whether. Said of none of the 2,522 train and
   validation queries.
2. **A first or last row picked from several that differ** (`fab/answer.rkt` `tie-note`). A query
   that ends `ORDER BY t DESC LIMIT 1` returns one row; when several rows share that time and say
   different things, which one is chance. `./answer` asks the tables for the tied rows and holds
   the answer, naming the form that returns every row of that time (`… AND t = ( SELECT DISTINCT
   t … LIMIT 1 )`) and a kind whose example is written so, over the same table when there is
   one. The benchmark's own first-or-last queries never meet such a tie (481 of that shape in the
   train and validation splits, none).
3. **A held answer shows the kind it names.** Under a decisive note `./answer` prints that kind's
   example, so the query to copy is in front of the agent. Without it one agent in four gave the
   held command a second time, which writes it (the "daily weight … take the maximum" question,
   missed again in iteration 1's pass).
4. **Two lines of the prompt**: when no kind's example selects what is asked, the nearest example
   gives the conditions and the order and the agent selects the schema's column for it; when a
   visit or stay *was* is when it began.

The validation split is no longer held out. No unseen questions are left in this benchmark: a
later claim about generalising needs other data.

## Citations

Seven of the fifteen in-scope test questions whose cited resources fell short of the benchmark's
were one template, "what was the care unit …": a `transfers` row named the Encounter and not the
Location its `careunit` is read from. The template is in the test split alone (the train split's
33 transfer queries cite nothing), so no check on the train split could show it; the rule it
broke is the tables' own, that a row names every resource behind it. `transfers` now has
`location_fhir_id` (`2026-11-17-tables/transfers.sql`); the answers, the rows and the train
citations of every table are as they were (`check` 2,078 of 2,098, `check-rows` and `check-ids`
unchanged per table). Recall over the test split: 0.971 to 0.990.

What is left, seven questions of 401: six prescriptions where the benchmark cites one Medication
and a row has two behind it (the mixture and its ingredient: the train split's citations are
matched to 0.93, and no better was found there), and one tie where the benchmark's `LIMIT 1`
happens on another row of the same time.

## Where a question's tokens and seconds go

Measured before any change (45.5k input tokens, 3.2 turns, 10.0 s a question):

- A turn re-reads about 14k tokens. 5.5k of them are the agent runtime's: its own system prompt
  (1.5k) and the definitions of its three tools (Bash 3.1k, Read 0.7k, Write 0.2k). 8.5k are the
  question prompt: the kinds of question (5.3k characters), how to work (5.2k), the time phrases
  (4.5k), the schema (3.1k), the question and the task (1.5k).
- 84% of sessions are three turns: read the example and look up a name; `./answer`; say that it
  is done. The third turn does nothing but re-read the whole conversation.
- Each tool call costs 1.2 to 1.4 s before it does anything: 0.31 s loading modules, 0.45 s
  opening the workspace (half of it the search catalogue, which SQL does not use), then 0.07 to
  0.10 s a query. Two calls a question: about a fifth of its ten seconds.

## Iteration 1: fewer tokens a turn

- The tables agent has the shell tool alone (`run.rkt` `builtin`): Read and Write were never
  needed, and their definitions were in every turn.
- The time phrases left the prompt. `./kind <n> [<n> …]` prints the kinds asked for and then the
  phrases, once, when the agent reads its example and not before.
- `./answer --say "<answer>"` for the answer the agent states itself, in place of writing the
  file by hand.

One pass of the test split: 401 of 409 as scored, 400 of 401 in scope (the one: the held command
given twice, above), **40.6k tokens** a question (−11%), 9.6 s. The whole validation split:
414 of 424, 413 of 414 in scope (the one: the tie, above), 40.2k tokens.

## Iteration 2: the session ends when the answer is written

When `./answer` writes the file and has no note of any kind, its last line is `done: …`, and a
hook of the agent runtime (`fab/stop-when-answered.sh`, a Claude Code PostToolUse hook given
with `--settings`) ends the session there. With a note the agent is asked again as before, so
every correction it could make it still can.

How safe that is was counted first, by replaying the 1,651 sessions of the round before: in
1,224 the first `./answer` was clean and nothing followed but the closing turn. In 24 the agent
went on after a clean answer: 19 ended with the same answer, 4 with the same answer in other
words ("no: none on record" for "no"), and one had answered a time to "does the heart rate ever
go greater than 105" and went on to "yes" — a query the time check above now holds. No agent
rewrote a clean answer by hand.

The whole test split three times, with iterations 1 and 2 and the changes above (402, 402 and
401 of 409 as scored):

```
runs 9, questions 409, answers 1227
as scored       1205 of 1227 (98.2%)
set aside       8 questions (set-aside.json): 3 of 24 marked right
in scope        1202 of 1203 (99.9%) over 401 questions: 400 right every time, 0 missed sometimes, 0 missed every time, 1 judged both ways

judged both ways (the same answer marked right in one run and wrong in another: the judge's, no slip):
  580f56a66f7626bbcd078c21  right 2 of 3  Has patient 10023239 had any organisms detected in his last urine microbiology test in 2137?
      answered: no: none on record

a question costs  input tokens: mean 29078, median 24142   turns: mean 3.14   seconds: mean 7.7
citations         precision 0.991   recall 0.99

PASS
```

and the whole validation split once:

```
runs 2, questions 424, answers 424
as scored       415 of 424 (97.9%)
set aside       10 questions (set-aside.json): 1 of 10 marked right
in scope        414 of 414 (100.0%) over 414 questions: 414 right every time, 0 missed sometimes, 0 missed every time
a question costs  input tokens: mean 28530, median 24124   turns: mean 3.15   seconds: mean 7.2
citations         precision 0.958   recall 0.969
PASS
```

| the test split, three passes | before | iteration 1 (one pass) | iteration 2 |
|---|---|---|---|
| as scored | 1205 of 1227 | 401 of 409 | 1205 of 1227 |
| in scope | 1202 of 1203 | 400 of 401 | 1202 of 1203 |
| input tokens a question, mean | 45,474 | 40,611 | **29,078** (−36%) |
| … median | 42,277 | 37,999 | 24,142 |
| … 90th percentile | 58,380 | | 39,513 |
| seconds a question, mean | 10.0 | 9.6 | **7.7** (−23%) |
| citations: precision, recall | 0.991, 0.971 | 0.991, 0.990 | 0.991, 0.990 |

77% of sessions ended at the answer (949 of 1,227), at 25.4k tokens; the others, asked again
after a note, cost 41.6k. The runtime counts the ended turn, so "turns" does not fall: the model
is called twice where it was called three times. The one answer marked wrong is again the judge's:
"no: none on record", given all three times to a question whose recorded answer is `[[0]]`,
marked right twice and wrong once — the second question on which that wording has been judged
both ways. The gate's output is kept in `2026-11-17-tables/gate-held-out-and-iteration2.txt`.

## Iteration 3: three tools of one process, no shell (2026-11-19)

Tried first and dropped: picking a question's likely kinds for it by the words it shares with the
train questions, so that the list of 45 kinds need not be in the prompt. The kind an agent went on
to use is among the first three such picks for 350 of the 424 validation questions, among the
first eight for 405. A question is worded freely; a list that misses the kind one time in six
costs more calls than it saves.

What a call of the model carries before the prompt was measured instead (one call, no question):

| the agent has | tokens |
|---|---|
| the shell tool, the runtime's system prompt (iterations 1 and 2) | 4,669 |
| no tool, the runtime's system prompt | 2,901 |
| no tool, a system prompt of one sentence | 1,380 |

The shell tool's definition is 1.8k tokens and the runtime's own system prompt (written for
someone working in a code base) 1.5k, in every call, for an agent that runs three commands. And
each command started a process that loaded the toolkit and opened the workspace (1.2 to 1.4 s)
before it read a row.

So the arm `tables-tools`: the same tables, examples, checks and instructions, with the three
commands as the three tools of one process (`fab/tables-server.rkt`, a Model Context Protocol
server over the question's workspace: `kind`, `sql`, `answer`, each answering the text the
command printed; their definitions are 400 tokens). The agent has those tools alone, and a system
prompt of one sentence. The workspace is opened once, while the model reads the question. The
prompt lost what was about the shell ("each command line is checked before it runs …"), and the
hook that ends the session is on the `answer` tool. The `tables` arm is unchanged (its prompt to
the byte), so the two can be run side by side.

The whole test split three times (402, 402 and 402 of 409 as scored), and the whole validation
split once:

```
runs 9, questions 409, answers 1227
as scored       1206 of 1227 (98.3%)
set aside       8 questions (set-aside.json): 3 of 24 marked right
in scope        1203 of 1203 (100.0%) over 401 questions: 401 right every time, 0 missed sometimes, 0 missed every time

a question costs  input tokens: mean 22441, median 19007   turns: mean 3.7   seconds: mean 6.5
citations         precision 0.991   recall 0.99

PASS
```

```
runs 2, questions 424, answers 424
as scored       415 of 424 (97.9%)
set aside       10 questions (set-aside.json): 1 of 10 marked right
in scope        414 of 414 (100.0%) over 414 questions: 414 right every time, 0 missed sometimes, 0 missed every time

a question costs  input tokens: mean 21975, median 18971   turns: mean 3.69   seconds: mean 6.3
citations         precision 0.957   recall 0.967

PASS
```

| the test split, three passes | iteration 2 | iteration 3 |
|---|---|---|
| as scored | 1205 of 1227 | 1206 of 1227 |
| in scope | 1202 of 1203 | 1203 of 1203 |
| input tokens a question, mean | 29,078 | **22,441** (−23%) |
| … median | 24,142 | 19,007 |
| … 90th percentile | 39,466 | 31,026 |
| output tokens a question, mean | 491 | 500 |
| seconds a question, mean | 7.7 | **6.5** (−16%) |
| … 90th percentile | 11.0 | 9.4 |
| citations: precision, recall | 0.991, 0.990 | 0.991, 0.990 |

"Turns" rose because the runtime counts each tool call, and a kind and a name looked up at once
are two calls where they were one command line; the model is called as often as before. 407 of
the first pass's 409 answers are word for word iteration 2's. The answer given once ends 1,195 of
the 1,227 sessions (21.9k tokens); iteration 2: 1,153. Of a session's 6.5 seconds the model takes
3.6 (two calls), the tools 1.1, and the agent runtime's own start and end the rest. The gate's
output is in `2026-11-17-tables/gate-iteration3.txt`.

Against the baseline the loop began from (45,474 tokens and 10.0 s a question): half the tokens,
two thirds of the time, the same answers.

## Next in the loop

- **What the prompt holds.** A two-call session reads the prompt twice (6k tokens each time of
  the 22k). How to write the query and give it to `answer` is needed only with the example, and
  of the 31 time phrases a question says one or two.
- **A statement in an open workspace** takes 200 ms where the query itself takes a few: every view
  it reads lists the workspace's files and hashes the defining ones again, and some twenty views of
  the store are made for a statement that names none. It is the tools' second of every session.
- **Answers that select two things** ("2161 | 70" for a yearly maximum): 14 of the last 2,116
  final queries, judged right so far, where every query of the train split selects one.
- **"no: none on record"** is the one wording the benchmark's judge has marked both ways (two
  questions, once each, in iteration 2; not in iteration 3's passes).
- **The other arms** (the workspace verbs with no tables, MCP, plain REST) have not been run
  since rounds 4 to 6; MedAgentBench's workspace arm pays the same two costs iteration 3 removed.
