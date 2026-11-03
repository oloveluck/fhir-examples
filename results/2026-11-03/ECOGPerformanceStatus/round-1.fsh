Profile: ECOGPerformanceStatus
Parent: Observation
Id: mcode-ecog-performance-status
Title: "ECOG Performance Status Profile"
Description: "The Eastern Cooperative Oncology Group (ECOG) Performance Status represents the patient's functional status and is used to determine their ability to tolerate therapies in serious illness, specifically for chemotherapy. (Definition from: [LOINC](https://loinc.org/89262-0/))"
* ^extension[FMM].valueInteger = 2
* ^status = #draft
* basedOn and partOf and interpretation MS
* basedOn only Reference(ServiceRequest or CarePlan)
* partOf only Reference(Procedure)
* code 1..1 MS
* code = LNC#89247-1 // ECOG Performance Status score
* subject 1..1 MS
* subject only Reference(CancerPatient)
* subject ^definition = "Patient whose performance status is recorded."
* effective[x] 1..1 MS
* effective[x] only dateTime or Period
* value[x] 1..1 MS
* value[x] only integer
* value[x] ^short = "ECOG performance status score (0 through 5)"
* valueInteger obeys ecog-value-range
* interpretation 0..1
* interpretation from ECOGPerformanceStatusInterpretationVS (required)
* interpretation ^short = "Interpretation of the ECOG score, using the LOINC answer list for ECOG Performance Status"

Invariant: ecog-value-range
Description: "The ECOG Performance Status score must be an integer between 0 and 5, inclusive."
Severity: #error
Expression: "$this >= 0 and $this <= 5"
XPath: ". >= 0 and . <= 5"

ValueSet: ECOGPerformanceStatusInterpretationVS
Id: mcode-ecog-performance-status-interpretation-vs
Title: "ECOG Performance Status Interpretation Value Set"
Description: "Interpretations of the ECOG Performance Status score, drawn from the LOINC answer list (LL529-9) for ECOG Performance Status."
* ^status = #draft
* LNC#LA9622-7 "Fully active, able to carry on all pre-disease performance without restriction"
* LNC#LA9623-5 "Restricted in physically strenuous activity but ambulatory and able to carry out work of a light or sedentary nature, e.g., light house work, office work"
* LNC#LA9624-3 "Ambulatory and capable of all selfcare but unable to carry out any work activities. Up and about more than 50% of waking hours"
* LNC#LA9625-0 "Capable of only limited selfcare, confined to bed or chair more than 50% of waking hours"
* LNC#LA9626-8 "Completely disabled. Cannot carry on any selfcare. Totally confined to bed or chair"
* LNC#LA9627-6 "Dead"

Instance: cancer-patient-jenny-m
InstanceOf: CancerPatient
Usage: #example
Description: "Example cancer patient referenced by the ECOG performance status example."
* identifier.use = #usual
* identifier.type = IDTYPE#MR "Medical Record Number"
* identifier.system = "http://hospital.example.org"
* identifier.value = "m123"
* name.family = "M"
* name.given = "Jenny"
* gender = #female
* birthDate = "1965-01-01"

Instance: ecog-performance-status-jenny-m
InstanceOf: ECOGPerformanceStatus
Usage: #example
Description: "Example of an ECOG Performance Status observation for a patient who is restricted in strenuous activity but fully ambulatory."
* status = #final
* category = ObsCat#survey "Survey"
* code = LNC#89247-1 "ECOG Performance Status score"
* subject = Reference(cancer-patient-jenny-m)
* effectiveDateTime = "2024-03-14"
* valueInteger = 1
* interpretation = LNC#LA9623-5 "Restricted in physically strenuous activity but ambulatory and able to carry out work of a light or sedentary nature, e.g., light house work, office work"
