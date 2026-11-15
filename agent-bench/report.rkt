#lang racket/base

;;; report.rkt — one markdown table of a run of both benchmarks: per arm, what the graders said and
;;; what it cost, then each arm's misses.
;;;
;;;   racket -l- fhir-examples/agent-bench/report RUN_DIR
;;;
;;; RUN_DIR holds mab-<arm>/grades.json (mab/grade.rkt) and fab-<arm>/eval/*_eval.json (fab/score.sh,
;;; the benchmark's evaluation_metrics.py), with each item's record.json beside.

(require racket/file racket/list racket/string racket/math racket/path json "run-agent.rkt")

(define (mean xs) (if (null? xs) 0 (/ (apply + xs) (length xs))))
(define (num x) (if (real? x) x 0))
(define (pct c n) (/ (round (* 1000 (/ c (max 1 n)))) 10.0))
(define (r2 x) (/ (round (* 100 x)) 100.0))
(define (arm-name d prefix) (substring (path->string (file-name-from-path d)) (string-length prefix)))

(define (records d)
  (for/list ([f (in-list (directory-list d #:build? #t))]
             #:when (file-exists? (build-path f "record.json")))
    (read-json-file (build-path f "record.json"))))

(define (mab run)
  (define arms (sort (for/list ([d (in-list (directory-list run #:build? #t))]
                                #:when (and (regexp-match? #rx"/mab-[^/]*$" (path->string d)) (file-exists? (build-path d "grades.json"))))
                       d)
                     string<? #:key path->string))
  (unless (null? arms)
    (printf "## MedAgentBench\n\n| arm | correct | cost | input tokens / task | agent time / task |\n|---|---|---|---|---|\n")
    (define grades (for/list ([a (in-list arms)]) (read-json-file (build-path a "grades.json"))))
    (for ([a (in-list arms)] [g (in-list grades)])
      (define c (count (lambda (r) (hash-ref r 'correct)) g))
      (define toks (filter real? (map (lambda (r) (hash-ref r 'input_tokens)) g)))
      (define secs (filter real? (map (lambda (r) (hash-ref r 'seconds)) g)))
      (printf "| ~a | ~a/~a (~a%) | $~a | ~a | ~a |\n" (arm-name a "mab-") c (length g) (pct c (length g))
              (r2 (apply + (map (lambda (r) (num (hash-ref r 'cost_usd))) g)))
              (if (null? toks) "—" (format "~ak" (exact-round (/ (mean toks) 1000))))
              (if (null? secs) "—" (format "~a s" (exact-round (mean secs))))))
    (define kinds (sort (remove-duplicates (for*/list ([g grades] [r g]) (car (string-split (hash-ref r 'id) "_"))))
                        < #:key (lambda (k) (string->number (substring k 4)))))
    (printf "\n| task kind | ~a |\n|---|~a\n" (string-join (map (lambda (a) (arm-name a "mab-")) arms) " | ")
            (string-append* (map (lambda (_) "---|") arms)))
    (for ([k (in-list kinds)])
      (printf "| ~a | ~a |\n" k
              (string-join (for/list ([g grades])
                             (define rs (filter (lambda (r) (string-prefix? (hash-ref r 'id) (string-append k "_"))) g))
                             (format "~a/~a" (count (lambda (r) (hash-ref r 'correct)) rs) (length rs)))
                           " | ")))
    (newline)
    (for ([a (in-list arms)] [g (in-list grades)])
      (define miss (for/list ([r g] #:unless (hash-ref r 'correct)) (hash-ref r 'id)))
      (printf "- ~a misses (~a): ~a\n" (arm-name a "mab-") (length miss) (string-join miss ", ")))
    (newline)))

(define (fab run)
  (define arms (sort (for/list ([d (in-list (directory-list run #:build? #t))]
                                #:when (and (regexp-match? #rx"/fab-[^/]*$" (path->string d))
                                            (directory-exists? (build-path d "eval"))))
                       d)
                     string<? #:key path->string))
  (unless (null? arms)
    (printf "## FHIR-AgentBench\n\n| arm | correct | retrieval precision | retrieval recall | cost | input tokens / q | agent time / q |\n|---|---|---|---|---|---|---|\n")
    (define evals (for/list ([a arms])
                    (read-json-file (findf (lambda (f) (regexp-match? #rx"_eval[.]json$" (path->string f)))
                                           (directory-list (build-path a "eval") #:build? #t)))))
    (for ([a arms] [ev evals])
      (define recs (records a))
      (define c (count (lambda (e) (= 1 (num (hash-ref e 'answer_correctness)))) ev))
      (printf "| ~a | ~a/~a (~a%) | ~a | ~a | $~a | ~ak | ~a s |\n" (arm-name a "fab-") c (length ev) (pct c (length ev))
              (r2 (mean (filter real? (map (lambda (e) (hash-ref e 'precision)) ev))))
              (r2 (mean (filter real? (map (lambda (e) (hash-ref e 'recall)) ev))))
              (r2 (apply + (map (lambda (r) (num (hash-ref r 'cost_usd))) recs)))
              (exact-round (/ (mean (map (lambda (r) (num (hash-ref r 'input_tokens))) recs)) 1000))
              (exact-round (mean (map (lambda (r) (num (hash-ref r 'seconds))) recs)))))
    (newline)
    (for ([a arms] [ev evals])
      (define miss (filter (lambda (e) (not (= 1 (num (hash-ref e 'answer_correctness))))) ev))
      (printf "### ~a misses (~a)\n" (arm-name a "fab-") (length miss))
      (for ([e miss])
        (define ans (format "~a" (hash-ref e 'agent_answer)))
        (printf "- `~a` ~a  \n  truth: ~a  ·  answer: ~a\n" (substring (hash-ref e 'question_id) 0 8) (hash-ref e 'question)
                (hash-ref e 'true_answer_extracted) (substring ans 0 (min 160 (string-length ans)))))
      (newline))))

(module+ main
  (define args (current-command-line-arguments))
  (unless (= (vector-length args) 1) (raise-user-error "usage: report RUN_DIR"))
  (define run (path->complete-path (vector-ref args 0)))
  (mab run)
  (fab run))
