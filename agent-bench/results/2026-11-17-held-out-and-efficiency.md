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

## Iteration 4: the prompt holds what the first call needs (2026-11-19)

A call of the model re-reads everything before it, so what the prompt holds is paid for in every
call: of a two-call session's 22k tokens, 12k were the prompt read twice. The agent's first call
does one thing with it: picks the kind and looks the names up.

- **The rest comes with the example.** How to write the query from the example and how to give it
  to `answer` (steps 2 and 3 of the instructions) left the prompt; the `kind` tool says them with
  the first example it shows, once (`examples/next.md`). The prompt is 10.0k characters where it
  was 14.9k.
- **The time phrases the question says.** The `kind` tool printed how each of the 31 kinds of time
  phrase is written. It now prints those the question's words hold (`query-checks.rkt`
  `said-times`, from the train split's forms of each kind): every phrase of each of the 424
  validation questions is among those found, 1.7 kinds a question; `every_phrase: true` lists
  them all (asked for in none of the confirming run's 1,651 sessions).
- **The kinds list names a slot by what it holds** (`[when]`, `[first/last]`, `{patient}` for
  `[time_filter_global1]`, `[time_filter_exact1]`, `{patient_id}`): 4.2k characters, was 5.3k.
  First written with the two times of a comparison numbered (`[first/last 2]`), which reads as
  "second to last": one validation answer compared its two values the wrong way round (it did not
  recur in 70 further runs of those questions under either labelling). Both slots read alike now,
  told apart by their place in the sentence.
- **The opening** says nothing of FHIR resources or of how to word an answer: the `answer` tool
  states the answer.

Four checks came with it, each read from the train split and said of none of its queries:

- **One thing is selected** (`selected`, `one-selected?`): every query of the train split selects
  one thing (2,098 of 2,098). In iterations 2 and 3 fourteen of 2,116 final queries selected the
  group beside the value ("2161 | 70" for a yearly maximum) or every column; such an answer is
  held now.
- **A name compared through `lower(trim(…))` is a name** (`name-comparisons`): the checks on names
  read `column = 'name'` and saw nothing in a query written for "account for all variations in
  letter case and surrounding whitespace".
- **An empty answer under a name that reads another way** (`own-word-readings`, `answer.rkt`
  `own-word-note`): the one validation miss of the first run. The question says "total tf residual
  output amount"; the tables have the outputs `TF Residual` and `TF Residual Output`; questions of
  its kind say "{output_name} output". The agent named the longer, found nothing, and the session
  ended on "none"; the benchmark's 230 is under `TF Residual` (as for the train split's two such
  questions). When the answer is empty and the name is another value of its column followed by
  the word the kind's own template says there, the tool says so and the session goes on.
