SELECT CAST(i.ident AS INTEGER) AS stay_id, CAST(c.itemid AS INTEGER) AS itemid, c.charttime AS charttime, c.valuenum AS valuenum, 'Observation/' || c.id AS fhir_id
FROM fhir_chart c JOIN fhir_encounters i ON i.id = c.encounter_id
