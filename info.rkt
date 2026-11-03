#lang info

;; fhir-spec-driven — FHIR as a framework for spec-driven development with LLMs: the demonstration.
;;
;; A model reads what a published Implementation Guide says about a profile, writes the FSH, gets
;; `raco fsh check`'s positioned diagnostics back, and is scored against the IG HL7 published. The
;; benchmark (bench.rkt, `raco spec-bench`) and the recorded runs (results/) live here; the tools it
;; demonstrates are the family's packages: fsh (+ `raco fsh check`), fhir-validation, fhir-server.

(define collection "spec-driven")
(define version "0.1")
(define pkg-desc "FHIR as a framework for spec-driven development with LLMs: prose -> FSH -> checked, scored against the published IG (raco spec-bench)")
(define pkg-authors '(oloveluck))
(define license 'MIT)
(define deps '("base" "fhir" "fhir-spec" "fhir-validation" "fsh"))
(define build-deps '("rackunit-lib"))
(define raco-commands
  '(("spec-bench" (submod spec-driven/cli main) "make prose -> FSH tasks from a published IG, run a model on them, score the answers" #f)))
(define test-omit-paths '("results"))
