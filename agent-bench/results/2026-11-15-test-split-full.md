## FHIR-AgentBench

| arm | correct | retrieval precision | retrieval recall | cost | input tokens / q | agent time / q |
|---|---|---|---|---|---|---|
| mcp | 117/150 (78.0%) | 0.88 | 0.81 | $8.45 | 85k | 17 s |
| rest | 110/150 (73.3%) | 0.77 | 0.74 | $8.4 | 69k | 18 s |
| workspace | 118/150 (78.7%) | 0.88 | 0.81 | $6.97 | 59k | 19 s |

### mcp misses (33)
- `26fba968` How many hours have elapsed since the last time patient 10004733 on this hospital stay received a lab test for lactate dehydrogenase (ld)?  
  truth: no answer  ·  answer: about 330.8 hours (last LD 228 IU/L at 2174-12-18 05:10)
- `3c3a60ef` When was patient 10008287 prescribed for the last time a medication via the pr route since 08/2145?  
  truth: [['2145-10-01 14:00:00']]  ·  answer: 2145-10-01T13:10:49-04:00
- `5cf885d1` How many hours have passed since patient 10004733's last stay in careunit medical/surgical intensive care unit (micu/sicu) in this hospital encounter?  
  truth: no answer  ·  answer: 459.93 hours (last MICU/SICU stay ended 2174-12-12 20:03:01)
- `552b047a` When did patient 10039708 receive his last microbiology test during the last hospital visit?  
  truth: no answer  ·  answer: 2144-01-18T15:45:00-05:00 (URINE CULTURE, no growth; during the ED phase of the Jan 2144 admission, hosp encounter 29488258)
- `0e4bb227` When did patient 10004733 first have the minimum number of specific gravity on the current hospital visit?  
  truth: no answer  ·  answer: 2174-12-13T11:03:00-05:00 (minimum specific gravity 1.017)
