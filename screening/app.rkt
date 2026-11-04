#lang fhir/capability

;;; app.rkt — the seventh language: the screening served. The same modules main.rkt composes are
;;; declared here as what a FHIR server supports, and the lang DERIVES the CapabilityStatement from
;;; the declarations (run this file to print it; `raco fhir-server serve screening/app.rkt 8080`
;;; serves it). The map is served by its canonical — requiring intake.fml registered it — and the
;;; profile FSH defined is the context its `uses` resolve in.
;;;
;;;   curl localhost:8080/metadata
;;;   curl -X POST localhost:8080/StructureMap/$transform -d @parameters.json
;;;     (a Parameters: source = http://example.org/StructureMap/bp-intake, content = a form)

(require (only-in "profile.fsh" [compiled clinic])          ; the profile, the clinic's records
         (only-in "intake.fml")                               ; registers the map by its canonical
         fhir/data-source
         (only-in fml/operations $transform)
         (only-in fhir/conformance/operations $validate)
         (only-in fhir/terminology/operations $expand))

;; the app's data: the clinic's records are the context the map's `uses` and validation resolve in
(current-data-source (resources->data-source clinic))

(server #:mode "server" #:status "active" #:url "http://example.org/fhir/screening")

(resource Observation #:interactions (read create))
(resource Patient #:interactions (read create))

(operation $transform)              ; StructureMap/$transform: source = the map's canonical
(operation $validate)               ; Resource/$validate on every declared type
(operation $expand)                 ; ValueSet/$expand (bp-panels.vcl's compose, or any url)
