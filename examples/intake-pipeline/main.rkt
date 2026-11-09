#lang racket/base

;;; main.rkt — four FHIR languages in one Racket program (the fhir-authoring skill's worked example):
;;;   QuestionnaireResponse JSON --FML (qr2patient.map)--> Patient
;;;     --$validate against IntakePatient (intake.fsh)--> --CQL "Is 65 Or Older" (Intake.cql)--> answer
;;; Each language file is a module: requiring it compiles and checks it (a misspelt element in the map,
;;; an unknown function in the library, fail `raco make` at their lines) and registers what it defines
;;; by canonical, so validation finds the profile with no setup.
;;;   racket main.rkt qr.json

(require racket/list json
         fhir/operation
         (only-in fhir/conformance/operations ensure-valid)  ; loading it registers $validate
         (only-in cql/value render)
         (only-in "intake.fsh" canonical-of)                  ; the profile's url, by name
         (only-in "qr2patient.map" transform)                 ; QuestionnaireResponse JSON -> Patient JSON
         (only-in "Intake.cql" evaluate))                     ; the library over one patient's resources

(provide intake)

;; intake : QuestionnaireResponse -> (values Patient answer)   or exn:fail:operation listing every
;; way the Patient breaks IntakePatient
(define (intake qr)
  (define patient (ensure-valid (transform qr) #:profile (canonical-of "IntakePatient")))
  (values patient (render (hash-ref (evaluate (list patient)) "Is 65 Or Older"))))

(module+ main
  (require racket/cmdline)
  (define file (command-line #:args (questionnaire-response.json) questionnaire-response.json))
  (define-values (patient old?) (intake (call-with-input-file file read-json)))
  (write-json patient) (newline)
  (printf "65 or older: ~a\n" old?))
