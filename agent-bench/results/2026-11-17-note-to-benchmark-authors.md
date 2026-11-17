# A note for FHIR-AgentBench's authors: eighteen questions whose recorded answer an agent given the FHIR data cannot reach

Drafted for the owner to file (an issue at github.com/glee4810/FHIR-AgentBench); not sent.

## 1. Seven questions whose query looks a label up in lower case

### What

In `final_dataset/questions_answers_sql_fhir.csv`, the seven test-split questions of the template

> List the [unit_average] [agg_function] volume of {output_name} output that patient {patient_id} had [time_filter_global1].

compare `d_items.label` with the output's name in lower case. MIMIC-IV writes those labels with
capitals (`Void`, `OR Urine`, `Chest Tube #1`), and SQLite's `=` is case-sensitive, so the inner
select finds no item, the query returns no row, `true_answer` is `[]` and `true_fhir_ids` is `{}`.
For six of the seven the patient does have that output in the period asked about.

| question_id | label in `sql_query` | label in `d_items` | the query as written | with the stored label |
|---|---|---|---|---|
| `204b55b1a8a2dbeafa89b76c` | `l pleural #1` | `L Pleural #1` | no row | `70` |
| `3ec03a348a536f8a80e9d54e` | `chest tube #1` | `Chest Tube #1` | no row | `24.347826086956523` |
| `4b72e7b13c37b47053d926d9` | `pre-admission` | `Pre-Admission` | no row | `250` |
| `5c2b95425f850cf9aee654aa` | `stool` | `Stool` | no row | no row |
| `dbf9297a4c1d683faa792fef` | `emesis` | `Emesis` | no row | `100` |
| `ea9a85005a244ffc9f78a09c` | `or urine` | `OR Urine` | no row | `700` |
| `eefb26cc5bd74a549f823166` | `void` | `Void` | no row | `250` |

