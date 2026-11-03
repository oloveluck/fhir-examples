Profile: CancerDiseaseStatus
Parent: USCoreObservationSimple
Id: mcode-cancer-disease-status
Title: "Cancer Disease Status Profile"
Description: "A clinician's qualitative judgment on the current trend of the cancer, e.g., whether it is stable, worsening (progressing), or improving (responding). The judgment may be based a single type or multiple kinds of evidence, such as imaging data, assessment of symptoms, tumor markers, laboratory data, etc."
* ^extension[FMM].valueInteger = 4
* ^status = #active
* ^version = "4.0.0"
* ^publisher = "HL7 International / Clinical Interoperability Council"
* extension contains CancerDiseaseStatusEvidenceType named evidenceType 0..* MS
* extension[evidenceType] ^short = "Cancer Disease Status Evidence Type"
* extension[evidenceType] ^definition = "Categorization of the kind of evidence used as input to the clinical judgment. This corresponds to both the S and O in SOAP."
* status MS
* status ^short = "Status of the disease status observation (e.g., final, amended)"
* category MS
* category ^short = "Classification of the observation; at least one category is required by US Core Simple Observation"
* code MS
* code = LNC#88040-1 "Response to cancer treatment"
* code ^short = "Code representing the disease status assessment (fixed to LOINC 88040-1)"
* code ^definition = "Fixed to LOINC 88040-1, Response to cancer treatment. The code represents the clinician's assessment of the trend of the cancer condition."
* subject 1..1 MS
* subject only Reference(CancerPatient)
* subject ^short = "Patient whose disease status is recorded"
* subject ^definition = "Patient whose disease status is recorded."
* focus MS
* focus only Reference(PrimaryCancerCondition or SecondaryCancerCondition)
* focus ^short = "The cancer condition whose status is being assessed"
* focus ^definition = "The cancer condition (primary or secondary) that is the subject of this disease status assessment. If focus is omitted, the disease status applies to the patient's primary cancer condition."
* effective[x] 1..1 MS
* effective[x] only dateTime or Period
* effective[x] ^short = "The date or period during which the disease status was assessed"
* effective[x] ^definition = "The clinically relevant time or time period for the assessment of the disease status. Because disease status is a point-in-time judgment, a dateTime is expected in most cases; a Period may be used when the judgment spans a period of observation."
* performer MS
* performer only Reference(USCorePractitioner)
* performer ^short = "Clinician who made the disease status judgment"
* performer ^definition = "The practitioner responsible for the qualitative judgment of the cancer's trend."
* value[x] 1..1 MS
* value[x] only CodeableConcept
* value[x] from ConditionStatusTrendVS (extensible)
* value[x] ^binding.extension[+].url = "http://hl7.org/fhir/StructureDefinition/elementdefinition-maxValueSet"
* value[x] ^binding.extension[=].valueCanonical = Canonical(ConditionStatusTrendMaxVS)
* value[x] ^short = "Current trend of the cancer condition (e.g., improved, stable, worsened)"
* value[x] ^definition = "The clinician's qualitative judgment of the current trend of the cancer condition. The value MUST be drawn from the Condition Status Trend value set where possible; codes outside that set MUST be drawn from the Condition Status Trend Maximum value set."
* valueCodeableConcept ^sliceName = "valueCodeableConcept"

Instance: cancer-disease-status-improved-jenny-m
InstanceOf: CancerDiseaseStatus
Usage: #example
Title: "Cancer Disease Status Example: Improving on Imaging"
Description: "Example of a clinician's judgment that the patient's primary cancer is improving, based on imaging evidence."
* extension[evidenceType].valueCodeableConcept = SCT#363679005 "Imaging (procedure)"
* status = #final
* category = ObsCat#exam "Exam"
* code = LNC#88040-1 "Response to cancer treatment"
* subject = Reference(Patient/cancer-patient-jenny-m) "Jenny M"
* focus = Reference(Condition/primary-cancer-condition-jenny-m)
* effectiveDateTime = "2024-03-15"
* performer = Reference(Practitioner/us-core-practitioner-kyle-anydoc) "Dr. Kyle Anydoc"
* valueCodeableConcept = SCT#268910001 "Patient's condition improved (finding)"
