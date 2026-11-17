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

The first pass of the test split with iterations 1 and 2 and the changes above:

```
runs 3, questions 409, answers 409
as scored       402 of 409 (98.3%)
set aside       8 questions (set-aside.json): 1 of 8 marked right
in scope        401 of 401 (100.0%) over 401 questions: 401 right every time, 0 missed sometimes, 0 missed every time
a question costs  input tokens: mean 29077, median 24142   turns: mean 3.15   seconds: mean 7.6
citations         precision 0.991   recall 0.99
PASS
```

(The runtime counts the ended turn, so "turns" does not fall; the model is called twice where it
was called three times.)

## Next in the loop

- **The tool's cold start** (0.45 s of opening a workspace that a SQL call does not need, twice a
  question): open the search catalogue when a search is run. It changes fhir-mcp's sources, which
  the kept views are keyed by, so the views are computed again once (a few minutes).
- **The kinds of question** are 2.2k tokens in each turn, with slot names like
  `[time_filter_global1]`; the schema's table 1.3k.
- **The other arms** (the workspace verbs with no tables, MCP, plain REST) have not been run
  since rounds 4 to 6.
