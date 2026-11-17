SELECT CAST(h.ident AS INTEGER) AS hadm_id, c.code AS icd_code, 'Condition/' || c.id AS fhir_id
FROM fhir_conditions c JOIN fhir_encounters h ON h.id = c.encounter_id WHERE h.kind LIKE '%hosp'
