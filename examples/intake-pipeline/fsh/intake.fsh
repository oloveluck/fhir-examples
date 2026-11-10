#lang fsh
Profile: IntakePatient
Parent: Patient
Id: intake-patient
Title: "Intake patient"
Description: "A patient from the intake form: name, gender and birth date are required."
* name 1..*
* gender 1..1
* birthDate 1..1

Instance: intake-good
InstanceOf: IntakePatient
* name.family = "Rivera"
* name.given = "Ana"
* gender = #female
* birthDate = "1950-05-01"
