SELECT CAST(h.ident AS INTEGER) AS hadm_id, CAST(i.ident AS INTEGER) AS stay_id, i.starttime AS intime, i.endtime AS outtime, 'Encounter/' || i.id AS fhir_id
FROM fhir_encounters i JOIN fhir_encounters h ON h.id = i.parent_id
WHERE i.kind LIKE '%icu'
