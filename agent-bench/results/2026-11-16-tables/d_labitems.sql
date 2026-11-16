SELECT CAST(itemid AS INTEGER) AS itemid, MIN(label) AS label FROM fhir_labs GROUP BY itemid
