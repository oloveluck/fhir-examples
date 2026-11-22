The schema (a time is text, `YYYY-MM-DD HH:MM:SS`; an identifier an integer). `subject_id` is the patient, `hadm_id` a hospital admission, `stay_id` a stay in an intensive care unit, `itemid` a test or a charting item:
patients: subject_id, gender (`M` or `F`)
admissions: subject_id, hadm_id, admittime, dischtime (when it began and ended), admission_type (`EW EMER.`, `URGENT`, `ELECTIVE`, …), admission_location (where the patient came from: `EMERGENCY ROOM`, …), marital_status
icustays: hadm_id, stay_id, intime, outtime (when the stay began and ended)
transfers: hadm_id, careunit (the unit the patient was moved to: `Medicine`, …), intime (when the patient arrived there)
d_labitems: itemid, label (a laboratory test's name: `Creatinine`, …)
labevents: hadm_id, itemid, charttime (when the specimen was taken), valuenum (the result as a number)
d_items: itemid, label (an ICU charting item's name: `Respiratory Rate`, `OR Urine`, …), linksto (the table its records are in: `chartevents`, `outputevents`, …)
chartevents: stay_id, itemid, charttime, valuenum (the value as a number)
outputevents: stay_id, itemid, charttime, value (a fluid output's volume, in ml)
prescriptions: hadm_id, drug (the medication's name as prescribed), starttime (when the prescription starts), route (`IV`, `PO`, …), dose_val_rx (the dose, as text)
microbiologyevents: hadm_id, charttime (when the specimen was taken), spec_type_desc (what was sampled: `BLOOD CULTURE`, `URINE`, …), test_name (the test done on it: `URINE CULTURE`, …), org_name (an organism that grew, one row each; empty when none did)
procedures_icd: hadm_id, icd_code, charttime (the day it was done, as `YYYY-MM-DD 00:00:00`)
d_icd_procedures: icd_code, long_title (a procedure code's title)
diagnoses_icd: hadm_id, icd_code
d_icd_diagnoses: icd_code, long_title (a diagnosis code's title)
