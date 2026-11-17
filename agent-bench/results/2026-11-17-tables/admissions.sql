SELECT CAST(p.subject_id AS INTEGER) AS subject_id, CAST(e.ident AS INTEGER) AS hadm_id,
 e.starttime AS admittime, e.endtime AS dischtime,
 CASE e.priority WHEN 'EM' THEN CASE WHEN e.admit_source IN ('PHYSICIAN REFERRAL','CLINIC REFERRAL') THEN 'DIRECT EMER.' ELSE 'EW EMER.' END
   WHEN 'UR' THEN 'URGENT' WHEN 'EL' THEN 'ELECTIVE'
   WHEN 'R' THEN CASE e.class WHEN 'SS' THEN 'SURGICAL SAME DAY ADMISSION' WHEN 'AMB' THEN 'AMBULATORY OBSERVATION'
        ELSE CASE WHEN e.types NOT LIKE '%G0378%' AND e.types NOT LIKE '%9921%' THEN 'OBSERVATION ADMIT' WHEN e.admit_source = 'EMERGENCY ROOM' OR EXISTS (SELECT 1 FROM fhir_encounters c WHERE c.parent_id = e.id AND c.kind LIKE '%ed') THEN 'EU OBSERVATION' ELSE 'DIRECT OBSERVATION' END END END AS admission_type,
 e.admit_source AS admission_location,
 CASE p.marital WHEN 'M' THEN 'MARRIED' WHEN 'S' THEN 'SINGLE' WHEN 'W' THEN 'WIDOWED' WHEN 'D' THEN 'DIVORCED' END AS marital_status,
 'Encounter/' || e.id AS fhir_id
FROM fhir_encounters e JOIN fhir_patients p ON p.id = e.patient_id
WHERE e.kind LIKE '%hosp'
