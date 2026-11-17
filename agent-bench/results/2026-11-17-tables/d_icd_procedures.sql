SELECT code AS icd_code, MIN(title) AS long_title FROM fhir_procedures GROUP BY code
