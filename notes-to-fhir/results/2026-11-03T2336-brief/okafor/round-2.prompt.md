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

Date of visit: 2026-10-15
Patient: Bo Okafor, born 1958-02-27, male

CC: diabetes check

HPI: 68M with T2DM, on metformin 500mg twice daily w/ meals, tolerating well. No hypoglycemia.
Walking 30 min most days.

Exam: BP 124/79. BMI 29. Feet: intact sensation, no ulcers.
Labs: HbA1c 7.1% (prev 7.6%).

Plan: continue metformin 500 mg BID. Diet counseling. RTC 3 months with A1c.


## Your previous answer

```json
{"entry":[{"resource":{"birthDate":"1958-02-27","gender":"male","id":"bo-okafor","meta":{"profile":["http://example.org/fhir/notes/StructureDefinition/note-patient"]},"name":[{"family":"Okafor","given":["Bo"]}],"resourceType":"Patient"}},{"resource":{"category":[{"coding":[{"code":"vital-signs","display":"Vital Signs","system":"http://terminology.hl7.org/CodeSystem/observation-category"}]}],"code":{"coding":[{"code":"85354-9","display":"Blood pressure panel with all children optional","system":"http://loinc.org"}]},"component":[{"code":{"coding":[{"code":"8480-6","display":"Systolic blood pressure","system":"http://loinc.org"}]},"valueQuantity":{"code":"mm[Hg]","system":"http://unitsofmeasure.org","unit":"mmHg","value":124}},{"code":{"coding":[{"code":"8462-4","display":"Diastolic blood pressure","system":"http://loinc.org"}]},"valueQuantity":{"code":"mm[Hg]","system":"http://unitsofmeasure.org","unit":"mmHg","value":79}}],"effectiveDateTime":"2026-10-15","id":"bp-2026-10-15","meta":{"profile":["http://example.org/fhir/notes/StructureDefinition/note-blood-pressure"]},"resourceType":"Observation","status":"final","subject":{"reference":"Patient/bo-okafor"}}},{"resource":{"category":[{"coding":[{"code":"problem-list-item","display":"Problem List Item","system":"http://terminology.hl7.org/CodeSystem/condition-category"}]}],"clinicalStatus":{"coding":[{"code":"active","display":"Active","system":"http://terminology.hl7.org/CodeSystem/condition-clinical"}]},"code":{"coding":[{"code":"44054006","display":"Diabetes mellitus type 2","system":"http://snomed.info/sct"}],"text":"Type 2 diabetes mellitus"},"id":"t2dm","meta":{"profile":["http://example.org/fhir/notes/StructureDefinition/note-problem"]},"recordedDate":"2026-10-15","resourceType":"Condition","subject":{"reference":"Patient/bo-okafor"},"verificationStatus":{"coding":[{"code":"confirmed","display":"Confirmed","system":"http://terminology.hl7.org/CodeSystem/condition-ver-status"}]}}},{"resource":{"dateAsserted":"2026-10-15","dosage":[{"doseAndRate":[{"doseQuantity":{"code":"mg","system":"http://unitsofmeasure.org","unit":"mg","value":500}}],"route":{"coding":[{"code":"26643006","display":"Oral route","system":"http://snomed.info/sct"}]},"text":"500 mg twice daily with meals","timing":{"repeat":{"frequency":2,"period":1,"periodUnit":"d"}}}],"effectiveDateTime":"2026-10-15","id":"metformin","medicationCodeableConcept":{"coding":[{"code":"861007","display":"metformin hydrochloride 500 MG Oral Tablet","system":"http://www.nlm.nih.gov/research/umls/rxnorm"}],"text":"Metformin 500 mg"},"meta":{"profile":["http://example.org/fhir/notes/StructureDefinition/note-medication"]},"resourceType":"MedicationStatement","status":"active","subject":{"reference":"Patient/bo-okafor"}}}],"resourceType":"Bundle","type":"collection"}
```

## It does not conform yet

- Observation/bp-2026-10-15: Observation.code: value does not match required pattern {"coding":[{"code":"85354-9","display":"Blood pressure panel","system":"http://loinc.org"}]}
- MedicationStatement/metformin: MedicationStatement.medication[x]: code not in required value set http://example.org/fhir/notes/ValueSet/note-medication-codes

Fix these and answer with the complete corrected Bundle in ONE ```json block.
