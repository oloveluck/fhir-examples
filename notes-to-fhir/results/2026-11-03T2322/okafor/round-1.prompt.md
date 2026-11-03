Turn this clinic note into FHIR R4 resources that conform to the clinic's profiles.

The profiles and the codes they allow, in FHIR Shorthand (FSH). The IG's canonical is http://example.org/fhir/notes, so a profile's url is http://example.org/fhir/notes/StructureDefinition/<Id>:

```fsh
// The contract a clinic note is turned into: four profiles and the codes they allow. FHIR R4.

Alias: $loinc = http://loinc.org
Alias: $sct = http://snomed.info/sct
Alias: $rxnorm = http://www.nlm.nih.gov/research/umls/rxnorm
Alias: $ucum = http://unitsofmeasure.org
Alias: $clinical = http://terminology.hl7.org/CodeSystem/condition-clinical

Profile: NotePatient
Parent: Patient
Id: note-patient
Title: "Patient"
Description: "The patient the note is about."
* name 1..*
* name.family 1..1
* name.given 1..*
* gender 1..1
* birthDate 1..1

Profile: NoteBloodPressure
Parent: Observation
Id: note-blood-pressure
Title: "Blood pressure"
Description: "A blood pressure measured at the visit: one systolic and one diastolic reading in mm[Hg]."
* status = #final
* code = $loinc#85354-9 "Blood pressure panel"
* subject 1..1
* subject only Reference(NotePatient)
* effective[x] 1..1
* effective[x] only dateTime
* component ^slicing.discriminator.type = #pattern
* component ^slicing.discriminator.path = "code"
* component ^slicing.rules = #open
* component contains systolic 1..1 and diastolic 1..1
* component[systolic].code = $loinc#8480-6 "Systolic blood pressure"
* component[systolic].value[x] only Quantity
* component[systolic].valueQuantity.system = $ucum
* component[systolic].valueQuantity.code = #mm[Hg]
* component[diastolic].code = $loinc#8462-4 "Diastolic blood pressure"
* component[diastolic].value[x] only Quantity
* component[diastolic].valueQuantity.system = $ucum
* component[diastolic].valueQuantity.code = #mm[Hg]

Profile: NoteProblem
Parent: Condition
Id: note-problem
Title: "Problem"
Description: "A diagnosis on the patient's problem list."
* subject 1..1
* subject only Reference(NotePatient)
* code 1..1
* code from NoteProblemCodes (required)
* clinicalStatus 1..1

Profile: NoteMedication
Parent: MedicationStatement
Id: note-medication
Title: "Medication"
Description: "A medication the patient takes, with its dose as written in the note."
* subject only Reference(NotePatient)
* medication[x] only CodeableConcept
* medicationCodeableConcept from NoteMedicationCodes (required)
* dosage 1..1
* dosage.text 1..1

ValueSet: NoteProblemCodes
Id: note-problem-codes
Title: "Problems"
Description: "The diagnoses this clinic codes."
* $sct#38341003 "Hypertensive disorder"
* $sct#44054006 "Diabetes mellitus type 2"
* $sct#55822004 "Hyperlipidemia"
* $sct#195967001 "Asthma"

ValueSet: NoteMedicationCodes
Id: note-medication-codes
Title: "Medications"
Description: "The medications this clinic codes (RxNorm ingredients)."
* $rxnorm#29046 "lisinopril"
* $rxnorm#6809 "metformin"
* $rxnorm#83367 "atorvastatin"
* $rxnorm#435 "albuterol"
* $rxnorm#17767 "amlodipine"
```

Rules:
- Answer with ONE ```json block: a FHIR Bundle of type "collection", one entry per resource (each entry has `resource`).
- Exactly one NotePatient. Every other resource's subject is a reference to it: "Patient/<its id>".
- Every resource declares its profile in meta.profile.
- Use only codes from the value sets above. Leave out what the profiles do not cover (other labs and vitals, family history, conditions the note says the patient does not have).
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

