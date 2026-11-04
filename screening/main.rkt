#lang racket/base

;;; main.rkt — a blood pressure screening, written in seven FHIR languages and composed by Racket:
;;; language-oriented programming, with FHIR's own languages.
;;;
;;;   profile.fsh    FHIR Shorthand     the data contract (a profile) and the clinic's records
;;;   forms.fhir6    FHIR R6 resources  the intake forms, checked against the FHIR model
;;;   intake.fml     FHIR Mapping Lang  form -> the profile's Observation
;;;   bp-panels.vcl  ValueSet Compose   which codes count as a blood pressure panel
;;;   screening.cql  CQL                the screening rule, per patient
;;;   readings.sof   SQL on FHIR        the readings as a flat table
;;;   app.rkt        fhir/capability    the composition served; the pipeline as the operation $screen
;;;
;;; Each file is a Racket module in its own language: compiled, and checked in that language's terms,
;;; when this program compiles (`raco make main.rkt`). pipeline.rkt composes them as ordinary values
;;; joined by FHIR operations; app.rkt declares the composition as a server and `$screen` as an
;;; operation, which this program applies in-process. The SEAMS are checked: the map against the
;;; structures FSH defined (fml/check), each mapped reading against the profile; and the module
;;; system is the FHIR registry — requiring a module makes what it defines resolvable by canonical.
;;;
;;;   racket main.rkt

(require racket/list racket/string
         "pipeline.rkt"
         (only-in "app.rkt" $screen)                       ; the pipeline as an operation value
         fhir/operation)

(module+ main
  (printf "intake: ~a forms mapped and valid against ~a\n" (length intake-readings) profile)
  (printf "panel codes (from bp-panels.vcl): ~a\n\n" (string-join panel-codes ", "))
  (printf "~a  ~a  ~a  ~a  ~a\n" "patient" "date      " "systolic" "diastolic" "hypertensive")
  (for ([r (in-list (sort readings string<? #:key (lambda (r) (format "~a ~a" (hash-ref r 'patient) (hash-ref r 'date)))))])
    (printf "~a  ~a  ~a       ~a        ~a\n"
            (pad (hash-ref r 'patient) 7) (hash-ref r 'date) (hash-ref r 'systolic) (hash-ref r 'diastolic)
            (if (hash-ref (screening (hash-ref r 'patient)) 'hypertensive) "yes" "no"))))

(define (pad s n) (string-append s (make-string (max 0 (- n (string-length s))) #\space)))

(module+ test
  (require rackunit json racket/runtime-path
           (only-in fml/operations)                              ; registers StructureMap/$transform
           (only-in fml/parser/parse parse-fml)
           (only-in fml/check check-map)
           (only-in fhir/result/result ok-value)
           (only-in fhir/diagnostic diagnostic-message diagnostic-loc loc-line)
           fhir/http/router)
  ;; the intake forms became valid screening readings
  (check-equal? (map (lambda (o) (hash-ref o 'id)) intake-readings) '("intake-ann-bp" "intake-bo-bp"))
  ;; the rule: Ann's highest systolic (clinic 152, intake 148) is hypertensive; Bo's (124) is not
  (check-true (hash-ref (screening "ann") 'hypertensive))
  (check-false (hash-ref (screening "bo") 'hypertensive))
  ;; the table: three readings, one per row
  (check-equal? (length readings) 3)
  (check-equal? (sort (map (lambda (r) (hash-ref r 'systolic)) readings) <) '(124 148 152))
  ;; the seam is checked: a map that writes an element the profile's structure lacks is reported at
  ;; its line, before any form is mapped — the profile resolves because profile.fsh is required
  (define broken
    (ok-value (parse-fml (string-append
      "map \"http://example.org/StructureMap/broken\" = \"Broken\"\n"
      "uses \"http://hl7.org/fhir/StructureDefinition/QuestionnaireResponse\" alias QR as source\n"
      "uses \"http://example.org/StructureDefinition/screening-blood-pressure\" alias ScreeningBP as target\n"
      "group g(source src : QR, target tgt : ScreeningBP) {\n"
      "  src -> tgt.status = 'final', tgt.code = cc('http://loinc.org', '85354-9');\n"
      "  src.item as item -> tgt.componnt as c, c.valueString = 'x';\n"
      "}\n") #:source "broken.map")))
  (define findings (check-map broken))
  (check-equal? (map (lambda (d) (loc-line (diagnostic-loc d))) findings) '(6))
  (check-regexp-match #rx"`componnt` is not an element of Observation" (diagnostic-message (car findings)))
  ;; the module registry is the canonical registry: requiring intake.fml registered its map, so the
  ;; operation finds it by url and answers what the module's procedure answers
  (define form (car (forms)))
  (define via-operation (apply-operation "StructureMap/$transform" form #:source "http://example.org/StructureMap/bp-intake"))
  (check-equal? (hash-ref via-operation 'id) "intake-ann-bp")
  ;; the pipeline as an operation: declared once in app.rkt, applied here in-process …
  (define (verdict p) (for/hash ([x (in-list (hash-ref p 'parameter))]) (values (hash-ref x 'name) (or (hash-ref x 'valueInteger #f) (hash-ref x 'valueBoolean #f)))))
  (check-equal? (hash-ref (verdict ($screen #:patient "ann")) "hypertensive") #t)
  (check-equal? (hash-ref (verdict (apply-operation "$screen" #:patient "bo")) "highest") 124)
  ;; … and served by the same declaration, its CapabilityStatement derived
  (define-runtime-path app-file "app.rkt")
  (define app (dynamic-require app-file 'app))
  (define (post path js) (let-values ([(st out) (handle app "POST" path '() (jsexpr->string js))]) (values st out)))
  (let-values ([(st cs) (handle app "GET" "/metadata" '() "")])
    (check-equal? st 200)
    (define rest (car (hash-ref cs 'rest)))
    (define definitions
      (append (for/list ([o (in-list (hash-ref rest 'operation '()))]) (hash-ref o 'definition))
              (for*/list ([r (in-list (hash-ref rest 'resource '()))] [o (in-list (hash-ref r 'operation '()))]) (hash-ref o 'definition))))
    (check-not-false (member "http://hl7.org/fhir/OperationDefinition/StructureMap-transform" definitions))
    (check-not-false (member "urn:fhir-capability:operation:screen" definitions)))
  (let-values ([(st obs) (post "/StructureMap/$transform"
                               (hasheq 'resourceType "Parameters"
                                       'parameter (list (hasheq 'name "source" 'valueUri "http://example.org/StructureMap/bp-intake")
                                                        (hasheq 'name "content" 'resource form))))])
    (check-equal? st 200)
    (check-equal? (hash-ref obs 'id) "intake-ann-bp"))
  (let-values ([(st p) (post "/$screen" (hasheq 'resourceType "Parameters" 'parameter (list (hasheq 'name "patient" 'valueString "ann"))))])
    (check-equal? st 200)
    (check-equal? (hash-ref (verdict p) "hypertensive") #t)))
