# Task: write one FHIR Shorthand (FSH) profile for minimal Common Oncology Data Elements (mCODE) Implementation Guide

The IG targets FHIR 4.0.1 and depends on: hl7.fhir.uv.genomics-reporting#2.0.0, hl7.fhir.us.core#6.1.0. Its canonical is http://hl7.org/fhir/us/mcode.

Write `Profile: CancerDiseaseStatus` with `Id: mcode-cancer-disease-status` (its url will be http://hl7.org/fhir/us/mcode/StructureDefinition/mcode-cancer-disease-status), and at least one example `Instance` of it that is valid against it. Use the IG's existing names below where they fit. Reply with ONE ```fsh code block holding all of it.

## What the IG says about this profile

A clinician's qualitative judgment on the current trend of the cancer, e.g., whether it is stable, worsening (progressing), or improving (responding). The judgment may be based a single type or multiple kinds of evidence, such as imaging data, assessment of symptoms, tumor markers, laboratory data, etc.

## The elements it constrains, in the IG's words

(The IG's published element descriptions; deciding the constraints is the task.)

- `Observation.extension`: (no description published)
- `Observation.extension:evidenceType`: (no description published)
- `Observation.status`: (no description published)
- `Observation.code`: (no description published)
- `Observation.subject`: (no description published) — Patient whose disease status is recorded.
- `Observation.focus`: (no description published)
- `Observation.effective[x]`: (no description published)
- `Observation.performer`: (no description published)
- `Observation.value[x]`: (no description published)

## Names already defined in this IG

Alias: LNC = http://loinc.org
Alias: SCT = http://snomed.info/sct
Alias: SCT_TBD = http://hl7.org/fhir/us/mcode/CodeSystem/snomed-requested-cs
Alias: UCUM = http://unitsofmeasure.org
Alias: ICD10CM = http://hl7.org/fhir/sid/icd-10-cm
Alias: ICD10PCS = http://www.cms.gov/Medicare/Coding/ICD10
Alias: RXN = http://www.nlm.nih.gov/research/umls/rxnorm
Alias: CPT = http://www.ama-assn.org/go/cpt
Alias: HGNC = http://www.genenames.org
Alias: HGVS = http://varnomen.hgvs.org
Alias: NULLFLAVOR = http://terminology.hl7.org/CodeSystem/v3-NullFlavor
Alias: DCM = http://dicom.nema.org/resources/ontology/DCM
Alias: GTR = http://www.ncbi.nlm.nih.gov/gtr
Alias: CLINVAR = http://www.ncbi.nlm.nih.gov/clinvar
Alias: SO = http://www.sequenceontology.org/
Alias: AJCC = http://cancerstaging.org
Alias: ENTREZ = https://www.ncbi.nlm.nih.gov/gene
Alias: NCIT = http://ncicb.nci.nih.gov/xml/owl/EVS/Thesaurus.owl
Alias: OmbRaceCat = urn:oid:2.16.840.1.113883.6.238
Alias: ICDO3 = http://terminology.hl7.org/CodeSystem/icd-o-3
Alias: UMLS = http://terminology.hl7.org/CodeSystem/umls
Alias: IDTYPE = http://terminology.hl7.org/CodeSystem/v2-0203
Alias: SPTY = http://terminology.hl7.org/CodeSystem/v2-0487
Alias: CondCat = http://terminology.hl7.org/CodeSystem/condition-category
Alias: ClinStatus = http://terminology.hl7.org/CodeSystem/condition-clinical
Alias: VerStatus = http://terminology.hl7.org/CodeSystem/condition-ver-status
Alias: ObsCat = http://terminology.hl7.org/CodeSystem/observation-category
Alias: ObsStatus = http://hl7.org/fhir/observation-status
Alias: ObsInt = http://terminology.hl7.org/CodeSystem/v3-ObservationInterpretation
Alias: DiagnosticService = http://terminology.hl7.org/CodeSystem/v2-0074
Alias: TimingAbbreviation = http://terminology.hl7.org/CodeSystem/v3-GTSAbbreviation
Alias: MedReqStatus = http://hl7.org/fhir/CodeSystem/medicationrequest-status
Alias: MedReqIntent = http://hl7.org/fhir/CodeSystem/medicationrequest-intent
Alias: MedReqCat = http://terminology.hl7.org/CodeSystem/medicationrequest-category
Alias: RefMeaning = http://terminology.hl7.org/CodeSystem/referencerange-meaning
Alias: AbsentReason = http://terminology.hl7.org/CodeSystem/data-absent-reason
Alias: MDR = http://terminology.hl7.org/CodeSystem/mdr
Alias: FMM = http://hl7.org/fhir/StructureDefinition/structuredefinition-fmm
Alias: CGMedicationRecommendation = http://hl7.org/fhir/uv/genomics-reporting/StructureDefinition/medication-recommendation
Alias: CGTherapeuticImplication = http://hl7.org/fhir/uv/genomics-reporting/StructureDefinition/therapeutic-implication
Alias: NCBI = http://www.ncbi.nlm.nih.gov/refseq
Alias: TMB = http://hl7.org/fhir/uv/genomics-reporting/StructureDefinition/tmb
Alias: MSI = http://hl7.org/fhir/uv/genomics-reporting/StructureDefinition/msi
Alias: FMM = http://hl7.org/fhir/StructureDefinition/structuredefinition-fmm
Alias: CGMedicationRecommendation = http://hl7.org/fhir/uv/genomics-reporting/StructureDefinition/medication-recommendation
Alias: CGTherapeuticImplication = http://hl7.org/fhir/uv/genomics-reporting/StructureDefinition/therapeutic-implication
Alias: NCBI = http://www.ncbi.nlm.nih.gov/refseq
Alias: TMB = http://hl7.org/fhir/uv/genomics-reporting/StructureDefinition/tmb
Alias: MSI = http://hl7.org/fhir/uv/genomics-reporting/StructureDefinition/msi
Alias: USCoreCondition = http://hl7.org/fhir/us/core/StructureDefinition/us-core-condition-problems-health-concerns
Alias: USCoreDiagnosticReportLab = http://hl7.org/fhir/us/core/StructureDefinition/us-core-diagnosticreport-lab
Alias: USCoreMedicationRequest = http://hl7.org/fhir/us/core/StructureDefinition/us-core-medicationrequest
Alias: USCorePatient = http://hl7.org/fhir/us/core/StructureDefinition/us-core-patient
Alias: USCorePractitioner = http://hl7.org/fhir/us/core/StructureDefinition/us-core-practitioner
Alias: USCoreProcedure = http://hl7.org/fhir/us/core/StructureDefinition/us-core-procedure
Alias: USCoreObservationLab = http://hl7.org/fhir/us/core/StructureDefinition/us-core-observation-lab
Alias: USCoreOrganization = http://hl7.org/fhir/us/core/StructureDefinition/us-core-organization
Alias: USCoreClinicalResult = http://hl7.org/fhir/us/core/StructureDefinition/us-core-observation-clinical-result
Alias: USCoreVitalSigns = http://hl7.org/fhir/us/core/StructureDefinition/us-core-vital-signs
Alias: USCoreObservationSimple = http://hl7.org/fhir/us/core/StructureDefinition/us-core-simple-observation
Alias: USCoreSpecimen = http://hl7.org/fhir/us/core/StructureDefinition/us-core-specimen
Alias: USCoreBirthSex = http://hl7.org/fhir/us/core/StructureDefinition/us-core-birthsex
Alias: USCoreRace = http://hl7.org/fhir/us/core/StructureDefinition/us-core-race
Alias: USCoreEthnicity = http://hl7.org/fhir/us/core/StructureDefinition/us-core-ethnicity

Profile MCODEPatientGroup
CodeSystem TG263CS
ValueSet TG263VS
Profile MCODEPatientBundle
Profile Comorbidities
Profile PrimaryCancerCondition
Profile SecondaryCancerCondition
Extension RelatedCondition
Extension RelatedConditionAbsent
Extension CancerDiseaseStatusEvidenceType
Extension HistologyMorphologyBehavior
Extension BodyLocationQualifier
Extension LateralityQualifier
Extension TreatmentTerminationReason
Extension ProcedureIntent
Extension NormalizationBasis
Profile GenomicRegionStudied
Profile GenomicVariant
Profile GenomicsReport
Profile TumorMarkerTest
Profile HumanSpecimen
Profile TumorMorphology
Profile HistologicBehaviorAndType
Profile HistologicGrade
Profile HistoryOfMetastaticCancer
ValueSet HistoryOfMetastaticMalignantNeoplasmVS
Profile CancerRelatedMedicationRequest
Profile CancerRelatedMedicationAdministration
Profile CancerPatient
Profile KarnofskyPerformanceStatus
Profile ECOGPerformanceStatus
Profile LanskyPlayPerformanceStatus
Profile DeauvilleScale
Profile BodySurfaceArea
Profile RadiotherapyCourseSummary
Extension RadiotherapyModalityAndTechnique
Extension RadiotherapyModality
Extension RadiotherapyTechnique
Extension RadiotherapySessions
Extension RadiotherapyDoseDeliveredToVolume
Profile RadiotherapyVolume
Profile CancerRiskAssessment
Profile RhabdomyosarcomaRiskAssessment
Profile ALLRiskAssessment
Profile CancerStage
Profile LymphomaStage
Profile TNMCategory
Profile TNMStageGroup
Profile TNMPrimaryTumorCategory
Profile TNMRegionalNodesCategory
Profile TNMDistantMetastasesCategory
Profile CancerRelatedSurgicalProcedure
Profile TumorSize
ValueSet TumorMorphologyCodeVS
ValueSet TumorMorphologyCodeMaxVS
Profile Tumor
Profile BodyStructureIdentifier
ValueSet SecondaryCancerDisorderVS
ValueSet MelanomaInSituDisorderVS
ValueSet CytologicEvidenceOfMalignancyVS
ValueSet HypereosinophilicSyndromeDisorderVS
ValueSet CarcinomaInSituDisorderVS
ValueSet BenignUncertainNeoplasmBrainCNSDisorderVS
ValueSet PrimaryCancerDisorderVS
ValueSet CancerDisorderVS
ValueSet HistologyMorphologyBehaviorVS
ValueSet PrimaryMalignantNeoplasmDisorderVS
ValueSet HumanSpecimenTypeVS
ValueSet TumorMarkerTestVS
ValueSet CancerBodyLocationVS
ValueSet ConditionStatusTrendVS
ValueSet ConditionStatusTrendMaxVS
ValueSet CancerDiseaseStatusEvidenceTypeVS
ValueSet CancerRelatedSurgicalProcedureVS
ValueSet BodyLocationAndLateralityQualifierVS
ValueSet LateralityQualifierVS
ValueSet BodyLocationQualifierVS
ValueSet TreatmentTerminationReasonVS
ValueSet ProcedureIntentVS
ValueSet TumorSizeUnitsVS
ValueSet TumorSizeMethodVS
ValueSet HistologicBehaviorAndTypeVS
ValueSet HistologicGradeVS
ValueSet HistologicGradingSystemVS
ValueSet NormalizationBasisVS
ValueSet LanskyPlayPerformanceStatusVS
ValueSet DeauvilleScaleVS
ValueSet TeleradiotherapyModalityVS
ValueSet BrachytherapyModalityVS
ValueSet RadiotherapyModalityVS
ValueSet TeleradiotherapyTechniqueVS
ValueSet TeleradiotherapyPhotonBeamTechniqueVS
ValueSet TeleradiotherapyElectronBeamTechniqueVS
ValueSet TeleradiotherapyNeutronTechniqueVS
ValueSet TeleradiotherapyCarbonIonBeamTechniqueVS
ValueSet TeleradiotherapyProtonBeamTechniqueVS
ValueSet BrachytherapyTechniqueVS
ValueSet BrachytherapyPermanentSeedsTechniqueVS
ValueSet BrachytherapyLowDoseRateTemporaryTechniqueVS
ValueSet BrachytherapyPulsedDoseRateTechniqueVS
ValueSet BrachytherapyHighDoseRateTechniqueVS
ValueSet BrachytherapyHighDoseRateElectronicTechniqueVS
ValueSet BrachytherapyRadiopharmaceuticalTechniqueVS
ValueSet RadiotherapyTechniqueVS
ValueSet RadiotherapyVolumeTypeVS
ValueSet RadiotherapyTreatmentLocationQualifierVS
ValueSet RadiotherapyTreatmentLocationVS
ValueSet CancerRiskAssessmentTypeVS
ValueSet RiskAssessmentValueVS
ValueSet RhabdomyosarcomaAssessmentValueVS
ValueSet ALLRiskAssessmentVS
ValueSet CancerStageTypeVS
ValueSet CancerStagingMethodVS
ValueSet CancerStageValueVS
ValueSet BinetStageValueVS
ValueSet BreslowDepthStageValueVS
ValueSet ClarkLevelValueVS
ValueSet ClinOrPathModifierVS
ValueSet FABClassificationValueVS
ValueSet FIGOStagingMethodVS
ValueSet FIGOStageValueVS
ValueSet GleasonGradeGroupValueVS
ValueSet LymphomaStagingMethodVS
ValueSet LymphomaStageValueVS
ValueSet LymphomaStageValueModifierVS
ValueSet MyelomaISSValueVS
ValueSet MyelomaRISSValueVS
ValueSet RaiStagingMethodVS
ValueSet RaiStageValueVS
ValueSet NeuroblastomaINSSValueVS
ValueSet NeuroblastomaINRGSSValueVS
ValueSet WilmsTumorStageValueVS
ValueSet WilmsTumorBodySiteVS
ValueSet LymphomaStageBulkyModifierVS
ValueSet RhabdomyosarcomaClinicalGroupValueVS
ValueSet CancerStagingPrognosticFactorTypeVS
ValueSet CancerStagingPrognosticFactorValueVS
ValueSet InternationalRetinoblastomaStageValueVS
ValueSet PRETEXTValueVS
ValueSet TNMStagingMethodVS
ValueSet TNMStageGroupStagingTypeVS
ValueSet TNMStageGroupStagingTypeMaxVS
ValueSet TNMStageGroupVS
ValueSet TNMStageGroupMaxVS
ValueSet TNMPrimaryTumorStagingTypeVS
ValueSet TNMPrimaryTumorStagingTypeMaxVS
ValueSet TNMPrimaryTumorCategoryVS
ValueSet TNMPrimaryTumorCategoryMaxVS
ValueSet TNMRegionalNodesStagingTypeVS
ValueSet TNMRegionalNodesStagingTypeMaxVS
ValueSet TNMRegionalNodesCategoryVS
ValueSet TNMRegionalNodesCategoryMaxVS
ValueSet TNMDistantMetastasesStagingTypeVS
ValueSet TNMDistantMetastasesStagingTypeMaxVS
ValueSet TNMDistantMetastasesCategoryVS
ValueSet TNMDistantMetastasesCategoryMaxVS
