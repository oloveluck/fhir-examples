#lang racket/base

;;; main.rkt — a blood pressure screening, written in six FHIR languages and composed by Racket.
;;;
;;;   profile.fsh    FHIR Shorthand     the data contract (a profile) and the clinic's records
;;;   forms.fhir6    FHIR R6 resources  the intake forms, checked against the FHIR model
;;;   intake.fml     FHIR Mapping Lang  form -> Observation
;;;   bp-panels.vcl  ValueSet Compose   which codes count as a blood pressure panel
;;;   screening.cql  CQL                the screening rule, per patient
;;;   readings.sof   SQL on FHIR        the readings as a flat table
;;;
;;; Each file is a Racket module in its own language: compiled, and checked in that language's terms,
;;; when this program compiles (`raco make main.rkt`). Here they are ordinary values — the FSH
;;; module's `compiled` resources, the map's `transform`, the value set, the CQL library's `evaluate`,
;;; the view — joined by FHIR operations (fhir/operation) and plain Racket.
;;;
;;;   racket main.rkt

(require racket/list racket/string
         ;; the six languages, as modules
         (only-in "profile.fsh" [compiled clinic])            ; profile + patients + clinic readings
         (only-in "forms.fhir6" [->json forms])                ; intake forms
         (only-in "intake.fml" [transform intake->reading])    ; the map, as a procedure
         (only-in "bp-panels.vcl" [valueset bp-panels])        ; the value set
         (only-in "screening.cql" [evaluate screen])           ; the CQL library, as a procedure
         (only-in "readings.sof" [->json view-definitions])    ; the view
         ;; FHIR operations, and where their data comes from
         fhir/operation fhir/data-source
         (only-in fhir/conformance/operations ensure-valid)
         (only-in fhir/terminology/operations $expand)
         (only-in sql-on-fhir/operations view-rows))

(define profile "http://example.org/StructureDefinition/screening-blood-pressure")

;; 1. Intake: each form is mapped (FML) and must satisfy the profile (FSH) — a reading that does not
;;    stops the program with an OperationOutcome saying why.
(define intake-readings
  (parameterize ([current-data-source (resources->data-source clinic)])     ; where the profile lives
    (for/list ([form (in-list (forms))])
      (~> form intake->reading (ensure-valid #:profile profile)))))

;; everything the clinic now knows
(define data (resources->data-source (append clinic intake-readings)))

;; 2. Terminology: the value set (VCL), expanded, gives the codes the CQL rule takes as a parameter.
(define panel-codes
  (for/list ([c (in-list (hash-ref (hash-ref ($expand #:valueSet bp-panels) 'expansion) 'contains))])
    (hash-ref c 'code)))

;; 3. The rule (CQL), per patient, over that patient's data.
(define (screening patient)
  (define id (hash-ref patient 'id))
  (define facts
    (screen (cons patient ((data-source-of-patient data) "Observation" id))
            #:parameters (hash "Panel Codes" panel-codes)))
  (hash 'patient id 'highest (hash-ref facts "Highest Systolic") 'hypertensive (hash-ref facts "Hypertensive")))

;; 4. The table (SQL on FHIR), with the rule's verdict alongside each patient's readings.
(define readings
  (parameterize ([current-data-source data])
    (view-rows (car (view-definitions)))))

(module+ main
  (printf "intake: ~a forms mapped and valid against ~a\n" (length intake-readings) profile)
  (printf "panel codes (from bp-panels.vcl): ~a\n\n" (string-join panel-codes ", "))
  (define verdicts (for/hash ([p (in-list ((data-source-all data) "Patient"))])
                     (define s (screening p)) (values (hash-ref s 'patient) s)))
  (printf "~a  ~a  ~a  ~a  ~a\n" "patient" "date      " "systolic" "diastolic" "hypertensive")
  (for ([r (in-list (sort readings string<? #:key (lambda (r) (format "~a ~a" (hash-ref r 'patient) (hash-ref r 'date)))))])
    (printf "~a  ~a  ~a       ~a        ~a\n"
            (pad (hash-ref r 'patient) 7) (hash-ref r 'date) (hash-ref r 'systolic) (hash-ref r 'diastolic)
            (if (hash-ref (hash-ref verdicts (hash-ref r 'patient)) 'hypertensive) "yes" "no"))))

(define (pad s n) (string-append s (make-string (max 0 (- n (string-length s))) #\space)))

(module+ test
  (require rackunit)
  ;; the intake forms became valid screening readings
  (check-equal? (map (lambda (o) (hash-ref o 'id)) intake-readings) '("intake-ann-bp" "intake-bo-bp"))
  ;; the rule: Ann's highest systolic (clinic 152, intake 148) is hypertensive; Bo's (124) is not
  (define ann (screening (hasheq 'resourceType "Patient" 'id "ann")))
  (define bo (screening (hasheq 'resourceType "Patient" 'id "bo")))
  (check-true (hash-ref ann 'hypertensive))
  (check-false (hash-ref bo 'hypertensive))
  ;; the table: three readings, one per row
  (check-equal? (length readings) 3)
  (check-equal? (sort (map (lambda (r) (hash-ref r 'systolic)) readings) <) '(124 148 152)))
