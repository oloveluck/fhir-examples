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

