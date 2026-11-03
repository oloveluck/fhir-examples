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

