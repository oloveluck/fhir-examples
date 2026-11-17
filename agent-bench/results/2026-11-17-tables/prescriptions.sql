SELECT CAST(h.ident AS INTEGER) AS hadm_id, COALESCE(di.drug, d.drug) AS drug,
       COALESCE(m.starttime, substr(m.authored,1,16) || ':00') AS starttime, m.route AS route,
       CASE WHEN ing.is_base = 1 AND d.mix_base GLOB '[0-9]*' AND d.mix_base NOT GLOB '*[^0-9]*' THEN d.mix_base
            WHEN ing.is_base = 0 AND d.mix_add GLOB '[0-9]*' AND d.mix_add NOT GLOB '*[^0-9]*' AND (m.dose IS NULL OR CAST(m.dose AS REAL) = CAST(m.dtext AS REAL)) THEN d.mix_add
            ELSE m.dose END AS dose_val_rx,
       'MedicationRequest/' || m.id AS fhir_id, 'Medication/' || COALESCE(di.id, d.id) AS medication_fhir_id,
       'Medication/' || d.id AS mix_fhir_id
FROM fhir_medreqs m JOIN fhir_medications d ON d.id = m.medication_id
LEFT JOIN (SELECT i.id, i.ingredient_id, CASE WHEN i.ingredient_id = x.base_id THEN 1 ELSE 0 END AS is_base
           FROM fhir_medication_ingredients i JOIN fhir_medications x ON x.id = i.id) ing ON ing.id = d.id
LEFT JOIN fhir_medications di ON di.id = ing.ingredient_id
LEFT JOIN fhir_encounters h ON h.id = m.encounter_id
