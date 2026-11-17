# A note for FHIR-AgentBench's authors: seven test questions whose query looks a label up in lower case

Drafted for the owner to file (an issue at github.com/glee4810/FHIR-AgentBench); not sent.

## What

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

## Why it looks unintended

- Every other query in the file that looks an output's label up — 82 of them, in all three splits,
  among them the 62 of the sibling template "What was the total volume of {output_name} output
  that patient {patient_id} had [time_filter_global1]?" — writes the label as `d_items` has it
  (`'Void'`, `'OR Urine'`, `'Foley'`).
- The template occurs only in the test split (seven questions; none in train or valid), so nothing
  an agent can learn from the other splits says that this kind of question is asked of a label
  that matches nothing.
- An agent that finds the output and reports its yearly, monthly or daily volume is marked wrong,
  and one that reports "nothing found" is marked right.

## What it does to a score

Six questions of the 409 in the test split (1.5%). In our runs the agents answer all six from the
data (for instance `70` for `204b55b1…`) and are marked wrong every time; we report the test split
as scored, and beside it with these seven set aside.

## Suggested fix

Write the label as stored (or compare case-insensitively, `lower(d_items.label) = '…'`) in the
seven queries, and regenerate their `true_answer` and `true_fhir_ids`.
