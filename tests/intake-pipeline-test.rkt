#lang racket/base

;;; intake-pipeline-test.rkt — the fhir-authoring skill's multi-language example runs as it says:
;;; a QuestionnaireResponse mapped by FML, validated against an FSH profile, judged by CQL.

(require rackunit racket/runtime-path json
         (only-in fsh/check check-fsh-project check-report-diagnostics)
         (only-in fhir/diagnostic diagnostic-message diagnostic-severity))
(define-runtime-path dir "../examples/intake-pipeline")
(define intake (dynamic-require (build-path dir "main.rkt") 'intake))
(define qr (call-with-input-file (build-path dir "qr.json") read-json))

(define-values (patient old?) (intake qr #:now "2026-01-01"))
(check-equal? (hash-ref patient 'birthDate) "1950-05-01")
(check-equal? old? "true")
;; without a birth date the Patient breaks IntakePatient, and the error names the map's birthDate rule
(define no-birth (hash-set qr 'item (filter (lambda (i) (not (equal? (hash-ref i 'linkId) "birthDate"))) (hash-ref qr 'item))))
(check-exn #rx"the map's Patient is invalid against IntakePatient [(][^)]*[)] [(]FHIR R5 [(]5.0.0[)][)]:\n  [^\n]*qr2patient[.]map:[0-9]+:[0-9]+: fml validate error: Patient[.]birthDate: minimum required = 1, but found 0 [(]the rule here wrote nothing: its source matched nothing in the input[)]"
           (lambda () (intake no-birth)))

;; the layout the docs recommend, as a template: the project checks clean, and the example meant to
;; fail is reported, apart (`raco fsh check fsh-invalid --context fsh`)
(define (errors-of r) (filter (lambda (d) (eq? (diagnostic-severity d) 'error)) (check-report-diagnostics r)))
(check-equal? (errors-of (check-fsh-project (build-path dir "fsh"))) '())
(define bad (errors-of (check-fsh-project (build-path dir "fsh-invalid") #:context (list (build-path dir "fsh")))))
(check-equal? (length bad) 1)
(check-regexp-match #rx"intake-bad: Patient.birthDate: minimum required = 1" (diagnostic-message (car bad)))

;; the fhir-authoring skill shows main.rkt whole: the same forms as the file (a rerun's agent copied the
;; skill's partial snippet and had to guess how to read the file and print the answer)
(require racket/file racket/port)
(define skill (let ([fhir (collection-file-path "main.rkt" "fhir")])
                (let-values ([(d n _) (split-path fhir)]) (simplify-path (build-path d 'up ".claude" "skills" "fhir-authoring" "SKILL.md")))))
(define (forms text) (with-input-from-string (regexp-replace #rx"^#lang [^\n]*\n" text "") (lambda () (port->list read))))
(when (file-exists? skill)
  (define block (for/first ([m (in-list (regexp-match* #px"```racket\n(.*?)```" (file->string skill) #:match-select cadr))]
                            #:when (regexp-match? #rx"\"qr2patient.map\"" m))
                  m))
  (check-equal? (forms block) (forms (file->string (build-path dir "main.rkt")))))