("With the stored label": the same `sql_query` with only the literal's capitals changed, run on
the MIMIC-IV Clinical Database Demo 2.2 loaded by the repository's `create_db.py`.)

One of them in full (`204b55b1…`): "Retrieve the yearly l pleural #1 output of patient 10009035 …"

```sql
SELECT MAX(outputevents.value) FROM outputevents WHERE outputevents.stay_id IN ( SELECT icustays.stay_id
FROM icustays WHERE icustays.hadm_id IN ( SELECT admissions.hadm_id FROM admissions WHERE
admissions.subject_id = 10009035 ) ) AND outputevents.itemid IN ( SELECT d_items.itemid FROM d_items
WHERE d_items.label = 'l pleural #1' AND d_items.linksto = 'outputevents' ) GROUP BY
strftime('%Y',outputevents.charttime)
```

### Why it looks unintended

- Every other query in the file that looks an output's label up — 82 of them, in all three splits,
  among them the 62 of the sibling template "What was the total volume of {output_name} output
  that patient {patient_id} had [time_filter_global1]?" — writes the label as `d_items` has it
  (`'Void'`, `'OR Urine'`, `'Foley'`).
- The template occurs only in the test split (seven questions; none in train or valid), so nothing
  an agent can learn from the other splits says that this kind of question is asked of a label
  that matches nothing.
- An agent that finds the output and reports its yearly, monthly or daily volume is marked wrong,
  and one that reports "nothing found" is marked right.

### What it does to a score

Six questions of the 409 in the test split (1.5%). In our runs the agents answer all six from the
data (for instance `70` for `204b55b1…`) and are marked wrong every time; we report the test split
as scored, and beside it with these seven set aside. With the labels corrected, five of the six
answers our agents give would be the query's; the sixth (`eefb26cc…`, "the monthly volume of void
… take the minimum") is read by the agents as the smallest monthly total (3075) where the query
takes the smallest single output of each month (250) — the template being absent from the train
split, they have no example of it.

### Suggested fix

Write the label as stored (or compare case-insensitively, `lower(d_items.label) = '…'`) in the
seven queries, and regenerate their `true_answer` and `true_fhir_ids`.

## 2. One question answered from a record dated after its own current time

`7535579b90cfcb61fed1c380`: "What was the organism's name found in the last peritoneal fluid
microbiology test of patient 10021487 since 09/2116?", with the assumption "Assume the current
time is 2116-12-31 23:59:00."

Its `sql_query` bounds the test's time from below only (`strftime('%Y-%m',
microbiologyevents.charttime) >= '2116-09'`), so "the last test" is one charted on 2117-03-23
17:11:00, twelve weeks after the stated current time, and `true_answer` is that test's organisms
(`CLOSTRIDIUM PERFRINGENS`, `BACTEROIDES FRAGILIS GROUP`). The patient's peritoneal fluid rows
with an organism, newest first, in the database `create_db.py` builds:

| charttime | org_name |
|---|---|
| 2117-03-23 17:11:00 | CLOSTRIDIUM PERFRINGENS |
| 2117-03-23 17:11:00 | BACTEROIDES FRAGILIS GROUP |
| 2117-03-03 18:11:00 | BACTEROIDES FRAGILIS GROUP |
| 2117-02-10 14:19:00 | FUSOBACTERIUM SPECIES, BACTEROIDES FRAGILIS GROUP |
| 2117-01-28 02:52:00 | BACTEROIDES FRAGILIS GROUP, PREVOTELLA SPECIES, STREPTOCOCCUS ANGINOSUS (MILLERI) GROUP |

The template is "What was the organism name found in the [time_filter_exact1] {spec_name}
microbiology test of patient {patient_id} [time_filter_global1]?". Its 27 train-split queries
with a "since" filter all end at the current time as well (`AND
strftime('%Y-%m-%d',microbiologyevents.charttime) <= '2142-12-31 23:59:00'`); its 3
validation-split and 2 test-split ones do not. An agent that follows the train split's form
answers from the last test on or before the current time (`BACTEROIDES FRAGILIS GROUP`,
`PORPHYROMONAS SPECIES`) and is marked wrong.

Suggested fix: add the upper bound to the five queries, as the train split's have it, and
regenerate their `true_answer` and `true_fhir_ids`.

## 3. Six validation questions with the same lower-case label, in a lab template

The validation split's template "List the [unit_average] [agg_function] {lab_name} lab value of
patient {patient_id} [time_filter_global1]." (seven questions, in no other split) compares
`d_labitems.label` with the lab's name in lower case in six of its seven queries; the seventh
writes `'Protein, Total'` and returns a value. The 874 other look-ups of a lab's label in the file
write it as stored.

| question_id | label in `sql_query` | label in `d_labitems` | the query as written | with the stored label |
|---|---|---|---|---|
| `249619a43d4c7fe7add673f1` | `lactate dehydrogenase (ld)` | `Lactate Dehydrogenase (LD)` | no row | `282` |
| `4ea43bff9e1b8d9f142a816d` | `mcv` | `MCV` | no row | `91` |
| `7a60c2c50fa3345765a83271` | `lipase` | `Lipase` | no row | `21` |
| `abd48dc45ba90022382e02c9` | `creatinine, urine` | `Creatinine, Urine` | no row | `42` |
| `acc9bade197c3728c67fcdd7` | `bilirubin, direct` | `Bilirubin, Direct` | no row | no row |
| `b9c136c1e1d19649caabdeb4` | `bilirubin, direct` | `Bilirubin, Direct` | no row | `5.4` |

Same cause and the same fix as section 1.

## 4. Four validation questions answered from values the FHIR export does not carry

These are marked `mappable_to_fhir`, and their queries are sound; the value the answer is read
from is in the relational `prescriptions` table and not in the MIMIC-IV on FHIR export the agents
are given.

| question_id | read from `prescriptions` | what the MedicationRequest has |
|---|---|---|
| `28fd166cd9efc2ab844c870d` | the order that starts last, `starttime` 2167-05-11 20:00:00 (dose 50) | `authoredOn` 2167-05-11T08:48:43, no `dispenseRequest.validityPeriod`: by the export's times another order (dose 25, 09:00) is last |
| `9ff61e95883c730111d063bb` | `starttime` 2155-12-02 22:00:00 | `authoredOn` 2155-12-02T21:20:57, no `validityPeriod` |
| `bf8aee434927ad78efbb9c37` | `starttime` 2200-09-28 20:00:00 | tables defined over the export read 2200-09-28 11:00:00 |
| `652c13b3ffbd655d3934525f` | `dose_val_rx` `'5-10'`, which `SUM` reads as 5 (total 10) | `dosageInstruction` with no `doseAndRate` (total 5) |

In the first two the relational row's `stoptime` is earlier than its `starttime`, and the export
leaves the period out. Held to the relational table row for row, tables defined over the export
differ in 3,534 of its 18,087 prescription rows for these two reasons; 20 train-split queries are
affected the same way, and no test-split query.

Suggested fix: mark these questions as not mappable, or carry the scheduled start and the dose
range into the export.
