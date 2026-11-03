#lang racket/base

;;; pipeline.rkt — FHIR operations applied like functions, with no server.
;;;
;;; An operation is applied by reference to its OperationDefinition, its parameters given as keywords
;;; (fhir/operation). Here a QuestionnaireResponse is mapped to a Patient by an FML map
;;; (StructureMap/$transform), the Patient is validated (Resource/$validate), and its gender is
;;; checked against the core value set (ValueSet/$validate-code).
;;;
;;;   racket examples/pipeline.rkt

(require racket/file racket/string json
         fhir/operation
         (only-in fhir/conformance/operations ensure-valid)   ; loading these registers the operations
         (only-in fhir/terminology/operations)
         (only-in fml/operations))

(define qr (hasheq 'resourceType "QuestionnaireResponse" 'status "completed"
                   'item (list (hasheq 'linkId "patient"
                                       'item (list (hasheq 'linkId "patient.sex"
                                                           'answer (list (hasheq 'valueString "female"))))))))
;; the FML map from the fhir package's examples (its #lang line dropped)
(define fml (string-join (cdr (string-split (file->string (collection-file-path "qr2pat.fmlmap" "fhir" "examples")) "\n")) "\n"))

;; 1. apply an operation by reference: the OperationDefinition's canonical, then its parameters
(define patient
  (apply-operation "http://hl7.org/fhir/OperationDefinition/StructureMap-transform" qr #:srcMap fml))

;; 2. resolve once, then apply it like any procedure
(define transform (operation "StructureMap/$transform"))

;; 3. a pipeline: each result is the next step's subject; ensure-valid passes a valid resource on
(define checked
  (~> qr
      (transform #:srcMap fml)
      (ensure-valid)))

;; 4. results are FHIR resources: here the Parameters of $validate-code
(define verdict
  (apply-operation "ValueSet/$validate-code"
                   #:url "http://hl7.org/fhir/ValueSet/administrative-gender"
                   #:system "http://hl7.org/fhir/administrative-gender"
                   #:code (hash-ref checked 'gender)))

(module+ main
  (printf "transformed: ~a\n" (jsexpr->string patient))
  (printf "validated:   ~a\n" (jsexpr->string checked))
  (printf "gender valid: ~a\n"
          (for/first ([p (in-list (hash-ref verdict 'parameter))] #:when (equal? (hash-ref p 'name) "result"))
            (hash-ref p 'valueBoolean)))
  ;; $validate answers an OperationOutcome; ensure-valid turns its errors into an exception that
  ;; stops a pipeline, and a misapplied operation (a parameter it does not have) raises the same way
  (printf "an invalid Patient: ~a\n" (jsexpr->string (apply-operation "$validate" (hash-set patient 'gender "florp"))))
  (printf "a misapplied operation: ~a\n" (jsexpr->string (apply-operation/outcome "$validate" patient #:profle "x"))))
