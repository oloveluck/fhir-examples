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

;; Tokens lead: an arm is compared by the input tokens an item costs (every turn re-reads its
;; context, so this is what a run spends), then turns and output; cost is last, since prompt caching
;; makes the same tokens cost twice as much in one run as in the next.

;; median : (listof real) -> real
(define (median xs)
  (define v (sort xs <))
  (cond [(null? v) 0]
        [(odd? (length v)) (list-ref v (quotient (length v) 2))]
        [else (/ (+ (list-ref v (sub1 (quotient (length v) 2))) (list-ref v (quotient (length v) 2))) 2)]))
;; k : real -> string   thousands
(define (k x) (format "~ak" (exact-round (/ x 1000))))
;; field : (listof hash) symbol -> (listof real)
(define (field rs key) (filter real? (map (lambda (r) (hash-ref r key #f)) rs)))

;; token-row : string (listof hash) integer -> string   one arm's row: correct, tokens, turns, cost
(define (token-row name rs correct)
  (define in (field rs 'input_tokens))
  (format "| ~a | ~a/~a (~a%) | ~a | ~a | ~a | ~a | ~a | $~a |\n" name correct (length rs) (pct correct (length rs))
          (k (mean in)) (k (median in)) (exact-round (mean (field rs 'output_tokens)))
          (r2 (mean (field rs 'turns)))
          (if (zero? correct) "—" (k (/ (apply + in) correct)))
          (r2 (apply + (field rs 'cost_usd)))))
(define token-header
  (string-append "| arm | correct | input tokens / item | median | output tokens / item | turns / item | input tokens / correct | cost (cache-dependent) |\n"
                 "|---|---|---|---|---|---|---|---|\n"))

(define (mab run)
  (define arms (sort (for/list ([d (in-list (directory-list run #:build? #t))]
                                #:when (and (regexp-match? #rx"/mab-[^/]*$" (path->string d)) (file-exists? (build-path d "grades.json"))))
                       d)
                     string<? #:key path->string))
  (unless (null? arms)
    (printf "## MedAgentBench\n\n~a" token-header)
    (define grades (for/list ([a (in-list arms)]) (read-json-file (build-path a "grades.json"))))
    (for ([a (in-list arms)] [g (in-list grades)])
      (display (token-row (arm-name a "mab-") g (count (lambda (r) (hash-ref r 'correct)) g))))
    (define kinds (sort (remove-duplicates (for*/list ([g grades] [r g]) (car (string-split (hash-ref r 'id) "_"))))
                        < #:key (lambda (k) (string->number (substring k 4)))))
    (define (of-kind g k) (filter (lambda (r) (string-prefix? (hash-ref r 'id) (string-append k "_"))) g))
    (printf "\nBy task kind: correct · input tokens / task · turns / task\n\n| task kind | ~a |\n|---|~a\n"
            (string-join (map (lambda (a) (arm-name a "mab-")) arms) " | ")
            (string-append* (map (lambda (_) "---|") arms)))
    (for ([kd (in-list kinds)])
      (printf "| ~a | ~a |\n" kd
              (string-join (for/list ([g grades])
                             (define rs (of-kind g kd))
                             (format "~a/~a · ~a · ~a" (count (lambda (r) (hash-ref r 'correct)) rs) (length rs)
                                     (k (mean (field rs 'input_tokens))) (r2 (mean (field rs 'turns)))))
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
    (printf "## FHIR-AgentBench\n\n~a" token-header)
    (define evals (for/list ([a arms])
                    (read-json-file (findf (lambda (f) (regexp-match? #rx"_eval[.]json$" (path->string f)))
                                           (directory-list (build-path a "eval") #:build? #t)))))
    (for ([a arms] [ev evals])
      (display (token-row (arm-name a "fab-") (records a)
                          (count (lambda (e) (= 1 (num (hash-ref e 'answer_correctness)))) ev))))
    (printf "\n| arm | retrieval precision | retrieval recall |\n|---|---|---|\n")
    (for ([a arms] [ev evals])
      (printf "| ~a | ~a | ~a |\n" (arm-name a "fab-")
              (r2 (mean (filter real? (map (lambda (e) (hash-ref e 'precision)) ev))))
              (r2 (mean (filter real? (map (lambda (e) (hash-ref e 'recall)) ev))))))
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