- **A name is named exactly** (`by-pattern`, `exact-names?`): no query of the train split matches
  by pattern (0 of 2,098 use `LIKE`). Of 3,342 final queries of this arm two did, and one was the
  miss of a test pass: "the number of times patient … got a cerebral ventricular #1" counted
  procedures `LIKE '%cerebral ventricle%'` and answered none, where the name is an output
  (`d_items`), found in seven earlier runs by looking further. Such a query is held, and the
  tool says where a name may be. (The miss was on a test question; the rule is the train split's.)

And in the toolkit, a statement in an open workspace does its bookkeeping once (the fhir
repository's notes, "A statement in an open workspace"): 200 ms to 30–90 ms a statement, the
`answer` call 700 to 360 ms. The tables were computed again under the changed sources and give
the train split's 2,098 queries the answers they gave (2,078, the same per table).

The confirming run was started three times. The first code missed the validation question above
(413 of 414) and passed a whole test pass (401 of 401); with that fixed, validation was 414 of
414 and a test pass missed the pattern-matching question (400 of 401). What follows is the third
run, all of it under the final code: the whole validation split once, the whole test split three
times.

```
runs 2, questions 424, answers 424
as scored       415 of 424 (97.9%)
set aside       10 questions (set-aside.json): 1 of 10 marked right
in scope        414 of 414 (100.0%) over 414 questions: 414 right every time, 0 missed sometimes, 0 missed every time

a question costs  input tokens: mean 16682, median 14584   turns: mean 3.67   seconds: mean 6.0
citations         precision 0.958   recall 0.969

PASS
```

```
runs 9, questions 409, answers 1227
as scored       1206 of 1227 (98.3%)
set aside       8 questions (set-aside.json): 3 of 24 marked right
in scope        1203 of 1203 (100.0%) over 401 questions: 401 right every time, 0 missed sometimes, 0 missed every time

a question costs  input tokens: mean 17038, median 14622   turns: mean 3.67   seconds: mean 6.3
citations         precision 0.991   recall 0.99

PASS
```

| the test split, three passes | iteration 3 | iteration 4 |
|---|---|---|
| as scored | 1206 of 1227 | 1206 of 1227 |
| in scope | 1203 of 1203 | 1203 of 1203 |
| input tokens a question, mean | 22,441 | **17,038** (−24%) |
| … median | 19,007 | 14,622 |
| … 90th percentile | 31,026 | 24,171 |
| output tokens a question, mean | 500 | 486 |
| seconds a question, mean | 6.5 | 6.3 |
| … 90th percentile | 9.4 | 8.8 |
| citations: precision, recall | 0.991, 0.990 | 0.991, 0.990 |

The answer given once ends 1,212 of the 1,227 sessions. The time barely moved: a session's
seconds are the model writing its query, the tools, and the agent runtime's own start and end,
none of which the prompt's length changes. The gate's output is in
`2026-11-17-tables/gate-iteration4.txt`.

Against the baseline the loop began from (45,474 tokens and 10.0 s a question): 37% of the
tokens, 63% of the time, the same answers.

## Iteration 5: what the first call can leave to the tools (2026-11-21)

Iteration 4's sessions, read call by call (1,516 of them): the first call of the model carried
6.2k tokens and the second 8.4k, and 23% of the sessions made a third (8.9k). Three things
followed from that.

- **The shape note is said beside another note, not alone** (`answer.rkt`). 312 of the 329
  third calls were sessions whose answer was written with one note beside it, the query's shape
  set against its kind's example. The note is advisory, so the session went on and the agent
  said it stood by its answer. It fired on 479 first answers of 2,090 and changed none (in
  iteration 3: five of 387, four of them the two-column selects that are held now). Most are
  questions of kinds the train split lacks, rightly answered with another select: 62 of the 424
  validation queries the benchmark itself wrote have the shape of no train query.
- **The `kind` tool looks the names up** (`tables-server.rkt` `names-text`). The first call
  picked a kind and, with `sql`, asked the tables how they write each name the question gives,
  which is what it needed the schema for. `kind` now takes those names and answers each as the
  tables write it: every spelling, by the column that holds it, in the columns the train split's
  queries compare with a name (`query-checks.rkt` `name-columns`: eight); a name no column holds
  exactly is offered the names that hold it and the names it holds as whole words ("nu route"
  holds the route `NU`). The schema (1.9k tokens) left the prompt and comes with the first
  example, read once. The prompt is 6.8k characters where it was 10.0k, and `sql` is called in 1
  session of 100 where it was called in 64.
- **The agents do not inherit the session they are started from** (`run-agent.rkt` `withheld`).
  A session that says one word carried 1,380 tokens before any prompt of ours. They are
  reminders an agent inherits from the hosted session the benchmark is run from (how to attribute
  its commits, where its scratch files go), through three environment variables by which that
  session names itself; with them an agent also reports its events there. Withheld, the same
  session carries 564 tokens and takes 2.0 s where it took 3.3. An agent started from a terminal
  has none of the three, so this is the harness measuring what a user would get.
  `AGENT_BENCH_KEEP_SESSION=1` leaves them in, to measure it.

### What the confirmation found

The look-up took over what the agents' own queries had been showing them, and three questions
that iteration 4 answered were missed on the way. Each was fixed from the train split, and the
confirmation started again.

- **What goes beside a name** (`name-companions`, checks.json `beside`). "Can you tell me if the
  chest tube #1 event has occurred": the look-up said `d_items.label = 'Chest Tube #1'`, the
  agent read the chart events under that label and answered none; the item is an output. Every
  train query that names an item also states `d_items.linksto`, the table its records are in
  (449 of 449), so a name is given with it: `d_items.label = 'Chest Tube #1' AND d_items.linksto
  = 'outputevents'`.
- **A longer name the question spells** (`held-statement`). "… had ostomy (output) since …": the
  agent gave "ostomy", the look-up answered the charted item `Ostomy`, and the count was of the
  wrong table's rows. Beside an exact match the look-up now shows any longer name of the same
  columns that the question's own words spell: `Ostomy (output)`, an output.
- **A word that fixes what is selected** (`said-columns`, checks.json `says`). "What was the name
  of the specimen test that patient … was given for the last time": answered with `test_name`
  where the specimen is asked. This is the one case of the shape note doing its work: it would
  have set `test_name` beside the example's `spec_type_desc`. What the train split says about it
  is narrower and decisive: every train question that says "specimen" (48 of 48) selects
  `microbiologyevents.spec_type_desc`, as "sex" goes with `patients.gender`, "discharged" with
  `admissions.dischtime` and "terms" with `admissions.admission_type` — four words that, in ten
  questions or more, always go with one selected column. A query of such a question that selects
  otherwise is held. The check says nothing of any of the 2,522 train and validation queries.

The container was replaced during the first confirmation; the runs below are on the new machine,
which is faster (iteration 4's code: 5.4 s a question on the 150-question validation sample,
6.0 s on the old one). So iteration 4's code was run again here, and the three are set side by
side on the same 150 questions, one after the other:

| 150 validation questions, one machine | in scope | input tokens | … 90th percentile | output tokens | seconds |
|---|---|---|---|---|---|
| iteration 4's code | 144 of 144 | 16,691 | 23,895 | 485 | 5.4 |
| iteration 5, the session kept | 144 of 144 | 13,399 | 14,147 | 437 | 4.6 |
| iteration 5 | 144 of 144 | 11,547 | 12,344 | 426 | 4.5 |

The toolkit's changes are the first step (a fifth of the tokens, a seventh of the time: no third
call, the schema read once, no `sql` call); the harness's is the second (1.9k tokens a question,
and little time on this machine). The 90th percentile is now close to the median: nearly every
session is the same two calls.

