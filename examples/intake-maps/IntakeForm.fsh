// The structure the front desk fills in: a logical model, not a FHIR resource.
Logical: IntakeForm
Id: IntakeForm
Title: "Blood-pressure intake form"
Description: "One blood-pressure reading as the front desk records it."
* patientId 1..1 string "The patient's record id"
* measured 1..1 dateTime "When the reading was taken"
* systolic 1..1 integer "Systolic pressure, mm[Hg]"
* diastolic 1..1 integer "Diastolic pressure, mm[Hg]"

// The structure the clinic keeps: a profile of Observation.
Profile: ScreeningBP
Parent: Observation
Id: ScreeningBP
Title: "Screening blood pressure"
Description: "A blood-pressure panel from a screening intake."
* status = #final
* code = http://loinc.org#85354-9
* subject 1..1
* effective[x] 1..1
* effective[x] only dateTime
* component 2..*

// An intake form as the desk recorded it: what the map transforms, what `check` validates.
Instance: intake-1
InstanceOf: IntakeForm
Usage: #example
* patientId = "p1"
* measured = "2024-03-01T09:00:00Z"
* systolic = 120
* diastolic = 80
