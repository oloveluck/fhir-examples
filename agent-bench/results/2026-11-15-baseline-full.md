## MedAgentBench

| arm | correct | cost | input tokens / task | agent time / task |
|---|---|---|---|---|
| official-hapi | 212/300 (70.7%) | $30.65 | — | — |
| official-ours | 226/300 (75.3%) | $27.34 | — | — |
| rest-hapi | 297/300 (99.0%) | $23.14 | 143k | 8 s |
| rest-ours | 295/300 (98.3%) | $22.02 | 139k | 8 s |
| workspace | 291/300 (97.0%) | $23.26 | 169k | 11 s |

| task kind | official-hapi | official-ours | rest-hapi | rest-ours | workspace |
|---|---|---|---|---|---|
| task1 | 30/30 | 23/30 | 30/30 | 30/30 | 30/30 |
| task2 | 0/30 | 0/30 | 30/30 | 30/30 | 30/30 |
| task3 | 30/30 | 28/30 | 30/30 | 30/30 | 29/30 |
| task4 | 30/30 | 30/30 | 30/30 | 29/30 | 30/30 |
| task5 | 16/30 | 23/30 | 28/30 | 28/30 | 28/30 |
| task6 | 24/30 | 23/30 | 30/30 | 30/30 | 30/30 |
| task7 | 26/30 | 22/30 | 30/30 | 29/30 | 25/30 |
| task8 | 30/30 | 30/30 | 30/30 | 30/30 | 30/30 |
| task9 | 2/30 | 20/30 | 29/30 | 29/30 | 29/30 |
| task10 | 24/30 | 27/30 | 30/30 | 30/30 | 30/30 |

- official-hapi misses (88): task10_13, task10_18, task10_19, task10_21, task10_25, task10_9, task2_1, task2_10, task2_11, task2_12, task2_13, task2_14, task2_15, task2_16, task2_17, task2_18, task2_19, task2_2, task2_20, task2_21, task2_22, task2_23, task2_24, task2_25, task2_26, task2_27, task2_28, task2_29, task2_3, task2_30, task2_4, task2_5, task2_6, task2_7, task2_8, task2_9, task5_10, task5_11, task5_14, task5_16, task5_17, task5_18, task5_19, task5_21, task5_25, task5_27, task5_28, task5_3, task5_6, task5_7, task6_10, task6_12, task6_13, task6_25, task6_27, task6_4, task7_11, task7_12, task7_15, task7_20, task9_1, task9_10, task9_11, task9_12, task9_13, task9_14, task9_15, task9_16, task9_17, task9_18, task9_19, task9_2, task9_20, task9_21, task9_22, task9_23, task9_24, task9_25, task9_26, task9_27, task9_28, task9_29, task9_3, task9_30, task9_4, task9_5, task9_7, task9_9
- official-ours misses (74): task10_14, task10_20, task10_24, task1_12, task1_17, task1_2, task1_22, task1_25, task1_27, task1_4, task2_1, task2_10, task2_11, task2_12, task2_13, task2_14, task2_15, task2_16, task2_17, task2_18, task2_19, task2_2, task2_20, task2_21, task2_22, task2_23, task2_24, task2_25, task2_26, task2_27, task2_28, task2_29, task2_3, task2_30, task2_4, task2_5, task2_6, task2_7, task2_8, task2_9, task3_10, task3_23, task5_14, task5_18, task5_21, task5_25, task5_27, task5_28, task5_6, task6_10, task6_12, task6_20, task6_25, task6_27, task6_4, task6_7, task7_11, task7_15, task7_16, task7_20, task7_23, task7_27, task7_29, task7_3, task9_10, task9_15, task9_17, task9_22, task9_24, task9_26, task9_27, task9_29, task9_3, task9_8
- rest-hapi misses (3): task5_21, task5_25, task9_3
- rest-ours misses (5): task4_1, task5_21, task5_25, task7_16, task9_3
- workspace misses (9): task3_20, task5_21, task5_25, task7_10, task7_15, task7_16, task7_26, task7_4, task9_3

## FHIR-AgentBench

| arm | correct | retrieval precision | retrieval recall | cost | input tokens / q | agent time / q |
|---|---|---|---|---|---|---|
| rest | 113/150 (75.3%) | 0.81 | 0.74 | $16.46 | 279k | 20 s |
| workspace | 117/150 (78.0%) | 0.88 | 0.77 | $19.02 | 342k | 27 s |

