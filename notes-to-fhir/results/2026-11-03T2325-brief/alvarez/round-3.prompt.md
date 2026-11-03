Turn this clinic note into FHIR R4 resources that conform to the clinic's profiles.

The profiles (their urls):
- Patient (Patient): http://example.org/fhir/notes/StructureDefinition/note-patient
- Blood pressure (Observation): http://example.org/fhir/notes/StructureDefinition/note-blood-pressure
- Problem (Condition): http://example.org/fhir/notes/StructureDefinition/note-problem
- Medication (MedicationStatement): http://example.org/fhir/notes/StructureDefinition/note-medication

Rules:
- Answer with ONE ```json block: a FHIR Bundle of type "collection", one entry per resource (each entry has `resource`).
- Exactly one NotePatient. Every other resource's subject is a reference to it: "Patient/<its id>".
- Every resource declares its profile in meta.profile.
- Use only the codes the profiles allow. Leave out what the profiles do not cover (other labs and vitals, family history, conditions the note says the patient does not have).
- Dates as YYYY-MM-DD.

The note:

Date of visit: 2026-10-16
Patient: Lucia Alvarez   DOB: 1990-07-03   Sex: F

Reason: wheezing x 3 days after a cold.

Hx: Asthma since childhood, uses albuterol inhaler 2 puffs q4-6h PRN, last few days ~3x/day.
No history of hypertension or diabetes. No controller med.

Vitals: BP 118/76, HR 92, SpO2 97% RA, RR 18.
Exam: mild expiratory wheeze bilaterally.

Assessment: asthma exacerbation, mild.
Plan: continue albuterol PRN; start ICS discussed, pt prefers to wait. Return if worse.


## Your previous answer

```json
{"entry":[{"resource":{"birthDate":"1990-07-03","gender":"female","id":"lucia-alvarez","meta":{"profile":["http://example.org/fhir/notes/StructureDefinition/note-patient"]},"name":[{"family":"Alvarez","given":["Lucia"]}],"resourceType":"Patient"}},{"resource":{"category":[{"coding":[{"code":"vital-signs","display":"Vital Signs","system":"http://terminology.hl7.org/CodeSystem/observation-category"}]}],"code":{"coding":[{"code":"55284-4","display":"Blood pressure systolic and diastolic","system":"http://loinc.org"},{"code":"85354-9","display":"Blood pressure panel with all children optional","system":"http://loinc.org"}],"text":"Blood pressure"},"component":[{"code":{"coding":[{"code":"8480-6","display":"Systolic blood pressure","system":"http://loinc.org"}]},"valueQuantity":{"code":"mm[Hg]","system":"http://unitsofmeasure.org","unit":"mmHg","value":118}},{"code":{"coding":[{"code":"8462-4","display":"Diastolic blood pressure","system":"http://loinc.org"}]},"valueQuantity":{"code":"mm[Hg]","system":"http://unitsofmeasure.org","unit":"mmHg","value":76}}],"effectiveDateTime":"2026-10-16","id":"bp-2026-10-16","meta":{"profile":["http://example.org/fhir/notes/StructureDefinition/note-blood-pressure"]},"resourceType":"Observation","status":"final","subject":{"reference":"Patient/lucia-alvarez"}}},{"resource":{"category":[{"coding":[{"code":"problem-list-item","display":"Problem List Item","system":"http://terminology.hl7.org/CodeSystem/condition-category"}]}],"clinicalStatus":{"coding":[{"code":"active","display":"Active","system":"http://terminology.hl7.org/CodeSystem/condition-clinical"}]},"code":{"coding":[{"code":"195967001","display":"Asthma","system":"http://snomed.info/sct"}],"text":"Asthma since childhood; mild exacerbation at this visit"},"id":"asthma","meta":{"profile":["http://example.org/fhir/notes/StructureDefinition/note-problem"]},"recordedDate":"2026-10-16","resourceType":"Condition","subject":{"reference":"Patient/lucia-alvarez"},"verificationStatus":{"coding":[{"code":"confirmed","display":"Confirmed","system":"http://terminology.hl7.org/CodeSystem/condition-ver-status"}]}}},{"resource":{"dateAsserted":"2026-10-16","dosage":[{"asNeededBoolean":true,"doseAndRate":[{"doseQuantity":{"code":"{puff}","system":"http://unitsofmeasure.org","unit":"puff","value":2}}],"route":{"coding":[{"code":"447694001","display":"Respiratory tract route","system":"http://snomed.info/sct"}]},"text":"2 puffs inhaled every 4-6 hours as needed","timing":{"repeat":{"frequency":1,"period":4,"periodMax":6,"periodUnit":"h"}}}],"id":"albuterol","medicationCodeableConcept":{"coding":[{"code":"435","display":"albuterol","system":"http://www.nlm.nih.gov/research/umls/rxnorm"}],"text":"Albuterol inhaler"},"meta":{"profile":["http://example.org/fhir/notes/StructureDefinition/note-medication"]},"resourceType":"MedicationStatement","status":"active","subject":{"reference":"Patient/lucia-alvarez"}}}],"resourceType":"Bundle","type":"collection"}
```

## It does not conform yet

- Observation/bp-2026-10-16: Observation.code: value does not match required pattern

Fix these and answer with the complete corrected Bundle in ONE ```json block.
