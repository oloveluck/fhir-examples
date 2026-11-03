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

Date of visit: 2026-10-17
Patient: Wei Chen, male, date of birth March 9 1975

Here for annual physical. Feels well. Father had type 2 diabetes; mother has high cholesterol.
No regular meds.

BP on arrival 158/98; repeated after 5 min rest 146/92. Second elevated reading at our clinic
(Sept BP 150/94).

Impression: hypertension, newly diagnosed, stage 2.
Plan: start amlodipine 5 mg once daily. Low-sodium diet. Recheck BP in 2 weeks.


## Your previous answer

```json
{"entry":[{"resource":{"birthDate":"1975-03-09","gender":"male","id":"wei-chen","meta":{"profile":["http://example.org/fhir/notes/StructureDefinition/note-patient"]},"name":[{"family":"Chen","given":["Wei"]}],"resourceType":"Patient"}},{"resource":{"category":[{"coding":[{"code":"vital-signs","display":"Vital Signs","system":"http://terminology.hl7.org/CodeSystem/observation-category"}]}],"code":{"coding":[{"code":"85354-9","display":"Blood pressure panel with all children optional","system":"http://loinc.org"}]},"component":[{"code":{"coding":[{"code":"8480-6","display":"Systolic blood pressure","system":"http://loinc.org"}]},"valueQuantity":{"code":"mm[Hg]","system":"http://unitsofmeasure.org","unit":"mmHg","value":158}},{"code":{"coding":[{"code":"8462-4","display":"Diastolic blood pressure","system":"http://loinc.org"}]},"valueQuantity":{"code":"mm[Hg]","system":"http://unitsofmeasure.org","unit":"mmHg","value":98}}],"effectiveDateTime":"2026-10-17","id":"bp-2026-10-17-arrival","meta":{"profile":["http://example.org/fhir/notes/StructureDefinition/note-blood-pressure"]},"resourceType":"Observation","status":"final","subject":{"reference":"Patient/wei-chen"}}},{"resource":{"category":[{"coding":[{"code":"vital-signs","display":"Vital Signs","system":"http://terminology.hl7.org/CodeSystem/observation-category"}]}],"code":{"coding":[{"code":"85354-9","display":"Blood pressure panel with all children optional","system":"http://loinc.org"}]},"component":[{"code":{"coding":[{"code":"8480-6","display":"Systolic blood pressure","system":"http://loinc.org"}]},"valueQuantity":{"code":"mm[Hg]","system":"http://unitsofmeasure.org","unit":"mmHg","value":146}},{"code":{"coding":[{"code":"8462-4","display":"Diastolic blood pressure","system":"http://loinc.org"}]},"valueQuantity":{"code":"mm[Hg]","system":"http://unitsofmeasure.org","unit":"mmHg","value":92}}],"effectiveDateTime":"2026-10-17","id":"bp-2026-10-17-repeat","meta":{"profile":["http://example.org/fhir/notes/StructureDefinition/note-blood-pressure"]},"resourceType":"Observation","status":"final","subject":{"reference":"Patient/wei-chen"}}},{"resource":{"category":[{"coding":[{"code":"problem-list-item","display":"Problem List Item","system":"http://terminology.hl7.org/CodeSystem/condition-category"}]}],"clinicalStatus":{"coding":[{"code":"active","display":"Active","system":"http://terminology.hl7.org/CodeSystem/condition-clinical"}]},"code":{"coding":[{"code":"38341003","display":"Hypertensive disorder, systemic arterial","system":"http://snomed.info/sct"}],"text":"Hypertension, stage 2"},"id":"hypertension","meta":{"profile":["http://example.org/fhir/notes/StructureDefinition/note-problem"]},"onsetDateTime":"2026-10-17","recordedDate":"2026-10-17","resourceType":"Condition","subject":{"reference":"Patient/wei-chen"},"verificationStatus":{"coding":[{"code":"confirmed","display":"Confirmed","system":"http://terminology.hl7.org/CodeSystem/condition-ver-status"}]}}},{"resource":{"dateAsserted":"2026-10-17","dosage":[{"doseAndRate":[{"doseQuantity":{"code":"mg","system":"http://unitsofmeasure.org","unit":"mg","value":5}}],"text":"5 mg once daily","timing":{"repeat":{"frequency":1,"period":1,"periodUnit":"d"}}}],"effectivePeriod":{"start":"2026-10-17"},"id":"amlodipine","medicationCodeableConcept":{"coding":[{"code":"197361","display":"amlodipine 5 MG Oral Tablet","system":"http://www.nlm.nih.gov/research/umls/rxnorm"}],"text":"amlodipine 5 mg"},"meta":{"profile":["http://example.org/fhir/notes/StructureDefinition/note-medication"]},"resourceType":"MedicationStatement","status":"active","subject":{"reference":"Patient/wei-chen"}}}],"resourceType":"Bundle","type":"collection"}
```

## It does not conform yet

- Observation/bp-2026-10-17-arrival: Observation.code: value does not match required pattern {"coding":[{"code":"85354-9","display":"Blood pressure panel","system":"http://loinc.org"}]}
- Observation/bp-2026-10-17-repeat: Observation.code: value does not match required pattern {"coding":[{"code":"85354-9","display":"Blood pressure panel","system":"http://loinc.org"}]}
- MedicationStatement/amlodipine: MedicationStatement.medication[x]: code not in required value set http://example.org/fhir/notes/ValueSet/note-medication-codes

Fix these and answer with the complete corrected Bundle in ONE ```json block.
