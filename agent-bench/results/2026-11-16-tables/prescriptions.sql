SELECT CAST(h.ident AS INTEGER) AS hadm_id, COALESCE(di.drug, d.drug) AS drug,
       COALESCE(m.starttime, substr(m.authored,1,16) || ':00') AS starttime, m.route AS route, m.dose AS dose_val_rx,
       'MedicationRequest/' || m.id AS fhir_id, 'Medication/' || COALESCE(di.id, d.id) AS medication_fhir_id
FROM fhir_medreqs m JOIN fhir_medications d ON d.id = m.medication_id
LEFT JOIN fhir_medication_ingredients ing ON ing.id = d.id
LEFT JOIN fhir_medications di ON di.id = ing.ingredient_id
LEFT JOIN fhir_encounters h ON h.id = m.encounter_id
