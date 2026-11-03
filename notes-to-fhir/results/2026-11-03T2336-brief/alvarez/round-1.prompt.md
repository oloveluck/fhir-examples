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

