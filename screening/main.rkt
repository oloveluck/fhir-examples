#lang racket/base

;;; main.rkt — a blood pressure screening, written in six FHIR languages and composed by Racket:
;;; language-oriented programming, with FHIR's own languages.
;;;
;;;   profile.fsh    FHIR Shorthand     the data contract (a profile) and the clinic's records
;;;   forms.fhir6    FHIR R6 resources  the intake forms, checked against the FHIR model
;;;   intake.fml     FHIR Mapping Lang  form -> the profile's Observation
;;;   bp-panels.vcl  ValueSet Compose   which codes count as a blood pressure panel
;;;   screening.cql  CQL                the screening rule, per patient
;;;   readings.sof   SQL on FHIR        the readings as a flat table
;;;   app.rkt        fhir/capability    the seventh: the same values served over HTTP
;;;
;;; Each file is a Racket module in its own language: compiled, and checked in that language's terms,
;;; when this program compiles (`raco make main.rkt`). Here they are ordinary values — the FSH
;;; module's `compiled` resources, the map's `transform`, the value set, the CQL library's `evaluate`,
;;; the view — joined by FHIR operations (fhir/operation) and plain Racket. The SEAMS between the
;;; languages are checked too: the map against the structures FSH defined (fml/check), each mapped
;;; reading against the profile, and the module registry is the FHIR canonical registry (requiring
;;; intake.fml makes its map resolvable by url, so `$transform #:source` finds it).
;;;
;;;   racket main.rkt

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
         (only-in fhir/terminology/operations $expand)
         (only-in sql-on-fhir/operations view-rows))

(define profile "http://example.org/StructureDefinition/screening-blood-pressure")

;; 0. The seam between FML and FSH: the map names the profile as its target structure, so it is
;;    checked against what FSH defined before any form is mapped — an element the structure lacks, a
;;    value of the wrong type, a required element no rule assigns, each positioned in intake.fml.
(define map-findings
  (parameterize ([current-data-source (resources->data-source clinic)])     ; where the profile lives
    (check-map bp-intake #:source "intake.fml")))
(unless (null? map-findings)
  (error 'screening "intake.fml does not fit the structures:\n~a" (string-join (map diagnostic->string map-findings) "\n")))

;; 1. Intake: each form is mapped (FML) and must satisfy the profile (FSH) — a reading that does not
;;    stops the program with an OperationOutcome saying why.
(define intake-readings
  (parameterize ([current-data-source (resources->data-source clinic)])
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
  (require rackunit json racket/runtime-path
           (only-in fml/parser/parse parse-fml)
           (only-in fhir/result/result ok-value)
           (only-in fhir/diagnostic diagnostic-message diagnostic-loc loc-line)
           fhir/http/router)
  ;; the intake forms became valid screening readings
  (check-equal? (map (lambda (o) (hash-ref o 'id)) intake-readings) '("intake-ann-bp" "intake-bo-bp"))
  ;; the seam is checked: a map that writes an element the profile's structure lacks is reported at
  ;; its line, before any form is mapped
  (define broken
    (ok-value (parse-fml (string-append
      "map \"http://example.org/StructureMap/broken\" = \"Broken\"\n"
      "uses \"http://hl7.org/fhir/StructureDefinition/QuestionnaireResponse\" alias QR as source\n"
      "uses \"http://example.org/StructureDefinition/screening-blood-pressure\" alias ScreeningBP as target\n"
      "group g(source src : QR, target tgt : ScreeningBP) {\n"
      "  src -> tgt.status = 'final', tgt.code = cc('http://loinc.org', '85354-9');\n"
      "  src.item as item -> tgt.componnt as c, c.valueString = 'x';\n"
      "}\n") #:source "broken.map")))
  (define findings (parameterize ([current-data-source (resources->data-source clinic)]) (check-map broken)))
  (check-equal? (map (lambda (d) (loc-line (diagnostic-loc d))) findings) '(6))
  (check-regexp-match #rx"`componnt` is not an element of Observation" (diagnostic-message (car findings)))
  ;; the module registry is the canonical registry: requiring intake.fml registered its map, so the
  ;; operation finds it by url and answers what the module's procedure answers
  (define form (car (forms)))
  (parameterize ([current-data-source (resources->data-source clinic)])
    (check-equal? (apply-operation "StructureMap/$transform" form #:source "http://example.org/StructureMap/bp-intake")
                  (intake->reading form)))
  ;; the seventh language: app.rkt serves the same values; its CapabilityStatement is derived from them
  (define-runtime-path app-file "app.rkt")
  (define app (dynamic-require app-file 'app))
  (define (post path js) (let-values ([(st out) (handle app "POST" path '() (jsexpr->string js))]) (values st out)))
  (let-values ([(st cs) (handle app "GET" "/metadata" '() "")])
    (check-equal? st 200)
    (define definitions
      (for*/list ([r (in-list (hash-ref (car (hash-ref cs 'rest)) 'resource '()))] [o (in-list (hash-ref r 'operation '()))])
        (hash-ref o 'definition)))
    (check-not-false (member "http://hl7.org/fhir/OperationDefinition/StructureMap-transform" definitions)))
  (let-values ([(st obs) (post "/StructureMap/$transform"
                               (hasheq 'resourceType "Parameters"
                                       'parameter (list (hasheq 'name "source" 'valueUri "http://example.org/StructureMap/bp-intake")
                                                        (hasheq 'name "content" 'resource form))))])
    (check-equal? st 200)
    (check-equal? (hash-ref obs 'resourceType) "Observation")
    (check-equal? (hash-ref obs 'id) "intake-ann-bp"))
  ;; the rule: Ann's highest systolic (clinic 152, intake 148) is hypertensive; Bo's (124) is not
  (define ann (screening (hasheq 'resourceType "Patient" 'id "ann")))
  (define bo (screening (hasheq 'resourceType "Patient" 'id "bo")))
  (check-true (hash-ref ann 'hypertensive))
  (check-false (hash-ref bo 'hypertensive))
  ;; the table: three readings, one per row
  (check-equal? (length readings) 3)
  (check-equal? (sort (map (lambda (r) (hash-ref r 'systolic)) readings) <) '(124 148 152)))
