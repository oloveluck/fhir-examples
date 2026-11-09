#lang cql
library Intake version '1.0'
using FHIR version '4.0.1'
include FHIRHelpers version '4.0.1' called FHIRHelpers
context Patient
define "Age": AgeInYears()
define "Is 65 Or Older": AgeInYears() >= 65
