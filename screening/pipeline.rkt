#lang racket/base

;;; pipeline.rkt — the screening composed: the six language modules as values, joined by FHIR
;;; operations. Requiring a module is enough for the others to find what it defines — the module
;;; system is the FHIR registry (fhir/registry): profile.fsh registers its profile, so
;;; `ensure-valid #:profile` and the map's `uses` resolve it; intake.fml registers its map, so
;;; `$transform #:source` finds it; bp-panels.vcl its value set. No data source to set up for context;
;;; the one `current-data-source` below is the DATA the rule and the view run over.

(require racket/list racket/string
         ;; the six languages, as modules
         (only-in "profile.fsh" [compiled clinic])            ; profile + patients + clinic readings
         (only-in "forms.fhir6" [->json forms])                ; intake forms
         (only-in "intake.fml" [transform intake->reading] [fml bp-intake])   ; the map: a procedure, and its AST
         (only-in "bp-panels.vcl" [valueset bp-panels])        ; the value set
         (only-in "screening.cql" [evaluate screen])           ; the CQL library, as a procedure
         (only-in "readings.sof" [->json view-definitions])    ; the view
         ;; FHIR operations, and where their data comes from
         fhir/operation fhir/data-source
         (only-in fml/check check-map)
         (only-in fhir/diagnostic diagnostic->string)
         (only-in fhir/conformance/operations ensure-valid)
         (only-in fhirpath/decimal fp-decimal? decimal->exact)
         (only-in fhir/terminology/operations $expand)
         (only-in sql-on-fhir/operations view-rows))

(provide profile clinic forms bp-intake intake-readings data panel-codes screening readings)

(define profile "http://example.org/StructureDefinition/screening-blood-pressure")

;; 0. The seam between FML and FSH: the map names the profile as its target structure, so it is
;;    checked against what FSH defined before any form is mapped — an element the structure lacks, a
;;    value of the wrong type, a required element no rule assigns, each positioned in intake.fml.
(define map-findings (check-map bp-intake #:source "intake.fml"))
(unless (null? map-findings)
  (error 'screening "intake.fml does not fit the structures:\n~a" (string-join (map diagnostic->string map-findings) "\n")))

;; 1. Intake: each form is mapped (FML) and must satisfy the profile (FSH) — a reading that does not
;;    stops the program with an OperationOutcome saying why.
(define intake-readings
  (for/list ([form (in-list (forms))])
    (~> form intake->reading (ensure-valid #:profile profile))))

;; everything the clinic now knows: the data
(define data (resources->data-source (append clinic intake-readings)))

;; 2. Terminology: the value set (VCL), expanded, gives the codes the CQL rule takes as a parameter.
(define panel-codes
  (for/list ([c (in-list (hash-ref (hash-ref ($expand #:valueSet bp-panels) 'expansion) 'contains))])
    (hash-ref c 'code)))

;; 3. The rule (CQL), per patient, over that patient's data.
(define (screening patient-id)
  (define patient (or ((data-source-read data) "Patient" patient-id)
                      (hasheq 'resourceType "Patient" 'id patient-id)))
  (define facts
    (screen (cons patient ((data-source-of-patient data) "Observation" patient-id))
            #:parameters (hash "Panel Codes" panel-codes)))
  (hash 'patient patient-id 'highest (number-of (hash-ref facts "Highest Systolic")) 'hypertensive (hash-ref facts "Hypertensive")))
;; a CQL number is a FHIRPath decimal; the program wants a Racket integer
(define (number-of v) (if (fp-decimal? v) (let ([x (decimal->exact v)]) (if (integer? x) (inexact->exact x) x)) v))

;; 4. The table (SQL on FHIR), with the rule's verdict alongside each patient's readings.
(define readings
  (parameterize ([current-data-source data])
    (view-rows (car (view-definitions)))))
