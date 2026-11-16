SELECT CAST(h.ident AS INTEGER) AS hadm_id, CAST(l.itemid AS INTEGER) AS itemid, l.charttime AS charttime, l.valuenum AS valuenum, 'Observation/' || l.id AS fhir_id
FROM fhir_labs l LEFT JOIN fhir_encounters h ON h.id = l.encounter_id
