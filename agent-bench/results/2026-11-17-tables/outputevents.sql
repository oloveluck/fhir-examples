SELECT CAST(i.ident AS INTEGER) AS stay_id, CAST(o.code AS INTEGER) AS itemid, o.charttime AS charttime, o.valuenum AS value, 'Observation/' || o.id AS fhir_id
FROM fhir_obs_other o JOIN fhir_encounters i ON i.id = o.encounter_id
WHERE o.profile = 'observation-outputevents'
