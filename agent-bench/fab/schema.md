# The relational schema FHIR-AgentBench's answers are defined over

The benchmark's questions were written as SQL over the MIMIC-IV hospital database (through EHRSQL),
and its answers are what that SQL returns. These are the tables and columns its 2,931 queries read,
with MIMIC-IV's own meaning for each. The same data, exported as FHIR by the MIMIC team, is what an
agent is given; nothing here says where a column is in FHIR.

Conventions of the database: an identifier is an integer; a time is text, `YYYY-MM-DD HH:MM:SS`, on
the hospital's own clock; a name (`label`, `drug`, `careunit`, …) is written exactly as MIMIC writes
it, capitals and all.

| table | column | meaning |
|---|---|---|
| `patients` | `subject_id` | the patient's number |
| | `gender` | `M` or `F` |
| `admissions` | `subject_id`, `hadm_id` | the patient, and the number of this hospital admission |
| | `admittime`, `dischtime` | when the admission began and ended |
| | `admission_type` | MIMIC's kind of admission: `EW EMER.`, `URGENT`, `ELECTIVE`, `SURGICAL SAME DAY ADMISSION`, `OBSERVATION ADMIT`, `EU OBSERVATION`, `AMBULATORY OBSERVATION`, `DIRECT EMER.`, `DIRECT OBSERVATION` |
| | `admission_location` | where the patient came from: `EMERGENCY ROOM`, `PHYSICIAN REFERRAL`, `TRANSFER FROM HOSPITAL`, … |
| | `marital_status` | `MARRIED`, `SINGLE`, `WIDOWED`, `DIVORCED` |
| `icustays` | `hadm_id`, `stay_id` | the admission, and the number of this stay in an intensive care unit |
| | `intime`, `outtime` | when the ICU stay began and ended |
| `transfers` | `hadm_id` | the admission |
| | `careunit` | the unit the patient was moved to: `Medicine`, `Emergency Department`, `Medical/Surgical Intensive Care Unit (MICU/SICU)`, … |
| | `intime` | when the patient arrived there |
| `d_labitems` | `itemid`, `label` | a laboratory test's number and name: `Creatinine`, `Hemoglobin`, … |
| `labevents` | `hadm_id` | the admission the result belongs to (empty for a result taken outside one) |
| | `itemid` | the test, as in `d_labitems` |
| | `charttime` | when the specimen was taken |
| | `valuenum` | the result as a number |
| `d_items` | `itemid`, `label` | an ICU charting item's number and name: `Respiratory Rate`, `OR Urine`, … |
| | `linksto` | the table its records are in: `chartevents`, `outputevents`, `inputevents`, … |
| `chartevents` | `stay_id` | the ICU stay |
| | `itemid` | the item, as in `d_items` |
| | `charttime` | when it was charted |
| | `valuenum` | the value as a number |
| `outputevents` | `stay_id`, `itemid`, `charttime` | as in `chartevents`: a fluid output during an ICU stay |
| | `value` | the volume, in ml |
| `prescriptions` | `hadm_id` | the admission |
| | `drug` | the medication's name as prescribed: `Heparin`, `Sodium Chloride 0.9%  Flush`, … |
| | `starttime` | when the prescription starts |
| | `route` | `IV`, `PO`, `PO/NG`, `IV DRIP`, … |
| | `dose_val_rx` | the dose, as text |
| `microbiologyevents` | `hadm_id` | the admission (empty for a culture taken outside one) |
| | `charttime` | when the specimen was taken |
| | `spec_type_desc` | what was sampled: `BLOOD CULTURE`, `URINE`, `MRSA SCREEN`, … |
| | `test_name` | the test done on it: `URINE CULTURE`, `Blood Culture, Routine`, … |
| | `org_name` | an organism that grew (empty when none did); one row per organism |
| `procedures_icd` | `hadm_id` | the admission |
| | `icd_code` | the procedure's ICD code |
| | `charttime` | the day it was done, as `YYYY-MM-DD 00:00:00` |
| `d_icd_procedures` | `icd_code`, `long_title` | an ICD procedure code and its title |
| `diagnoses_icd` | `hadm_id`, `icd_code` | a diagnosis coded for the admission |
| `d_icd_diagnoses` | `icd_code`, `long_title` | an ICD diagnosis code and its title |

`check-tables.rkt` asks a workspace the benchmark's own queries and compares the answers.
