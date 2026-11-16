SELECT code AS icd_code, MIN(title) AS long_title FROM fhir_conditions GROUP BY code
