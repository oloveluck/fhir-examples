#lang racket/base

;;; tests.rkt — the pipeline's one gate, `raco test tests.rkt` (copy it with the template and change
;;; the expectations with the files): the FSH project checks clean, the example meant to fail fails at
;;; its line, the map's result holds to the profile, and main.rkt answers on either side of the
;;; 65th birthday. Each step is the command fhir-authoring runs by hand, here as a check.

(require rackunit racket/runtime-path json
         (only-in fsh/check check-fsh-project check-report-diagnostics)
         (only-in fhir/diagnostic diagnostic-message diagnostic-severity diagnostic-loc loc-line))

(define-runtime-path here ".")
(define (at . parts) (apply build-path here parts))
(define (errors-of report) (filter (lambda (d) (eq? (diagnostic-severity d) 'error)) (check-report-diagnostics report)))

;; raco fsh check fsh: the profile and its valid example, no error
(check-equal? (map diagnostic-message (errors-of (check-fsh-project (at "fsh")))) '())

;; raco fsh check fsh-invalid --context fsh: the example meant to fail, at its instance
(define bad (errors-of (check-fsh-project (at "fsh-invalid") #:context (list (at "fsh")))))
(check-equal? (length bad) 1)
(check-regexp-match #rx"intake-bad: Patient[.]birthDate: minimum required = 1" (diagnostic-message (car bad)))
(check-equal? (loc-line (diagnostic-loc (car bad))) 3)

;; main.rkt: the map, validated against IntakePatient, then CQL — on either side of the birthday
(define intake (dynamic-require (at "main.rkt") 'intake))
(define qr (call-with-input-file (at "qr.json") read-json))
(define-values (patient old?) (intake qr #:now "2026-01-01"))
(check-equal? (hash-ref patient 'birthDate) "1950-05-01")
(check-equal? old? "true")
(define-values (_p young?) (intake qr #:now "2015-04-30"))
(check-equal? young? "false")

;; a response with no birth date breaks the profile, and says so at the map's rule
(define no-birth (hash-set qr 'item (filter (lambda (i) (not (equal? (hash-ref i 'linkId) "birthDate"))) (hash-ref qr 'item))))
(check-exn #rx"qr2patient[.]map:[0-9]+:[0-9]+: .*Patient[.]birthDate: minimum required = 1" (lambda () (intake no-birth)))
