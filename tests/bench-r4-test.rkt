#lang racket/base

;;; bench-r4-test.rkt — the spec benchmark's own oracle: a task made from mCODE's TumorSize, scored
;;; with the IG's own FSH (the ceiling our compiler allows) and with nothing (the floor). The model
;;; runs themselves are not tests (they need a model); TESTING.md and results/ record them.

(require rackunit racket/file
         (only-in fhir/spec-package spec-package-path)
         fhir-examples/bench)

(define mcode (collection-file-path "mcode-4.0.0" "fsh" "tests" "vendor"))

(cond
  [(not (spec-package-path "hl7.fhir.us.mcode-4.0.0.tgz" #:optional? #t))
   (printf "spec-bench: skipped (needs fhir-spec)\n")]
  [else
   (define dir (make-temporary-directory "spec-bench-test-~a"))
   (define task (make-task! mcode (published-package "hl7.fhir.us.mcode-4.0.0") "TumorSize" (build-path dir "t")))
   (define prompt (file->string (build-path task "prompt.md")))
   ;; the prompt names every constrained element but states no constraint value
   (check-regexp-match #rx"`Observation[.]code`" prompt)
   (check-regexp-match #rx"`Observation[.]component:tumorLongestDimension`" prompt)
   (check-false (regexp-match? #rx"33728-7|21889-1" prompt) "a pinned code leaked into the prompt")
   (define t (call-with-input-file (build-path task "task.rktd") read))
   (define oracle (score-task task (hash-ref t 'oracle)))
   (define empty (score-task task ""))
   (check-equal? (hash-ref oracle 'check_errors) 0)
   (check-equal? (hash-ref oracle 'accepts_published_examples) '(2 2))
   (check-equal? (hash-ref oracle 'examples_conform_to_published) '(2 2))
   (check-true (>= (car (hash-ref oracle 'fidelity)) 28) "the oracle's fidelity regressed (the compiler's ceiling)")
   (check-false (hash-ref empty 'profile_compiled))
   (check-equal? (car (hash-ref empty 'fidelity)) 0)
   (printf "  spec-bench TumorSize: oracle fidelity ~a, empty ~a\n" (hash-ref oracle 'fidelity) (hash-ref empty 'fidelity))
   (delete-directory/files dir)])
