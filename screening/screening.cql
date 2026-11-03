#lang cql
// screening.cql — Clinical Quality Language: the screening rule, over one patient's FHIR data.
// "Panel Codes" is a parameter: the program fills it from the value set in bp-panels.vcl.

library BloodPressureScreening version '1.0.0'

using FHIR version '4.0.1'

parameter "Panel Codes" List<System.String>

context Patient

define "Readings":
  [Observation] O
    where exists (O.code.coding C where C.code.value in "Panel Codes")

define "Systolic Values":
  "Readings" O
    return singleton from (O.component C
                             where exists (C.code.coding K where K.code.value = '8480-6')
                             return (C.value as FHIR.Quantity).value.value)

define "Highest Systolic": Max("Systolic Values")

define "Hypertensive": "Highest Systolic" >= 140
