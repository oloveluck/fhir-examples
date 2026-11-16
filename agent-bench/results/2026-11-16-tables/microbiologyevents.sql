SELECT CAST(h.ident AS INTEGER) AS hadm_id, t.charttime AS charttime, s.spec_type AS spec_type_desc,
       t.display AS test_name, o.display AS org_name, 'Observation/' || t.id AS fhir_id
FROM fhir_obs_other t
LEFT JOIN fhir_encounters h ON h.id = t.encounter_id
LEFT JOIN fhir_specimens s ON s.id = t.specimen_id
LEFT JOIN fhir_obs_other o ON o.derived_id = t.id AND o.profile = 'observation-micro-org'
WHERE t.profile = 'observation-micro-test'
