SELECT CAST(subject_id AS INTEGER) AS subject_id, CASE gender WHEN 'male' THEN 'M' WHEN 'female' THEN 'F' END AS gender, 'Patient/' || id AS fhir_id FROM fhir_patients
