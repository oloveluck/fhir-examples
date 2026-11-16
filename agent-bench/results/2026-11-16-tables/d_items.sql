SELECT CAST(itemid AS INTEGER) AS itemid, MIN(label) AS label, linksto FROM (
  SELECT itemid, label, 'chartevents' AS linksto FROM fhir_chart
  UNION ALL
  SELECT code, display, substr(profile, 13) FROM fhir_obs_other WHERE profile IN ('observation-outputevents','observation-datetimeevents')
) GROUP BY itemid, linksto
