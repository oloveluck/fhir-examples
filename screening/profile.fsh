#lang fsh
// profile.fsh — the clinic's data contract, in FHIR Shorthand: what a screening blood pressure is,
// and the patients and readings the clinic already has.

Alias: $loinc = http://loinc.org
Alias: $ucum = http://unitsofmeasure.org

Profile: ScreeningBloodPressure
Parent: Observation
Id: screening-blood-pressure
Title: "Screening blood pressure"
Description: "A blood pressure panel taken at a screening visit: one systolic and one diastolic reading in mm[Hg]."
* status = #final
* code = $loinc#85354-9 "Blood pressure panel"
* subject 1..1
* effective[x] 1..1
* component ^slicing.discriminator.type = #pattern
* component ^slicing.discriminator.path = "code"
* component ^slicing.rules = #open
* component contains systolic 1..1 and diastolic 1..1
* component[systolic].code = $loinc#8480-6 "Systolic blood pressure"
* component[systolic].value[x] only Quantity
* component[diastolic].code = $loinc#8462-4 "Diastolic blood pressure"
* component[diastolic].value[x] only Quantity

Instance: ann
InstanceOf: Patient
* name.family = "Ng"
* name.given = "Ann"
* gender = #female

Instance: bo
InstanceOf: Patient
* name.family = "Okafor"
* name.given = "Bo"
* gender = #male

Instance: ann-clinic-1
InstanceOf: ScreeningBloodPressure
* subject = Reference(ann)
* effectiveDateTime = "2026-09-14"
* component[systolic].valueQuantity = 152 $ucum#mm[Hg] "mm[Hg]"
* component[diastolic].valueQuantity = 96 $ucum#mm[Hg] "mm[Hg]"
