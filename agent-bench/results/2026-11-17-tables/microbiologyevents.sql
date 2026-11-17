SELECT CAST(h.ident AS INTEGER) AS hadm_id,
       CASE WHEN h.id IS NULL AND t.charttime LIKE '% 00:00:00' THEN NULL ELSE t.charttime END AS charttime,
       s.spec_type AS spec_type_desc,
       t.display AS test_name, o.display AS org_name, 'Observation/' || t.id AS fhir_id,
       'Observation/' || o.id AS org_fhir_id, 'Observation/' || u.id AS susc_fhir_id
FROM fhir_obs_other t
LEFT JOIN fhir_encounters h ON h.id = t.encounter_id
LEFT JOIN fhir_specimens s ON s.id = t.specimen_id
LEFT JOIN fhir_obs_other o ON o.derived_id = t.id AND o.profile = 'observation-micro-org'
LEFT JOIN fhir_obs_other u ON u.derived_id = o.id AND u.profile = 'observation-micro-susc'
WHERE t.profile = 'observation-micro-test'