- `3ec03a34` Please list the yearly volume of chest tube #1 that was output by patient 10019172 since 09/2118. if multiple chest tube #1 volumes are measured yearly, take the average.  
  truth: no answer  ·  answer: 2118: 24.35 ml (average of 23 chest tube #1 outputs, total 560 ml)
- `ac9de430` What was the organism found in the last urine microbiology test for patient 10038081?  
  truth: [['YEAST']]  ·  answer: MIXED BACTERIAL FLORA (>= 3 colony types), consistent with skin and/or genital contamination (urine culture 2115-10-04T01:28, no specific organism identified)
- `0b519b39` Today, when was the first time that patient 10018081 had the minimum spo2?  
  truth: [['2133-12-31 02:00:00']]  ·  answer: 2133-12-20 13:50:00 (-05:00); minimum SpO2 75%
- `fc9a1a57` What was the admission type for patient 10023117 during their first hospital visit?  
  truth: [['SURGICAL SAME DAY ADMISSION']]  ·  answer: Short stay (ActCode SS), routine priority, admitted 2170-10-08
- `2cd96b35` How many days has it been since patient 10018081's hospital admission?  
  truth: no answer  ·  answer: 13 days (admitted 2133-12-18 16:58; 13 days 7 h elapsed at 2133-12-31 23:59)
- `bede0977` What was the name of the last specimen test patient 10021938 got since 07/2181?  
  truth: [['MRSA SCREEN']]  ·  answer: Blood (specimen collected 2181-10-27 08:00, lab specimen)
- `7b7f155a` Tell me the name of the medication patient 10004720 was first prescribed via iv route since 05/2183?  
  truth: no answer  ·  answer: Potassium Chloride (Potassium Chloride--KCL20PM--00409707714_Sterile Water--KCLBASE2), first IV order authored 2186-11-12 22:12:44
- `58a17f0e` Did patient 10002428 come to the er during the first hospital encounter?  
  truth: [[1]]  ·  answer: No - the first hospital encounter (25797028, 2155-07-14 to 2155-07-15) has no linked ED encounter; the first ED visit (2155-12-04) was a separate standalone vis
- `dd025c27` How many hours has it been since patient 10018081 first received a mcv lab test during this hospital encounter?  
  truth: no answer  ·  answer: 318.5 hours (first MCV in the hospital encounter: 2133-12-18 17:28; 13 days 6 h 31 min before 2133-12-31 23:59)
- `feaa4517` During this month, when was the first time that patient 10005817 was prescribed a medication via the iv drip route?  
  truth: [['2132-12-12 11:00:00']]  ·  answer: 2132-12-12 10:03:09 (-05:00)
- `8a165a89` When did patient 10026255 last get a procedure since 2200?  
  truth: [['2200-09-17 00:00:00']]  ·  answer: 2200-09-18T00:05:00-04:00 (Taking patient vital signs assessment, ED procedure)
- `d69a4b8b` How many hours have passed since patient 10004733 stayed in the careunit medicine on this hospital visit for the first time?  
  truth: no answer  ·  answer: ≈459.93 hours (first Medicine stay began 2174-12-12 20:03:01)
- `1436276f` How many hours has it been since patient 10021487 got their last prescription of glucagon on this hospital stay?  
  truth: no answer  ·  answer: ≈687.4 hours (last glucagon prescription authored 2116-12-03 08:36:54 on hospital stay Encounter/ddcb961c; no stay was open at 2116-12-31 23:59)
- `5c5d37ea` Count the number of times that patient 10010471 received the performance of urinary filtration, multiple procedure in the previous year.  
  truth: no answer  ·  answer: 1
- `10396305` What is the sum of patient 10003046's or urine output during the last icu visit.  
  truth: [[150]]  ·  answer: 1969 mL (Foley 1819 mL over 44 entries + OR Urine 150 mL) during the last ICU stay (2154-01-02 to 2154-01-04)
- `7535579b` What was the organism's name found in the last peritoneal fluid microbiology test of patient 10021487 since 09/2116?  
  truth: [['CLOSTRIDIUM PERFRINGENS']
 ['BACTEROIDES FRAGILIS GROUP']]  ·  answer: BACTEROIDES FRAGILIS GROUP and PORPHYROMONAS SPECIES (anaerobic culture of peritoneal fluid, 2116-12-22 21:09)
- `672d81cd` When was patient 10015860's respiratory rate less than 21.0 for the first time since 06/06/2186?  
  truth: [['2186-09-15 18:00:00']]  ·  answer: 2186-09-15 12:56:00 (-04:00), respiratory rate 18 breaths/min
- `96ac404e` How much difference is there in respiratory rate levels among patient 10019777 last measured on the last icu visit compared to the value second to last measured on the last icu visit?  
  truth: [[-1.]]  ·  answer: 1 insp/min (last 11 at 2187-02-17T23:00 vs second-to-last 12 at 22:00; the last was 1 lower)
- `97f99846` How many unique medicines were prescribed to patient 10014354 since 4 months ago?  
  truth: [[28]]  ·  answer: 33
- `ee06998b` Has clonidine patch 0.3 mg/24 hr, amlodipine, or 5% dextrose been prescribed for patient 10004733 in this hospital encounter?  
  truth: no answer  ·  answer: Yes — all three were prescribed during the hospital encounter: Clonidine Patch 0.3 mg/24 hr (e.g. 2174-12-09), Amlodipine (e.g. 2174-12-04 and 2174-12-17), and 
- `6336898e` How many days have there been since patient 10039831's admission to the hospital?  
  truth: no answer  ·  answer: 3 days (admitted 2115-12-28 07:15; about 3.7 days, i.e. 3 full days, as of 2115-12-31 23:59)
- `f08654b0` Since 16 months ago, what specimen test did patient 10002428 receive for the last time?  
  truth: [['BLOOD CULTURE']]  ·  answer: Urine specimen (collected 2155-11-10 12:36 -05:00; both a urine lab specimen and a urine microbiology specimen)
- `44ba2f35` When was patient 10000032 first given a creatinine test in 05/2180?  
  truth: [['2180-05-07 05:05:00']]  ·  answer: 2180-05-06 22:25:00
- `c5d97a3f` How many days have passed since patient 10039831's last stay in careunit discharge lounge in this hospital visit?  
  truth: no answer  ·  answer: 3 days (Discharge Lounge stay ended 2115-12-28 19:36:43; about 3.18 days before 2115-12-31 23:59)
- `6f8551a8` How long has it been in hours since the first time ciprofloxacin iv was prescribed to patient 10018081 on the current hospital encounter?  
  truth: no answer  ·  answer: ≈278.7 hours (first ciprofloxacin IV order authored 2133-12-20 09:16:38, to 2133-12-31 23:59:00)
- `dbf9297a` What is the yearly volume of emesis that patient 10001217 had since 07/2157? if multiple emesis volumes are measured yearly, take the minimum.  
  truth: no answer  ·  answer: 100 ml (2157; single emesis measurement on 2157-11-21)
- `ed91e258` What medicine was prescribed to patient 10039708 for the first time since 07/2138?  
  truth: [['Heparin']
 ['Docusate Sodium']
 ['Senna']
 ['Sodium Chloride 0.9%  Flush']
 ['Sodium Chloride 0.9%']]  ·  answer: Thiamine (first prescribed 2138-10-30 20:02 -04:00)
- `3173d5e9` When was the last instance when patient 10021487's respiratory rate was greater than 17.0 on 12/17/2116?  
  truth: [['2116-12-17 23:52:00']]  ·  answer: 2116-12-17 18:00 (respiratory rate 28 insp/min)

### rest misses (40)
- `f195f5a0` When did patient 10004457 first get discharged from the hospital?  
  truth: [['2140-09-18 12:40:00']]  ·  answer: 2141-12-21T15:56:00-05:00
- `26fba968` How many hours have elapsed since the last time patient 10004733 on this hospital stay received a lab test for lactate dehydrogenase (ld)?  
  truth: no answer  ·  answer: about 330.8 hours (last LD 2174-12-18 05:10; Observation d4a1eb77 linked to the stay encounter 4080c645)
- `3c3a60ef` When was patient 10008287 prescribed for the last time a medication via the pr route since 08/2145?  
  truth: [['2145-10-01 14:00:00']]  ·  answer: 2145-10-01T13:10:49-04:00
- `568a32b0` When did patient 10020786 receive the last magnesium test in their last hospital encounter?  
  truth: [['2189-06-12 06:35:00']]  ·  answer: 2189-06-10T04:02:00-04:00 (magnesium 2.1 mg/dL)
- `5cf885d1` How many hours have passed since patient 10004733's last stay in careunit medical/surgical intensive care unit (micu/sicu) in this hospital encounter?  
  truth: no answer  ·  answer: ≈459.9 hours (last MICU/SICU stay ended 2174-12-12 20:03:01)
- `552b047a` When did patient 10039708 receive his last microbiology test during the last hospital visit?  
  truth: no answer  ·  answer: 2144-01-18T15:45:00-05:00 (urine culture, last hospital stay 2144-01-18 to 2144-01-21)
- `3ec03a34` Please list the yearly volume of chest tube #1 that was output by patient 10019172 since 09/2118. if multiple chest tube #1 volumes are measured yearly, take the average.  
  truth: no answer  ·  answer: 2118: 25.45 ml (average of 22 chest tube #1 output measurements, total 560 ml)
- `8465e809` What is the difference between platelet count last measured on the first hospital visit compared to the first value measured on the first hospital visit for patient 10009628?  
  truth: [[14.]]  ·  answer: Increase of 32 K/uL (first 130 K/uL on 2153-09-19 12:40, last 162 K/uL on 2153-09-21 01:48; inpatient encounter 09767f55)
- `ac9de430` What was the organism found in the last urine microbiology test for patient 10038081?  
  truth: [['YEAST']]  ·  answer: No single organism identified: the last urine culture (collected 2115-10-04 01:28) grew MIXED BACTERIAL FLORA (>= 3 colony types), consistent with skin and/or g
- `0b519b39` Today, when was the first time that patient 10018081 had the minimum spo2?  
  truth: [['2133-12-31 02:00:00']]  ·  answer: 2133-12-20 13:50:00 (minimum SpO2 75%)
- `ee981ea6` Tell me the length of stay in days for patient 10018328's first icu stay.  
  truth: [[7.70251157]]  ·  answer: 2.67 days (Trauma SICU, 2154-04-26 05:53 to 2154-04-28 21:51; ~2 d 16 h)
- `fc9a1a57` What was the admission type for patient 10023117 during their first hospital visit?  
  truth: [['SURGICAL SAME DAY ADMISSION']]  ·  answer: Short stay (class SS, routine priority; admit source physician referral) - first hospital encounter starting 2170-10-08
- `2cd96b35` How many days has it been since patient 10018081's hospital admission?  
  truth: no answer  ·  answer: 13 days (admission 2133-12-18 17:10; 13 days 6.8 h before 2133-12-31 23:59)
- `bede0977` What was the name of the last specimen test patient 10021938 got since 07/2181?  
  truth: [['MRSA SCREEN']]  ·  answer: Blood (specimen collected 2181-10-27 08:00; the latest specimen since 07/2181)
- `7b7f155a` Tell me the name of the medication patient 10004720 was first prescribed via iv route since 05/2183?  
  truth: no answer  ·  answer: Potassium Chloride (KCl in sterile water mix)
- `f3051b86` When was the last time that patient 10003400 was discharged from the hospital?  
  truth: [['2137-09-02 17:05:00']]  ·  answer: 2137-09-02T19:17:11-04:00
- `dd025c27` How many hours has it been since patient 10018081 first received a mcv lab test during this hospital encounter?  
  truth: no answer  ·  answer: 318.5 hours (first MCV 2133-12-18 17:28 to 2133-12-31 23:59)
- `feaa4517` During this month, when was the first time that patient 10005817 was prescribed a medication via the iv drip route?  
  truth: [['2132-12-12 11:00:00']]  ·  answer: 2132-12-12T10:03:09-05:00
- `8a165a89` When did patient 10026255 last get a procedure since 2200?  
  truth: [['2200-09-17 00:00:00']]  ·  answer: 2200-09-18T00:05:00-04:00
- `254b58ea` When did patient 10035185 receive red blood cells test the first time in the first hospital visit?  
  truth: [['2120-05-12 15:00:00']]  ·  answer: 2120-05-13T16:46:00-04:00 (Red Blood Cells 3.68, first result during the inpatient admission that began 2120-05-13T14:27; an earlier result at 2120-05-12T15:00 
- `d69a4b8b` How many hours have passed since patient 10004733 stayed in the careunit medicine on this hospital visit for the first time?  
  truth: no answer  ·  answer: 459.93 hours (Medicine first entered 2174-12-12 20:03:01)
- `1436276f` How many hours has it been since patient 10021487 got their last prescription of glucagon on this hospital stay?  
  truth: no answer  ·  answer: about 687.4 hours (last glucagon order 2116-12-03 08:36:54, 1 mg IM, on the stay of 2116-12-03 to 2116-12-28)
- `7535579b` What was the organism's name found in the last peritoneal fluid microbiology test of patient 10021487 since 09/2116?  
  truth: [['CLOSTRIDIUM PERFRINGENS']
 ['BACTEROIDES FRAGILIS GROUP']]  ·  answer: PORPHYROMONAS SPECIES and BACTEROIDES FRAGILIS GROUP (anaerobic culture of peritoneal fluid collected 2116-12-22 21:09)
- `672d81cd` When was patient 10015860's respiratory rate less than 21.0 for the first time since 06/06/2186?  
  truth: [['2186-09-15 18:00:00']]  ·  answer: 2186-09-15 12:56 (-04:00): respiratory rate 18 breaths/min
- `97f99846` How many unique medicines were prescribed to patient 10014354 since 4 months ago?  
  truth: [[28]]  ·  answer: 33
- `6bb8d0b3` Tell me patient 10038081's first oxygen value on the first hospital stay.  
  truth: [[94.]]  ·  answer: 40 % (lab "Oxygen", 2115-10-10T03:36:00-04:00) — first Oxygen result during the inpatient stay (2115-10-09 to 2115-10-13); an earlier 94 % on 2115-10-07 predate
- `7d3d2919` What was the length of stay in days for patient 10012552's last hospitalization?  
  truth: [[7.86944444]]  ·  answer: ≈3.2 days (3 days 3 h 48 min; 2140-03-25 14:37 to 2140-03-28 18:25)
- `ee06998b` Has clonidine patch 0.3 mg/24 hr, amlodipine, or 5% dextrose been prescribed for patient 10004733 in this hospital encounter?  
  truth: no answer  ·  answer: Yes - all three were prescribed in this encounter: Clonidine Patch 0.3 mg/24 hr (2174-12-12), Amlodipine (2174-12-17), and Dextrose 5% (2174-12-10).
- `bba49bd7` What was the admission type for patient 10002930's last hospital admission?  
  truth: [['EU OBSERVATION']]  ·  answer: Emergency (EMER)
- `6336898e` How many days have there been since patient 10039831's admission to the hospital?  
  truth: no answer  ·  answer: 3 days (admitted 2115-12-28 07:15; about 3.7 days elapsed at 2115-12-31 23:59)
- `f08654b0` Since 16 months ago, what specimen test did patient 10002428 receive for the last time?  
  truth: [['BLOOD CULTURE']]  ·  answer: Urine specimen (urine test), collected 2155-11-10 12:36 (-05:00)
- `44ba2f35` When was patient 10000032 first given a creatinine test in 05/2180?  
  truth: [['2180-05-07 05:05:00']]  ·  answer: 2180-05-06 22:25:00
- `c5d97a3f` How many days have passed since patient 10039831's last stay in careunit discharge lounge in this hospital visit?  
  truth: no answer  ·  answer: 3 days (last Discharge Lounge stay ended 2115-12-28 19:36:43; about 3.18 days before 2115-12-31 23:59)
- `6f8551a8` How long has it been in hours since the first time ciprofloxacin iv was prescribed to patient 10018081 on the current hospital encounter?  
  truth: no answer  ·  answer: 278.71 hours (first ciprofloxacin IV order authored 2133-12-20 09:16:38, encounter 05c742f8, to 2133-12-31 23:59:00)
- `764c80fc` Since 01/2148, when was patient 10038933's first microbiology test done?  
  truth: [['2148-09-10 15:29:00']]  ·  answer: 2148-09-10 00:00:00 (microbiology test recorded on 2148-09-10; the next one was 2148-09-10 15:29)
- `f97ed282` Is the value of patient 10019385's rdw-sd last measured on the last hospital visit less than the second to last value measured on the last hospital visit?  
  truth: [[1]]  ·  answer: No. The last RDW-SD on the last hospital visit was 49.5 fL (2180-02-25 06:05), which is higher than the second-to-last value of 48.1 fL (2180-02-24 06:08).
- `9930fa67` Get the sum of the outputs that happened on 12/18/2116 for patient 10021487.  
  truth: [[4110]]  ·  answer: 3710 ml
- `dbf9297a` What is the yearly volume of emesis that patient 10001217 had since 07/2157? if multiple emesis volumes are measured yearly, take the minimum.  
  truth: no answer  ·  answer: 100 ml
- `9aff84df` How much does patient 10038999 change in calcium, total second measured on the last hospital visit compared to the first value measured on the last hospital visit?  
  truth: no answer  ·  answer: -0.1 mg/dL (decrease: 7.8 mg/dL at 2131-05-22T22:45 to 7.7 mg/dL at 2131-05-23T04:54, last inpatient visit Encounter 24339e36)
- `ed91e258` What medicine was prescribed to patient 10039708 for the first time since 07/2138?  
  truth: [['Heparin']
 ['Docusate Sodium']
 ['Senna']
 ['Sodium Chloride 0.9%  Flush']
 ['Sodium Chloride 0.9%']]  ·  answer: Thiamine (first prescribed 2138-10-30 20:02)

### workspace misses (32)
- `26fba968` How many hours have elapsed since the last time patient 10004733 on this hospital stay received a lab test for lactate dehydrogenase (ld)?  
  truth: no answer  ·  answer: ≈330.8 hours (last LD 228 IU/L at 2174-12-18 05:10 -05:00; 330 h 49 min before 2174-12-31 23:59)
- `3c3a60ef` When was patient 10008287 prescribed for the last time a medication via the pr route since 08/2145?  
  truth: [['2145-10-01 14:00:00']]  ·  answer: 2145-10-01T13:10:49-04:00
- `b71bf471` When was patient 10036156's last procedure conducted in this year?  
  truth: [['2157-07-01 00:00:00']]  ·  answer: 2157-07-01 10:15:00 (Interventional Radiology)
- `5cf885d1` How many hours have passed since patient 10004733's last stay in careunit medical/surgical intensive care unit (micu/sicu) in this hospital encounter?  
  truth: no answer  ·  answer: ≈459.9 hours (ICU stay in MICU/SICU ended 2174-12-12 20:03:01)
- `552b047a` When did patient 10039708 receive his last microbiology test during the last hospital visit?  
  truth: no answer  ·  answer: 2144-01-18T15:45:00-05:00 (urine culture, during the last hospital visit: ED start 2144-01-18 to discharge 2144-01-21)
- `0e4bb227` When did patient 10004733 first have the minimum number of specific gravity on the current hospital visit?  
  truth: no answer  ·  answer: 2174-12-13T11:03:00-05:00 (minimum specific gravity 1.017)
- `3ec03a34` Please list the yearly volume of chest tube #1 that was output by patient 10019172 since 09/2118. if multiple chest tube #1 volumes are measured yearly, take the average.  
  truth: no answer  ·  answer: 2118: average chest tube #1 output 24.35 ml (23 measurements, total 560 ml)
- `ac9de430` What was the organism found in the last urine microbiology test for patient 10038081?  
  truth: [['YEAST']]  ·  answer: Mixed bacterial flora (>= 3 colony types), consistent with skin and/or genital contamination (urine culture 2115-10-04T01:28)
- `a2de199e` Can you tell me the first medicine that was prescribed to patient 10007795?  
  truth: [['Multivitamins']
 ['Nicotine Patch']
 ['Duloxetine']
 ['Tamoxifen Citrate']]  ·  answer: The first orders were all written at the same moment, 2136-04-10 21:43:35 (-04:00), so no single first medicine can be named. Those with the earliest start (213
- `0b519b39` Today, when was the first time that patient 10018081 had the minimum spo2?  
  truth: [['2133-12-31 02:00:00']]  ·  answer: 2133-12-20 13:50:00 (minimum SpO2 75 %)
- `fc9a1a57` What was the admission type for patient 10023117 during their first hospital visit?  
  truth: [['SURGICAL SAME DAY ADMISSION']]  ·  answer: Short stay (Encounter class SS; routine priority, admitted via physician referral)
- `2cd96b35` How many days has it been since patient 10018081's hospital admission?  
  truth: no answer  ·  answer: 13 days (admitted 2133-12-18 16:58; 13 days 7 h before 2133-12-31 23:59)
- `bede0977` What was the name of the last specimen test patient 10021938 got since 07/2181?  
  truth: [['MRSA SCREEN']]  ·  answer: Blood (specimen collected 2181-10-27 08:00, with CBC-type lab results)
- `7b7f155a` Tell me the name of the medication patient 10004720 was first prescribed via iv route since 05/2183?  
  truth: no answer  ·  answer: Potassium Chloride (premixed bag with Sterile Water, KCL20PM/KCLBASE2), IV, ordered 2186-11-12 22:12:44
- `dd025c27` How many hours has it been since patient 10018081 first received a mcv lab test during this hospital encounter?  
  truth: no answer  ·  answer: 318.52 hours (first MCV in this hospital encounter at 2133-12-18 17:28)
- `feaa4517` During this month, when was the first time that patient 10005817 was prescribed a medication via the iv drip route?  
  truth: [['2132-12-12 11:00:00']]  ·  answer: 2132-12-12T10:03:09-05:00
- `8a165a89` When did patient 10026255 last get a procedure since 2200?  
  truth: [['2200-09-17 00:00:00']]  ·  answer: 2200-09-18T00:05:00-04:00 (vital signs assessment, ED)
- `d69a4b8b` How many hours have passed since patient 10004733 stayed in the careunit medicine on this hospital visit for the first time?  
  truth: no answer  ·  answer: 459.93 hours (Medicine first entered 2174-12-12 20:03:01)
- `1436276f` How many hours has it been since patient 10021487 got their last prescription of glucagon on this hospital stay?  
  truth: no answer  ·  answer: ≈687.4 hours (last glucagon prescription authored 2116-12-03 08:36:54 on stay 28998349; now 2116-12-31 23:59:00)
- `7535579b` What was the organism's name found in the last peritoneal fluid microbiology test of patient 10021487 since 09/2116?  
  truth: [['CLOSTRIDIUM PERFRINGENS']
 ['BACTEROIDES FRAGILIS GROUP']]  ·  answer: PORPHYROMONAS SPECIES and BACTEROIDES FRAGILIS GROUP (anaerobic culture of peritoneal fluid, 2116-12-22 21:09)
- `672d81cd` When was patient 10015860's respiratory rate less than 21.0 for the first time since 06/06/2186?  
  truth: [['2186-09-15 18:00:00']]  ·  answer: 2186-09-15 12:56:00 (respiratory rate 18 breaths/minute)
- `97f99846` How many unique medicines were prescribed to patient 10014354 since 4 months ago?  
  truth: [[28]]  ·  answer: 33
- `ee06998b` Has clonidine patch 0.3 mg/24 hr, amlodipine, or 5% dextrose been prescribed for patient 10004733 in this hospital encounter?  
  truth: no answer  ·  answer: Yes — all three were prescribed during the hospital encounter (27411876): Clonidine Patch 0.3 mg/24 hr (1 patch TD, 2174-12-09; also 2174-12-12 entry), Amlodipi
- `6336898e` How many days have there been since patient 10039831's admission to the hospital?  
  truth: no answer  ·  answer: 3 days (3.7 days; admitted 2115-12-28 07:15, still inpatient at 2115-12-31 23:59)
- `f08654b0` Since 16 months ago, what specimen test did patient 10002428 receive for the last time?  
  truth: [['BLOOD CULTURE']]  ·  answer: Urine specimen (urine culture/lab), collected 2155-11-10 12:36
- `44ba2f35` When was patient 10000032 first given a creatinine test in 05/2180?  
  truth: [['2180-05-07 05:05:00']]  ·  answer: 2180-05-06 22:25
- `c5d97a3f` How many days have passed since patient 10039831's last stay in careunit discharge lounge in this hospital visit?  
  truth: no answer  ·  answer: 3 days (discharge lounge stay ended 2115-12-28 19:36:43; 3.18 days before 2115-12-31 23:59)
- `6f8551a8` How long has it been in hours since the first time ciprofloxacin iv was prescribed to patient 10018081 on the current hospital encounter?  
  truth: no answer  ·  answer: ≈278.7 hours (first ciprofloxacin IV order authored 2133-12-20 09:16:38 on the current admission)
- `764c80fc` Since 01/2148, when was patient 10038933's first microbiology test done?  
  truth: [['2148-09-10 15:29:00']]  ·  answer: 2148-09-10 00:00:00 (urine culture, no growth)
- `dbf9297a` What is the yearly volume of emesis that patient 10001217 had since 07/2157? if multiple emesis volumes are measured yearly, take the minimum.  
  truth: no answer  ·  answer: 100 ml (single emesis measurement in 2157, on 2157-11-21)
- `ed91e258` What medicine was prescribed to patient 10039708 for the first time since 07/2138?  
  truth: [['Heparin']
 ['Docusate Sodium']
 ['Senna']
 ['Sodium Chloride 0.9%  Flush']
 ['Sodium Chloride 0.9%']]  ·  answer: Thiamine (first prescribed 2138-10-30 20:02 -04:00)
- `3173d5e9` When was the last instance when patient 10021487's respiratory rate was greater than 17.0 on 12/17/2116?  
  truth: [['2116-12-17 23:52:00']]  ·  answer: 28 insp/min at 2116-12-17 18:00 (-05:00)

