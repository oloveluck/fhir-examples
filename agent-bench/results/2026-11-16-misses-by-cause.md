# The remaining misses, by cause (2026-11-16)

Every miss of the workspace arm's latest runs, read against what decides it: for FHIR-AgentBench
(round 5: 120 of 150) the benchmark's reference SQL (`questions_answers_sql_fhir.csv`, `sql_query`)
and the records in the store; for MedAgentBench (round 4: 297 of 300) its grader (`refsol.py`) and
the payloads posted. Ids are the question ids' first eight characters.

## FHIR-AgentBench: 30

| cause | misses | whose |
|---|---|---|
| The reference SQL reads fewer records than the question's words cover, or none | 12 | the benchmark's |
| The fact is not in the FHIR data | 2 | the data's |
| A convention of the benchmark an agent could be told | 6 | a choice |
| The agent's mistake | 9 | ours to make harder |
| A defect of this toolkit | 1 | ours |

**The reference SQL reads fewer records, or none (12).** The agent's answer is what the data says.
- A label compared in the wrong case: `d_items.label = 'chest tube #1'` and `= 'emesis'` match no
  row (the labels are `Chest Tube #1`, `Emesis`), so the truth is "no answer"; the store holds 23
  chest tube outputs on 2118-11-16/17 and one emesis of 100 ml, which the agents reported
  (3ec03a34, dbf9297a).
- Only records linked to an admission (`hadm_id IN admissions`): the first creatinine of 05/2180 is
  on 05-06 22:25 with no encounter, the truth is the next one (44ba2f35); the last specimen test is
  a urine culture with no encounter, the truth the blood culture before it (f08654b0); the last
  microbiology test of the "last hospital visit" was taken in the emergency department the day
  before admission (552b047a).
- Only one source table: respiratory rate from the ICU chart where an emergency-department vital
  sign is earlier (672d81cd); "a procedure" as the ICD-coded ones only (8a165a89).
- "This hospital stay" as `dischtime IS NULL`, which no admission in the data is, with a "current
  time" the stay in fact spans: patient 10018081 is in hospital from 2133-12-18 to 2134-01-12 and
  "now" is 2133-12-31 (2cd96b35, dd025c27, 6f8551a8); patient 10039831 from 2115-12-28 to
  2116-01-02, "now" 2115-12-31 (6336898e, c5d97a3f). The truth is "no answer"; the agents answered
  for the stay the patient was in.

**Not in the FHIR data (2).** The admission type (`SURGICAL SAME DAY ADMISSION`, `EU OBSERVATION`)
is MIMIC's string; the FHIR Encounter carries the class it was mapped to (`short stay`,
`observation encounter`), which is what the agents answered (fc9a1a57, bba49bd7).

**A convention an agent could be told (6).**
- "Prescribed" means when the prescription starts (`prescriptions.starttime`, in FHIR
  `dispenseRequest.validityPeriod.start`), not when it was written (`authoredOn`), which the
  agents gave or ordered by (3c3a60ef, feaa4517, ed91e258, 97f99846).
- "The organism found in the last test" means the last test that found one, and every organism
  recorded at that time (ac9de430, 7535579b — the second not checked record by record).

**The agent's mistake (9).**
- A "current stay" answered though the stay had ended before the stated time: patient 10004733's
  stay ended 2174-12-27 and "now" is 2174-12-31 (26fba968, 5cf885d1, 0e4bb227, d69a4b8b,
  ee06998b); patient 10021487's ended 2116-12-28 (1436276f). `describe … as=summary asof=` says no
  encounter was open; the agents answered for the last one.
- "Today" not applied (0b519b39); a prescription from 2186 given with "now" in 2183 (7b7f155a);
  "or urine output" read as all urine, where the item is `OR Urine` (10396305; right in round 4).

**A defect of this toolkit (1).** A search date with no time zone (`date=2116-12-17`,
`date=ge2116-12-17&date=lt2116-12-18`) is compared as a UTC day: over data written at `-05:00` it
answered 2116-12-16 19:00 to 2116-12-17 18:00 local, so the day's last respiratory rate, at 23:52,
was not there and the agent gave 18:00 (3173d5e9). A date as a person writes it should be the day
as the record wrote it.

## MedAgentBench: 3

task5_21, task5_25 and task9_3 are the only tasks of their kinds where the value calls for an
order. Each agent posted the order with `route` as `{"text": "IV"}` (`"oral"`), which is what the
benchmark's own function description says and what FHIR defines; the grader compares
`dosageInstruction[0].route` with the bare string. Every arm misses the same three. (The MCP
arm's ten task8 misses are the same kind: `note` as a list of Annotations, which FHIR defines,
where the grader reads an object.)

## What passing would take

- 14 of the 30 (and the 3) cannot pass without answering against the data or against FHIR: an
  agent would have to know that the reference query matched no label, linked only admitted
  records, or called an open stay closed.
- 6 pass if the agent is told the benchmark's two conventions. That is knowledge of this dataset,
  of the kind a site writes down; it must then be measured on questions it was not read from.
- 10 are worth fixing whatever the benchmark says: the date-only search, and tools and a card that
  make "no stay was open then", "nothing after the current time" and "today" hard to miss.
So the ceiling that means something is about 130 of 150 (the 120 now, plus those 10), or 136 with
the conventions; two runs of the same code differ by about two.

## Done since

The first two of those ten kinds are built (fhir 41ec5f4; `2026-11-16-round4.md`, round 6): the
date-only search, and a summary and a card that say what follows from a question being asked at a
time. Six of the ten questions are now answered as the reference expects, in each of three runs;
round 6 as a whole is 122 of 150.

