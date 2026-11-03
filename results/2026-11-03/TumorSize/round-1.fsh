// ---------------------------------------------------------------------------
// Tumor Size
// ---------------------------------------------------------------------------

Invariant: mcode-tumor-size-focus-or-specimen
Description: "A tumor size observation SHALL NOT have both a focus (tumor still in the body) and a specimen (tumor removed from the body)."
Severity: #error
Expression: "focus.empty() or specimen.empty()"

Profile: TumorSize
Parent: Observation
Id: mcode-tumor-size
Title: "Tumor Size Profile"
Description: "Records the dimensions of a tumor"
* obeys mcode-tumor-size-focus-or-specimen
* code = SCT#246116008 "Lesion size"
* code MS
* subject 1..1 MS
* subject only Reference(CancerPatient)
* subject ^short = "The patient whose tumor was measured"
* subject ^definition = "The patient whose tumor was measured. SHALL be a Patient resource conforming to CancerPatient."
* focus 0..1 MS
* focus only Reference(Tumor)
* focus ^short = "Identifies a tumor that has NOT been removed from the body"
* focus ^definition = "Reference to a BodyStructure resource conforming to Tumor."
* focus ^comment = "Use only when the tumor has not been removed from the body. If the tumor has been removed, use specimen instead and leave focus empty."
* effective[x] only dateTime or Period
* effective[x] MS
* method MS
* method from TumorSizeMethodVS (extensible)
* method ^short = "Method for measuring the tumor"
* method ^comment = "Tumors are typically measured via gross pathology after excision, or via diagnostic imaging or physical exam prior to removal. If specimen is set, method is expected to be a gross pathology code. If focus is set, method is expected to be a type of diagnostic imaging or physical exam."
* specimen 0..1 MS
* specimen only Reference(HumanSpecimen)
* specimen ^short = "Identifies a tumor that has been removed from the body"
* specimen ^definition = "Reference to a Specimen resource consistent with HumanSpecimen with type = http://terminology.hl7.org/CodeSystem/v2-0487#TUMOR."
* specimen ^comment = "Use specimen only when the tumor has been removed from the body. If the tumor has not been removed, use focus instead and leave specimen empty."
* component MS
* component ^slicing.discriminator.type = #pattern
* component ^slicing.discriminator.path = "code"
* component ^slicing.rules = #open
* component ^slicing.description = "Slice based on the component.code pattern"
* component contains
    tumorLongestDimension 1..1 MS and
    tumorOtherDimension 0..2 MS
* component[tumorLongestDimension] ^short = "Longest tumor dimension (cm or mm)"
* component[tumorLongestDimension] ^definition = "The longest tumor dimension in cm or mm."
* component[tumorLongestDimension].code = LNC#33728-7 "Size.maximum dimension in Tumor"
* component[tumorLongestDimension].code MS
* component[tumorLongestDimension].value[x] 1..1 MS
* component[tumorLongestDimension].value[x] only Quantity
* component[tumorLongestDimension].valueQuantity from TumorSizeUnitsVS (required)
* component[tumorOtherDimension] ^short = "2nd or 3rd tumor dimension (cm or mm)"
* component[tumorOtherDimension] ^definition = "The second or third tumor dimension in cm or mm."
* component[tumorOtherDimension] ^comment = "Additional tumor dimensions should be ordered from largest to smallest."
* component[tumorOtherDimension].code = LNC#33729-5 "Size additional dimension in Tumor"
* component[tumorOtherDimension].code MS
* component[tumorOtherDimension].value[x] 1..1 MS
* component[tumorOtherDimension].value[x] only Quantity
* component[tumorOtherDimension].valueQuantity from TumorSizeUnitsVS (required)

// ---------------------------------------------------------------------------
// Examples
// ---------------------------------------------------------------------------

Instance: tumor-size-imaging-example
InstanceOf: TumorSize
Usage: #example
Title: "Tumor Size (in situ, measured by imaging)"
Description: "Three-dimensional size of a breast tumor measured by diagnostic imaging while still in the body. The tumor is identified via focus, so specimen is left empty."
* status = #final
* code = SCT#246116008 "Lesion size"
* subject = Reference(cancer-patient-eve-anyperson)
* focus = Reference(tumor-left-breast-eve-anyperson)
* effectiveDateTime = "2024-03-15"
* method = SCT#363679005 "Imaging (procedure)"
* component[tumorLongestDimension].code = LNC#33728-7 "Size.maximum dimension in Tumor"
* component[tumorLongestDimension].valueQuantity = 2.5 'cm' "cm"
* component[tumorOtherDimension][0].code = LNC#33729-5 "Size additional dimension in Tumor"
* component[tumorOtherDimension][0].valueQuantity = 1.8 'cm' "cm"
* component[tumorOtherDimension][1].code = LNC#33729-5 "Size additional dimension in Tumor"
* component[tumorOtherDimension][1].valueQuantity = 12 'mm' "mm"

Instance: cancer-patient-eve-anyperson
InstanceOf: CancerPatient
Usage: #example
Title: "Cancer Patient Eve Anyperson"
Description: "Patient referenced by the tumor size example."
* identifier.use = #usual
* identifier.type = IDTYPE#MR "Medical Record Number"
* identifier.system = "http://hospital.example.org/mrn"
* identifier.value = "MRN-0001234"
* name.family = "Anyperson"
* name.given = "Eve"
* gender = #female
* birthDate = "1975-06-21"

Instance: tumor-left-breast-eve-anyperson
InstanceOf: Tumor
Usage: #example
Title: "Tumor in Left Breast of Eve Anyperson"
Description: "Tumor body structure referenced as the focus of the tumor size example."
* identifier.system = "http://hospital.example.org/tumor-ids"
* identifier.value = "TUMOR-0001"
* morphology = SCT#86049000 "Malignant neoplasm, primary (morphologic abnormality)"
* location = SCT#76752008 "Breast structure (body structure)"
* description = "Primary tumor in the upper outer quadrant of the left breast"
* patient = Reference(cancer-patient-eve-anyperson)
