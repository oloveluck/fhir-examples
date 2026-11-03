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

