SELECT CAST(h.ident AS INTEGER) AS hadm_id, l.name AS careunit, el.intime AS intime, 'Encounter/' || h.id AS fhir_id,
       'Location/' || l.id AS location_fhir_id
FROM fhir_encounter_locations el JOIN fhir_encounters h ON h.id = el.id JOIN fhir_locations l ON l.id = el.location_id
WHERE h.kind LIKE '%hosp'
UNION ALL
SELECT NULL, 'Emergency Department', h.starttime, 'Encounter/' || h.id, NULL
FROM fhir_encounters h WHERE h.kind LIKE '%ed' AND h.parent_id IS NULL
UNION ALL
SELECT CAST(h.ident AS INTEGER), NULL, el.outtime, 'Encounter/' || h.id, NULL
FROM fhir_encounter_locations el JOIN fhir_encounters h ON h.id = el.id
WHERE h.kind LIKE '%hosp' AND el.outtime IS NOT NULL
AND NOT EXISTS (SELECT 1 FROM fhir_encounter_locations n WHERE n.id = el.id AND n.intime = el.outtime)
