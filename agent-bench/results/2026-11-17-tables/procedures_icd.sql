SELECT CAST(h.ident AS INTEGER) AS hadm_id, p.code AS icd_code, p.charttime || ' 00:00:00' AS charttime, 'Procedure/' || p.id AS fhir_id
FROM fhir_procedures p JOIN fhir_encounters h ON h.id = p.encounter_id
