#lang fhir/capability

;;; app.rkt — the seventh language: the screening served. What main.rkt composes is declared here
;;; as what a FHIR server supports, and the lang DERIVES the CapabilityStatement from the
;;; declarations (run this file to print it; `raco fhir-server serve screening/app.rkt 8080` serves
;;; it). The map is served by its canonical — requiring intake.fml registered it — and the pipeline
;;; is declared ONCE as `$screen`: served here, and an operation value main.rkt applies in-process.
;;;
;;;   curl localhost:8080/metadata
;;;   curl -X POST localhost:8080/StructureMap/$transform -d @parameters.json
;;;     (a Parameters: source = http://example.org/StructureMap/bp-intake, content = a form)
;;;   curl -X POST 'localhost:8080/$screen' -d '{"resourceType":"Parameters","parameter":[{"name":"patient","valueString":"ann"}]}'

(require (only-in "pipeline.rkt" screening)                 ; the composition (and its modules)
         (only-in fml/operations $transform)
         (only-in fhir/conformance/operations $validate)
         (only-in fhir/terminology/operations $expand))

(server #:mode "server" #:status "active" #:url "http://example.org/fhir/screening")

(resource Observation #:interactions (read create))
(resource Patient #:interactions (read create))

(operation $transform)              ; StructureMap/$transform: source = the map's canonical
(operation $validate)               ; Resource/$validate on every declared type
(operation $expand)                 ; ValueSet/$expand (bp-panels.vcl's compose, or any url)

;; the pipeline as an operation: the rule's verdict for one patient
(define (screen-handler in req)
  (define id (format "~a" (car (hash-ref in "patient"))))
  (define verdict (screening id))
  (Parameters (parameter (ParametersParameter (name "highest") (valueInteger (hash-ref verdict 'highest)))
                         (ParametersParameter (name "hypertensive") (valueBoolean (hash-ref verdict 'hypertensive))))))
(operation $screen #:system
  #:in ([patient string 1 1])
  #:out ([highest integer 0 1] [hypertensive boolean 1 1])
  #:handler screen-handler)
