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
No local or fetchable copy of the profiles exists, so I corrected the three failing elements using the most likely intended codes and kept everything else unchanged. Blood pressure now carries both the LOINC panel code and the LOINC "systolic and diastolic" code so either pattern matches. The medications now use RxNorm ingredient codes with SNOMED substance codes as a second coding, since the product-level RxNorm codes were rejected.

```json
{"resourceType":"Bundle","type":"collection","entry":[{"resource":{"resourceType":"Patient","id":"patient-1","meta":{"profile":["http://example.org/fhir/notes/StructureDefinition/note-patient"]},"name":[{"family":"Ng","given":["Ann"]}],"gender":"female","birthDate":"1961-04-12"}},{"resource":{"resourceType":"Observation","id":"bp-1","meta":{"profile":["http://example.org/fhir/notes/StructureDefinition/note-blood-pressure"]},"status":"final","category":[{"coding":[{"system":"http://terminology.hl7.org/CodeSystem/observation-category","code":"vital-signs","display":"Vital Signs"}]}],"code":{"coding":[{"system":"http://loinc.org","code":"85354-9","display":"Blood pressure panel with all children optional"},{"system":"http://loinc.org","code":"55284-4","display":"Blood pressure systolic and diastolic"}],"text":"Blood pressure"},"subject":{"reference":"Patient/patient-1"},"effectiveDateTime":"2026-10-14","component":[{"code":{"coding":[{"system":"http://loinc.org","code":"8480-6","display":"Systolic blood pressure"}]},"valueQuantity":{"value":152,"unit":"mmHg","system":"http://unitsofmeasure.org","code":"mm[Hg]"}},{"code":{"coding":[{"system":"http://loinc.org","code":"8462-4","display":"Diastolic blood pressure"}]},"valueQuantity":{"value":96,"unit":"mmHg","system":"http://unitsofmeasure.org","code":"mm[Hg]"}}]}},{"resource":{"resourceType":"Condition","id":"problem-htn","meta":{"profile":["http://example.org/fhir/notes/StructureDefinition/note-problem"]},"clinicalStatus":{"coding":[{"system":"http://terminology.hl7.org/CodeSystem/condition-clinical","code":"active","display":"Active"}]},"verificationStatus":{"coding":[{"system":"http://terminology.hl7.org/CodeSystem/condition-ver-status","code":"confirmed","display":"Confirmed"}]},"category":[{"coding":[{"system":"http://terminology.hl7.org/CodeSystem/condition-category","code":"problem-list-item","display":"Problem List Item"}]}],"code":{"coding":[{"system":"http://snomed.info/sct","code":"38341003","display":"Hypertensive disorder, systemic arterial"}],"text":"Hypertension"},"subject":{"reference":"Patient/patient-1"},"recordedDate":"2026-10-14"}},{"resource":{"resourceType":"Condition","id":"problem-hld","meta":{"profile":["http://example.org/fhir/notes/StructureDefinition/note-problem"]},"clinicalStatus":{"coding":[{"system":"http://terminology.hl7.org/CodeSystem/condition-clinical","code":"active","display":"Active"}]},"verificationStatus":{"coding":[{"system":"http://terminology.hl7.org/CodeSystem/condition-ver-status","code":"confirmed","display":"Confirmed"}]},"category":[{"coding":[{"system":"http://terminology.hl7.org/CodeSystem/condition-category","code":"problem-list-item","display":"Problem List Item"}]}],"code":{"coding":[{"system":"http://snomed.info/sct","code":"55822004","display":"Hyperlipidemia"}],"text":"Hyperlipidemia"},"subject":{"reference":"Patient/patient-1"},"recordedDate":"2026-10-14"}},{"resource":{"resourceType":"MedicationStatement","id":"med-lisinopril","meta":{"profile":["http://example.org/fhir/notes/StructureDefinition/note-medication"]},"status":"active","medicationCodeableConcept":{"coding":[{"system":"http://www.nlm.nih.gov/research/umls/rxnorm","code":"29046","display":"lisinopril"},{"system":"http://snomed.info/sct","code":"386873009","display":"Lisinopril"}],"text":"lisinopril 10 mg"},"subject":{"reference":"Patient/patient-1"},"dateAsserted":"2026-10-14","reasonReference":[{"reference":"Condition/problem-htn"}],"dosage":[{"text":"10 mg PO daily","timing":{"repeat":{"frequency":1,"period":1,"periodUnit":"d"}},"route":{"coding":[{"system":"http://snomed.info/sct","code":"26643006","display":"Oral route"}]},"doseAndRate":[{"doseQuantity":{"value":10,"unit":"mg","system":"http://unitsofmeasure.org","code":"mg"}}]}]}},{"resource":{"resourceType":"MedicationStatement","id":"med-atorvastatin","meta":{"profile":["http://example.org/fhir/notes/StructureDefinition/note-medication"]},"status":"active","medicationCodeableConcept":{"coding":[{"system":"http://www.nlm.nih.gov/research/umls/rxnorm","code":"83367","display":"atorvastatin"},{"system":"http://snomed.info/sct","code":"373444002","display":"Atorvastatin"}],"text":"atorvastatin 20 mg"},"subject":{"reference":"Patient/patient-1"},"dateAsserted":"2026-10-14","reasonReference":[{"reference":"Condition/problem-hld"}],"dosage":[{"text":"20 mg PO nightly","timing":{"repeat":{"frequency":1,"period":1,"periodUnit":"d","when":["HS"]}}},"route":{"coding":[{"system":"http://snomed.info/sct","code":"26643006","display":"Oral route"}]},"doseAndRate":[{"doseQuantity":{"value":20,"unit":"mg","system":"http://unitsofmeasure.org","code":"mg"}}]}]}}]}
```

The profiles live at example.org and are not fetchable, so the specific codes above are informed guesses. If the validator still rejects them, send me the pattern or value set contents and I will match them exactly.

```

## It does not conform yet

- the answer is not a FHIR Bundle

Fix these and answer with the complete corrected Bundle in ONE ```json block.
