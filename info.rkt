#lang info

;; fhir-examples — examples for the fhir family: FHIR operations as procedures (examples/), and
;; spec-driven development with LLMs, measured (bench.rkt, `raco spec-bench`).
;;
;; A model reads what a published Implementation Guide says about a profile, writes the FSH, gets
;; `raco fsh check`'s positioned diagnostics back, and is scored against the IG HL7 published. The
;; benchmark (bench.rkt, `raco spec-bench`) and the recorded runs (results/) live here; the tools it
;; demonstrates are the family's packages: fsh (+ `raco fsh check`), fhir-validation, fhir-server.

(define collection "fhir-examples")
(define version "0.1")
(define pkg-desc "Examples for the Racket FHIR family: FHIR operations applied as procedures, and a spec-driven development benchmark (prose -> FSH -> checked, scored against the published IG; raco spec-bench)")
(define pkg-authors '(oloveluck))
(define license 'MIT)
(define deps '("base" "fhir" "fhir-spec" "fhir-tx" "fhir-validation" "fhir-server" "fhirpath" "fsh" "fml" "cql" "vcl"
               "sql-on-fhir" "net-lib"))
(define build-deps '("rackunit-lib" "scribble-lib" "racket-doc"))
(define scribblings '(("scribblings/fhir-examples.scrbl" ())))
(define raco-commands
  '(("spec-bench" (submod fhir-examples/cli main) "make prose -> FSH tasks from a published IG, run a model on them, score the answers" #f)))
(define test-omit-paths '("results" "ig-servers/packages" "ig-servers/main.rkt" "scribblings"))
