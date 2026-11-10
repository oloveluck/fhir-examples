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
         (only-in fhir/conformance/operations)               ; loading it registers $validate
         (only-in cql/value render)
         (only-in "fsh/intake.fsh" canonical-of)                  ; the profile's url, by name
         (only-in "qr2patient.map" transform)                 ; QuestionnaireResponse JSON -> Patient JSON
         (only-in "Intake.cql" evaluate))                     ; the library over one patient's resources

(provide intake)

;; intake : QuestionnaireResponse [#:now date] -> (values Patient answer)   or exn:fail:user listing
;; every way the Patient breaks IntakePatient, each at the map's rule that wrote (or should have
;; written) the element; `#:now` fixes CQL's Today() (the answer depends on the day otherwise)
(define (intake qr #:now [now #f])
  (define patient (transform qr #:validate (canonical-of "IntakePatient")))
  (values patient (render (evaluate (list patient) #:define "Is 65 Or Older" #:now now))))

(module+ main
  (require racket/cmdline)
  (define file (command-line #:args (questionnaire-response.json) questionnaire-response.json))
  (define-values (patient old?) (intake (call-with-input-file file read-json)))
  (write-json patient) (newline)
  (printf "65 or older: ~a\n" old?))