### rest misses (37)
- `2e8d527a` What was the name of the specimen test that was first given to patient 10007795 in the first hospital visit?  
  truth: [['BLOOD CULTURE']]  ·  answer: Blood specimen collected 2136-04-11 05:19 (first of the first stay, Encounter 3bea8715, 2136-04-10 to 05-02). Three blood specimens were drawn at that same minu
- `fcb5ab40` Give me the details of the time patient 10020740 was admitted to the hospital in 2150.  
  truth: [['2150-03-11 15:34:00']
 ['2150-06-03 20:12:00']
 ['2150-09-15 14:09:00']
 ['2150-07-09 22:09:00']]  ·  answer: Two inpatient hospital admissions in 2150. (1) Admitted 2150-03-11 15:34 (transfer from hospital, urgent, MED service; hosp. stay 23831430, with ICU stays withi
- `b9c136c1` What is patient 10021487's monthly bilirubin, direct levels since 05/2116? if multiple bilirubin, direct levels are measured monthly, take the average.  
  truth: no answer  ·  answer: 2116-12: 5.4 mg/dL (only month with direct bilirubin from 05/2116 to 12/2116; the 2116-12-07 lab and chart values are both 5.4)
- `92d6c5d8` When was patient 10021487 first prescribed the drug heparin in 12/this year?  
  truth: [['2116-12-05 14:00:00']]  ·  answer: 2116-12-05 10:58:32
- `199101dc` When was the last time a drug was prescribed to patient 10013049 since 02/2114?  
  truth: [['2114-06-22 20:00:00']]  ·  answer: 2114-06-22 17:25:48 (-04:00)
- `b037cad3` How many days have passed since patient 10018081 received a basophils laboratory test for the first time during this hospital encounter?  
  truth: no answer  ·  answer: 13 days (first basophils test 2133-12-18 17:28; 13 days 6.5 h before 2133-12-31 23:59)
- `0184b4b1` When was patient 10001217 prescribed medication via the po/ng route, for the first time in 12/this year?  
  truth: [['2157-12-18 19:00:00']]  ·  answer: 2157-12-18 18:01:35
- `05a8454a` Has patient 10004733 got a central venous catheter placement with guidance treatment during this hospital visit?  
  truth: no answer  ·  answer: Yes. Central venous catheter placement with guidance (ICD-9 3897) was recorded on 2174-12-07, during the hospital stay of 2174-12-04 to 2174-12-12.
- `2322a6ff` How many hours have elapsed since the first time patient 10021487 stayed in careunit med/surg/trauma during this hospital encounter?  
  truth: no answer  ·  answer: 318.42 hours (first Med/Surg/Trauma stay began 2116-12-18 17:34:03; 13 days 6 h 25 min before 2116-12-31 23:59)
- `b52f4e22` When is the first time patient 10004235 has had the maximum diastolic blood pressure during their last icu stay?  
  truth: [['2196-02-25 21:00:00']]  ·  answer: 2196-02-25 20:40 (-05:00); maximum diastolic ABP 92 mmHg during the last (only) ICU stay
- `ac19aaff` Is glucose in patient 10021487 last measured on the current hospital visit less than the second to last value measured on the current hospital visit?  
  truth: no answer  ·  answer: No. The last glucose (106 mg/dL, 2117-12-05 06:25) is not less than the second-to-last (102 mg/dL, 2117-12-04 05:55); it is higher. Caveat: every encounter on r
- `49428279` Since 05/2114, when was the first microbiology test conducted for patient 10013049?  
  truth: [['2114-06-20 11:09:00']]  ·  answer: 2114-06-18 13:30:00
- `81a5e456` What was the total number of unique drugs prescribed to patient 10009628 in 09/this year?  
  truth: [[58]]  ·  answer: 72
- `a08cb35b` What number of hours have elapsed since patient 10039831 was admitted to the icu?  
  truth: no answer  ·  answer: 76.4 hours (ICU admission 2115-12-28 19:36:43 to 2115-12-31 23:59:00; the ICU stay itself ended 2115-12-30 16:31:48)
- `2d7404fc` What was the name of the specimen test that patient 10011398 got the first on their last hospital visit?  
  truth: [['MRSA SCREEN']]  ·  answer: Blood (specimen collected 2146-12-15 07:52, first of the stay; blood-gas/chemistry panel: pH, pCO2, pO2, lactate, electrolytes, glucose, hemoglobin, etc.)
- `2001cff6` Has there been any organism found since 09/2155 in the first blood culture microbiology test of patient 10010471?  
  truth: no answer  ·  answer: Yes - STAPHYLOCOCCUS, COAGULASE NEGATIVE (first blood culture since 09/2155, collected 2155-12-02 17:30)
- `3290627f` Compute the number of times patient 10018081 was prescribed 5% dextrose in 12/this year.  
  truth: [[11]]  ·  answer: 4
- `a8802819` During the last hospital encounter, when was the last staph aureus swab microbiology test for patient 10005817?  
  truth: no answer  ·  answer: 2135-01-08T15:30:00-05:00 (MRSA screen swab, grew STAPH AUREUS COAG +; during the 2135-01-03 to 2135-01-19 admission)
- `d535c91e` Count the number of times that patient 10018845 received a laboratory test for hemoglobin since 07/2184.  
  truth: [[2]]  ·  answer: 4
- `d2063048` What was the first time that patient 10037928 had the maximum amount of chloride since 04/2175?  
  truth: [['2175-10-25 23:49:00']]  ·  answer: 2175-09-28 15:27:00 (chloride 104 mEq/L, the maximum since 04/2175)
- `7a60c2c5` What is the monthly level of patient 10038999's lipase in 2131? if multiple lipase levels are measured monthly, take the minimum.  
  truth: no answer  ·  answer: May 2131: 21 IU/L (only lipase measurement in 2131, 2131-05-23 04:54)
- `9ff61e95` When patient 10010471 was prescribed 5% dextrose for the first time since 10/2155?  
  truth: [['2155-12-02 22:00:00']]  ·  answer: 2155-12-02 21:20:57 (-05:00) — heparin premix in 5% Dextrose base
- `36178f6b` Did patient 10007795 go through any procedures during the last year?  
  truth: no answer  ·  answer: Yes — 28 procedures were recorded in 2136, including endoscopy of small intestine (2136-04-13, 04-17), percutaneous abdominal drainage (04-19), drainage of panc
- `e7683297` How many days has it been since patient 10021487 had received a po2 lab test for the first time during this hospital visit?  
  truth: no answer  ·  answer: 28 days (first pO2 lab 2116-12-03 01:29; about 28.9 days before 2116-12-31 23:59)
- `9db8bd8e` When was the first time in 10/2115 patient 10038081 was prescribed a drug via the neb route?  
  truth: [['2115-10-03 09:00:00']]  ·  answer: 2115-10-03 08:06:09
- `43896dd8` How many days have elapsed since the last time patient 10039831 stayed in careunit discharge lounge in their current hospital encounter?  
  truth: no answer  ·  answer: 3 days (last Discharge Lounge stay ended 2115-12-28 19:36:43; about 3.18 days elapsed)
- `ec946af2` What was the maximum spo2 of patient 10019568?  
  truth: [[99.]]  ·  answer: 100 % (maximum SpO2, recorded at 2120-01-30T23:04 and again 2120-01-31T08:00)
- `34c6a8ee` What is the last value of patient 10004422's respiratory rate on 01/22/this year?  
  truth: [[15.]]  ·  answer: 19 insp/min (2111-01-22 18:00)
- `885642fd` Since 04/2110, when was the last microbiology test conducted for patient 10001725?  
  truth: [['2110-04-14 12:37:00']]  ·  answer: 2110-10-18 12:00 (-04:00)
- `652c13b3` How much oxycodone (immediate release) dose was prescribed to patient 10020187?  
  truth: [[10.]]  ·  answer: 5 mg
- `ba5d2c36` How many distinct drugs were prescribed to patient 10000032 since 10 months ago?  
  truth: [[32]]  ·  answer: 37
- `12c4448b` Since patient 10039831's admission to the icu, how many days have passed?  
  truth: no answer  ·  answer: 3 days (about 3.18 days; ICU admission 2115-12-28 19:36:43 to 2115-12-31 23:59:00)
- `9720cb4a` Tell me the first specimen test given to patient 10022281 in 06/2125?  
  truth: [['MRSA SCREEN']]  ·  answer: Urine specimen test, collected 2125-06-16 23:30
- `272b7419` How many times in 07/this year does patient 10002428 receive a bicarbonate test?  
  truth: [[1]]  ·  answer: 2
- `4ea43bff` Can you list patient 10021118's yearly mcv since 10/2161? if multiple mcv are measured yearly, take the minimum.  
  truth: no answer  ·  answer: 2161: 91 fL (minimum of 8 MCV results, 11/2161)
- `42a6e5d9` What was patient 10027602's last prescribed time for bisacodyl during this month?  
  truth: [['2201-12-11 21:00:00']]  ·  answer: 2201-12-11 20:15:47
- `c06d5f1b` For the first time since 01/2125, when was patient 10014729 prescribed a drug?  
  truth: [['2125-02-27 08:00:00']]  ·  answer: 2125-02-27 16:30:43 (-05:00)

### workspace misses (33)
- `2e8d527a` What was the name of the specimen test that was first given to patient 10007795 in the first hospital visit?  
  truth: [['BLOOD CULTURE']]  ·  answer: Blood (blood specimen, collected 2136-04-11T05:19:00-04:00 during the first hospital stay)
- `b9c136c1` What is patient 10021487's monthly bilirubin, direct levels since 05/2116? if multiple bilirubin, direct levels are measured monthly, take the average.  
  truth: no answer  ·  answer: 2116-12: 5.4 mg/dL (the only direct bilirubin in 05/2116–12/2116; no other months have values)
- `92d6c5d8` When was patient 10021487 first prescribed the drug heparin in 12/this year?  
  truth: [['2116-12-05 14:00:00']]  ·  answer: 2116-12-05T10:58:32-05:00
- `199101dc` When was the last time a drug was prescribed to patient 10013049 since 02/2114?  
  truth: [['2114-06-22 20:00:00']]  ·  answer: 2114-06-22T17:25:48-04:00
- `b037cad3` How many days have passed since patient 10018081 received a basophils laboratory test for the first time during this hospital encounter?  
  truth: no answer  ·  answer: 13 days (first basophils test 2133-12-18 17:28 during hospital encounter 21027282; 13 days 6 h 31 min before 2133-12-31 23:59)
- `0184b4b1` When was patient 10001217 prescribed medication via the po/ng route, for the first time in 12/this year?  
  truth: [['2157-12-18 19:00:00']]  ·  answer: 2157-12-18T18:01:35-05:00
- `05a8454a` Has patient 10004733 got a central venous catheter placement with guidance treatment during this hospital visit?  
  truth: no answer  ·  answer: Yes - central venous catheter placement with guidance (ICD-9 38.97) was performed on 2174-12-07 during the hospital stay (Encounter 27411876), status completed.
- `2322a6ff` How many hours have elapsed since the first time patient 10021487 stayed in careunit med/surg/trauma during this hospital encounter?  
  truth: no answer  ·  answer: ≈318.4 hours (318 h 25 min) since the first med/surg/trauma stay began at 2116-12-18 17:34:03
- `ac19aaff` Is glucose in patient 10021487 last measured on the current hospital visit less than the second to last value measured on the current hospital visit?  
  truth: no answer  ·  answer: No. Last glucose 106 mg/dL (2117-12-05T06:25-05:00) is not less than the second-to-last 102 mg/dL (2117-12-04T05:55-05:00) on the current hospital visit (encoun
- `49428279` Since 05/2114, when was the first microbiology test conducted for patient 10013049?  
  truth: [['2114-06-20 11:09:00']]  ·  answer: 2114-06-18 13:30 (-04:00)
- `c68bc6d5` What microbiology test was given to patient 10004235 for the first time during the first hospital encounter?  
  truth: [['MRSA SCREEN']]  ·  answer: Blood Culture, Routine (blood culture specimen collected 2196-02-24T12:40, in the ED part of the first hospital encounter 24181354)
- `bbef3c6d` What organism was found in patient 10016742's last sputum microbiology test since 08/2178?  
  truth: no answer  ·  answer: Acinetobacter baumannii and Stenotrophomonas maltophilia (sputum respiratory culture collected 2178-07-13 20:30)
- `81a5e456` What was the total number of unique drugs prescribed to patient 10009628 in 09/this year?  
  truth: [[58]]  ·  answer: 44
- `a08cb35b` What number of hours have elapsed since patient 10039831 was admitted to the icu?  
  truth: no answer  ·  answer: 76.37 hours (ICU admission 2115-12-28 19:36:43; 3 days 4 h 22 min before 2115-12-31 23:59:00)
- `2001cff6` Has there been any organism found since 09/2155 in the first blood culture microbiology test of patient 10010471?  
  truth: no answer  ·  answer: Yes - STAPHYLOCOCCUS, COAGULASE NEGATIVE (first blood culture since 09/2155, 2155-12-02 17:30)
- `3290627f` Compute the number of times patient 10018081 was prescribed 5% dextrose in 12/this year.  
  truth: [[11]]  ·  answer: 4
- `d535c91e` Count the number of times that patient 10018845 received a laboratory test for hemoglobin since 07/2184.  
  truth: [[2]]  ·  answer: 3
- `d2063048` What was the first time that patient 10037928 had the maximum amount of chloride since 04/2175?  
  truth: [['2175-10-25 23:49:00']]  ·  answer: 2175-09-28T15:27:00-04:00 (chloride 104 mEq/L, the maximum between 2175-04 and 2175-12-31)
- `7a60c2c5` What is the monthly level of patient 10038999's lipase in 2131? if multiple lipase levels are measured monthly, take the minimum.  
  truth: no answer  ·  answer: 2131-05: 21 IU/L (only month in 2131 with a lipase result; single measurement on 2131-05-23 04:54)
- `9ff61e95` When patient 10010471 was prescribed 5% dextrose for the first time since 10/2155?  
  truth: [['2155-12-02 22:00:00']]  ·  answer: 2155-12-02 21:20:57 (-05:00) — heparin premix in 5% dextrose, MedicationRequest 8419626b (250 mL IV)
- `36178f6b` Did patient 10007795 go through any procedures during the last year?  
  truth: no answer  ·  answer: Yes — 28 procedures recorded between 2136-04-11 and 2136-09-22 (all within the last year), e.g. central venous catheter placement, drainage of pancreatic cyst b
- `e7683297` How many days has it been since patient 10021487 had received a po2 lab test for the first time during this hospital visit?  
  truth: no answer  ·  answer: 28 days (first pO2 lab 2116-12-03 01:29, about 28.9 days before 2116-12-31 23:59)
- `9db8bd8e` When was the first time in 10/2115 patient 10038081 was prescribed a drug via the neb route?  
  truth: [['2115-10-03 09:00:00']]  ·  answer: 2115-10-03T08:06:09-04:00
- `43896dd8` How many days have elapsed since the last time patient 10039831 stayed in careunit discharge lounge in their current hospital encounter?  
  truth: no answer  ·  answer: 3 days (about 3.18 days; the Discharge Lounge stay ended 2115-12-28 19:36:43, and 2115-12-31 23:59:00 is 3 d 4 h 22 min later)
- `db9cfb9f` What was the name of the drug, which was prescribed to patient 10022041 last on the first hospital stay?  
  truth: [['Thiamine']
 ['OxycoDONE (Immediate Release) ']]  ·  answer: OxycoDONE (Immediate Release) (tied: Thiamine was ordered at the same timestamp, 2187-05-23T08:40:08-04:00)
- `885642fd` Since 04/2110, when was the last microbiology test conducted for patient 10001725?  
  truth: [['2110-04-14 12:37:00']]  ·  answer: 2110-10-18 12:00 (-04:00), a SWAB microbiology specimen
- `ba5d2c36` How many distinct drugs were prescribed to patient 10000032 since 10 months ago?  
  truth: [[32]]  ·  answer: 36
- `12c4448b` Since patient 10039831's admission to the icu, how many days have passed?  
  truth: no answer  ·  answer: 3 days (about 3.18 days: ICU admission 2115-12-28 19:36:43 to 2115-12-31 23:59:00 = 3 days 4 h 22 min)
- `9720cb4a` Tell me the first specimen test given to patient 10022281 in 06/2125?  
  truth: [['MRSA SCREEN']]  ·  answer: Urine specimen, collected 2125-06-16 23:30 (-04:00)
- `272b7419` How many times in 07/this year does patient 10002428 receive a bicarbonate test?  
  truth: [[1]]  ·  answer: 2
- `4ea43bff` Can you list patient 10021118's yearly mcv since 10/2161? if multiple mcv are measured yearly, take the minimum.  
  truth: no answer  ·  answer: 2161: 91 fL (minimum of 8 MCV measurements, Nov 2161)
- `42a6e5d9` What was patient 10027602's last prescribed time for bisacodyl during this month?  
  truth: [['2201-12-11 21:00:00']]  ·  answer: 2201-12-11T20:15:47-05:00
- `c06d5f1b` For the first time since 01/2125, when was patient 10014729 prescribed a drug?  
  truth: [['2125-02-27 08:00:00']]  ·  answer: 2125-02-27T16:30:43-05:00

