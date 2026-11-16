SELECT CAST(h.ident AS INTEGER) AS hadm_id, l.name AS careunit, el.intime AS intime, 'Encounter/' || h.id AS fhir_id
FROM fhir_encounter_locations el JOIN fhir_encounters h ON h.id = el.id JOIN fhir_locations l ON l.id = el.location_id
WHERE h.kind LIKE '%hosp'