The whole validation split once, then the whole test split three times, all under the final
code:

```
runs 2, questions 424, answers 424
as scored       415 of 424 (97.9%)
set aside       10 questions (set-aside.json): 1 of 10 marked right
in scope        414 of 414 (100.0%) over 414 questions: 414 right every time, 0 missed sometimes, 0 missed every time

a question costs  input tokens: mean 11498, median 11268   turns: mean 3.02   seconds: mean 4.5
citations         precision 0.958   recall 0.969

PASS
```

```
runs 9, questions 409, answers 1227
as scored       1205 of 1227 (98.2%)
set aside       8 questions (set-aside.json): 3 of 24 marked right
in scope        1202 of 1203 (99.9%) over 401 questions: 400 right every time, 0 missed sometimes, 0 missed every time, 1 judged both ways

judged both ways (the same answer marked right in one run and wrong in another: the judge's, no slip):
  40bd0f4265c38c258e1d9e19  right 2 of 3  Has there been any organism found in patient 10021118's last urine microbiological examination in 12/this year…
      answered: no: none on record

a question costs  input tokens: mean 11769, median 11307   turns: mean 3.04   seconds: mean 4.6
citations         precision 0.991   recall 0.993

PASS
```

The one is the benchmark's judge: the query and the answer are, word for word, those of
iteration 4's passes and of this iteration's other two, all marked right.

| the test split, three passes | iteration 4 | iteration 5 |
|---|---|---|
| as scored | 1206 of 1227 | 1205 of 1227 |
| in scope | 1203 of 1203 | 1202 of 1203 (the one the judge's) |
| input tokens a question, mean | 17,038 | **11,769** (−31%) |
| … median | 14,622 | 11,307 |
| … 90th percentile | 24,171 | 12,487 |
| output tokens a question, mean | 486 | 434 |
| seconds a question, mean | 6.3 (another machine; 5.4 on this one, above) | **4.6** |
| … 90th percentile | 8.8 | 6.7 |
| citations: precision, recall | 0.991, 0.990 | 0.991, 0.993 |

The answer given once ends 1,196 of the 1,227 sessions, and `sql` was called in 6 of them. The
gate's output is in `2026-11-17-tables/gate-iteration5.txt`.

Against the baseline the loop began from (45,474 tokens and 10.0 s a question, on the other
machine): 26% of the tokens, the same answers.

## Next in the loop

Read from iteration 5's sessions: the first call of the model carries 3.9k tokens, the second
7.5k, and 3% of the sessions make a third. A question's 4.5 s are, by the sessions' own
timestamps: the first call 1.2 s, the second 1.6 s, the two tools 0.4 s, and 1.2 s around them
(the agent runtime starting, connecting its tool server, and ending).

- **Two calls** is what the arm's design takes: one to pick the kind and give the names, one to
  write the query. What the second call carries beyond the first is the `kind` tool's answer
  (3.5k tokens: the schema, the example, how to write the query, the time phrases the question
  says, the names).
- **The time** is the model's (2.8 s, some 430 tokens written) and the runtime's (1.2 s): a tool
  server that outlives a question would save its start, which is what a person's session has.
- **"no: none on record"** is the one wording the benchmark's judge has marked both ways: three
  times in 882 judgements over every run so far (this iteration's one among them), each time on
  an answer marked right in the other passes. Its judge first asks whether an answer says the
  question cannot be answered; "none: nothing on record", which that step reads as no answer
  nine times in ten, has been marked wrong 0 times in 2,828.
- **The other arms** (the workspace verbs with no tables, MCP, plain REST) have not been run
  since rounds 4 to 6; MedAgentBench's workspace arm pays the two costs iteration 3 removed.
