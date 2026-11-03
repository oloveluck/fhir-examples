#lang racket/base

;;; pipeline.rkt — FHIR operations as function calls, with no server.
;;;
;;; An operation is applied by reference to its OperationDefinition, with parameters, like a function
;;; call (fhir/operation). Here: a QuestionnaireResponse is mapped to a Patient by an FML map
;;; (StructureMap/$transform), the Patient is validated (Resource/$validate), and its gender is checked
;;; against the core value set (ValueSet/$validate-code).
;;;
;;;   racket examples/pipeline.rkt

(require racket/file racket/string json
         fhir/operation
         (only-in fhir/conformance/operations validated)   ; loading these registers the operations
         (only-in fhir/terminology/operations)
         (only-in fml/operations))

(define qr (hasheq 'resourceType "QuestionnaireResponse" 'status "completed"
                   'item (list (hasheq 'linkId "patient"
                                       'item (list (hasheq 'linkId "patient.sex"
                                                           'answer (list (hasheq 'valueString "female"))))))))
;; the FML map from the fhir package's examples (its #lang line dropped)
(define fml (string-join (cdr (string-split (file->string (collection-file-path "qr2pat.fmlmap" "fhir" "examples")) "\n")) "\n"))

;; 1. a function call: the operation by its canonical, the parameters by name
(define patient
  (call-operation "http://hl7.org/fhir/OperationDefinition/StructureMap-transform" qr "srcMap" fml))

;; 2. a pipeline: each step's result feeds the next; `validated` passes the resource on when it is valid
(define checked
  (pipeline qr
            (step (lookup-operation "StructureMap/$transform") "srcMap" fml)
            (validated)))

;; 3. results are FHIR resources: here the Parameters of $validate-code
(define verdict
  (call-operation "ValueSet/$validate-code" #f
                  "url" "http://hl7.org/fhir/ValueSet/administrative-gender"
                  "system" "http://hl7.org/fhir/administrative-gender"
                  "code" (hash-ref checked 'gender)))

(module+ main
  (printf "transformed: ~a\n" (jsexpr->string patient))
  (printf "validated:   ~a\n" (jsexpr->string checked))
  (printf "gender valid: ~a\n"
          (for/first ([p (in-list (hash-ref verdict 'parameter))] #:when (equal? (hash-ref p 'name) "result"))
            (hash-ref p 'valueBoolean)))
  ;; $validate's answer is an OperationOutcome (`validated` turns its errors into an exception
  ;; that stops a pipeline; a failed call — an unknown parameter — raises the same way)
  (printf "an invalid Patient: ~a\n"
          (jsexpr->string (call-operation "$validate" (hash-set patient 'gender "florp"))))
  (printf "a bad call:  ~a\n"
          (jsexpr->string (invoke/outcome (lookup-operation "$validate") patient "profle" "x"))))
