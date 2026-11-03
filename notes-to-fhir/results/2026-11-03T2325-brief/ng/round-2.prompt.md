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

Date of visit: 2026-10-14
Patient: Ann Ng, DOB 04/12/1961, female

S: 65 y/o F here for f/u of HTN. Reports good adherence to lisinopril 10 mg PO daily. Occasional
headaches in the morning, no chest pain or SOB. Also on atorvastatin 20 mg nightly for HLD; lipid
panel last month LDL 98.

O: BP 152/96 seated, HR 78, wt 71 kg. Lungs clear, no edema.

A/P:
1. HTN - not at goal. Continue lisinopril, recheck in 4 wks, home BP log.
2. Hyperlipidemia - stable on atorvastatin, continue.


## Your previous answer

```json
{"entry":[{"resource":{"birthDate":"1961-04-12","gender":"female","id":"patient-1","meta":{"profile":["http://example.org/fhir/notes/StructureDefinition/note-patient"]},"name":[{"family":"Ng","given":["Ann"]}],"resourceType":"Patient"}},{"resource":{"category":[{"coding":[{"code":"vital-signs","display":"Vital Signs","system":"http://terminology.hl7.org/CodeSystem/observation-category"}]}],"code":{"coding":[{"code":"85354-9","display":"Blood pressure panel with all children optional","system":"http://loinc.org"}]},"component":[{"code":{"coding":[{"code":"8480-6","display":"Systolic blood pressure","system":"http://loinc.org"}]},"valueQuantity":{"code":"mm[Hg]","system":"http://unitsofmeasure.org","unit":"mmHg","value":152}},{"code":{"coding":[{"code":"8462-4","display":"Diastolic blood pressure","system":"http://loinc.org"}]},"valueQuantity":{"code":"mm[Hg]","system":"http://unitsofmeasure.org","unit":"mmHg","value":96}}],"effectiveDateTime":"2026-10-14","id":"bp-1","meta":{"profile":["http://example.org/fhir/notes/StructureDefinition/note-blood-pressure"]},"resourceType":"Observation","status":"final","subject":{"reference":"Patient/patient-1"}}},{"resource":{"category":[{"coding":[{"code":"problem-list-item","display":"Problem List Item","system":"http://terminology.hl7.org/CodeSystem/condition-category"}]}],"clinicalStatus":{"coding":[{"code":"active","display":"Active","system":"http://terminology.hl7.org/CodeSystem/condition-clinical"}]},"code":{"coding":[{"code":"38341003","display":"Hypertensive disorder, systemic arterial","system":"http://snomed.info/sct"}],"text":"Hypertension"},"id":"problem-htn","meta":{"profile":["http://example.org/fhir/notes/StructureDefinition/note-problem"]},"recordedDate":"2026-10-14","resourceType":"Condition","subject":{"reference":"Patient/patient-1"},"verificationStatus":{"coding":[{"code":"confirmed","display":"Confirmed","system":"http://terminology.hl7.org/CodeSystem/condition-ver-status"}]}}},{"resource":{"category":[{"coding":[{"code":"problem-list-item","display":"Problem List Item","system":"http://terminology.hl7.org/CodeSystem/condition-category"}]}],"clinicalStatus":{"coding":[{"code":"active","display":"Active","system":"http://terminology.hl7.org/CodeSystem/condition-clinical"}]},"code":{"coding":[{"code":"55822004","display":"Hyperlipidemia","system":"http://snomed.info/sct"}],"text":"Hyperlipidemia"},"id":"problem-hld","meta":{"profile":["http://example.org/fhir/notes/StructureDefinition/note-problem"]},"recordedDate":"2026-10-14","resourceType":"Condition","subject":{"reference":"Patient/patient-1"},"verificationStatus":{"coding":[{"code":"confirmed","display":"Confirmed","system":"http://terminology.hl7.org/CodeSystem/condition-ver-status"}]}}},{"resource":{"dateAsserted":"2026-10-14","dosage":[{"doseAndRate":[{"doseQuantity":{"code":"mg","system":"http://unitsofmeasure.org","unit":"mg","value":10}}],"route":{"coding":[{"code":"26643006","display":"Oral route","system":"http://snomed.info/sct"}]},"text":"10 mg PO daily","timing":{"repeat":{"frequency":1,"period":1,"periodUnit":"d"}}}],"id":"med-lisinopril","medicationCodeableConcept":{"coding":[{"code":"314076","display":"lisinopril 10 MG Oral Tablet","system":"http://www.nlm.nih.gov/research/umls/rxnorm"}],"text":"lisinopril 10 mg"},"meta":{"profile":["http://example.org/fhir/notes/StructureDefinition/note-medication"]},"reasonReference":[{"reference":"Condition/problem-htn"}],"resourceType":"MedicationStatement","status":"active","subject":{"reference":"Patient/patient-1"}}},{"resource":{"dateAsserted":"2026-10-14","dosage":[{"doseAndRate":[{"doseQuantity":{"code":"mg","system":"http://unitsofmeasure.org","unit":"mg","value":20}}],"route":{"coding":[{"code":"26643006","display":"Oral route","system":"http://snomed.info/sct"}]},"text":"20 mg PO nightly","timing":{"repeat":{"frequency":1,"period":1,"periodUnit":"d","when":["HS"]}}}],"id":"med-atorvastatin","medicationCodeableConcept":{"coding":[{"code":"617310","display":"atorvastatin 20 MG Oral Tablet","system":"http://www.nlm.nih.gov/research/umls/rxnorm"}],"text":"atorvastatin 20 mg"},"meta":{"profile":["http://example.org/fhir/notes/StructureDefinition/note-medication"]},"reasonReference":[{"reference":"Condition/problem-hld"}],"resourceType":"MedicationStatement","status":"active","subject":{"reference":"Patient/patient-1"}}}],"resourceType":"Bundle","type":"collection"}
```

## It does not conform yet

- Observation/bp-1: Observation.code: value does not match required pattern
- MedicationStatement/med-lisinopril: MedicationStatement.medication[x]: code not in required value set http://example.org/fhir/notes/ValueSet/note-medication-codes
- MedicationStatement/med-atorvastatin: MedicationStatement.medication[x]: code not in required value set http://example.org/fhir/notes/ValueSet/note-medication-codes

Fix these and answer with the complete corrected Bundle in ONE ```json block.
