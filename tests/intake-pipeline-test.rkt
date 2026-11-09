#lang racket/base

;;; intake-pipeline-test.rkt — the fhir-authoring skill's multi-language example runs as it says:
;;; a QuestionnaireResponse mapped by FML, validated against an FSH profile, judged by CQL.

(require rackunit racket/runtime-path json)
(define-runtime-path dir "../examples/intake-pipeline")
(define intake (dynamic-require (build-path dir "main.rkt") 'intake))
(define qr (call-with-input-file (build-path dir "qr.json") read-json))

(define-values (patient old?) (intake qr))
(check-equal? (hash-ref patient 'birthDate) "1950-05-01")
(check-equal? old? "true")
;; without a birth date the Patient breaks IntakePatient, and the error says so
(define no-birth (hash-set qr 'item (filter (lambda (i) (not (equal? (hash-ref i 'linkId) "birthDate"))) (hash-ref qr 'item))))
(check-exn #rx"invalid Patient against [^ ]*/StructureDefinition/[^:]*:.*birthDate" (lambda () (intake no-birth)))
