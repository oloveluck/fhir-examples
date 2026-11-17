#lang racket/base

;;; gate.rkt — is FHIR-AgentBench passing, and what does a question cost: one answer over scored runs.
;;;
;;;   racket -l- fhir-examples/agent-bench/fab/gate [--slips N] [--json OUT] RUN_DIR…
;;;
;;; Each RUN_DIR is a run of fab/run.rkt that fab/score.sh has scored (eval/agent_results_eval.json,
;;; written by the benchmark's own evaluation_metrics.py). The runs given are taken together: a
;;; question asked in three of them was asked three times.
;;;
;;; The benchmark's score is reported as scored. Beside it, the questions of set-aside.json — those
;;; whose recorded answer contradicts the question, with the evidence in the note to the
;;; benchmark's authors — are set apart, and the rest (in scope) are sorted by how often they were
;;; missed: every time (the arm cannot answer it), sometimes (a slip of one run). The gate passes
;;; when no in-scope question is missed every time and at most N (--slips, default 0) are missed
;;; sometimes. Then what a question costs, which is what is compared once the gate passes: input
;;; tokens, turns, seconds, and the citations' precision and recall.
;;;
;;; An Asked is (asked id question correct? answer truth precision recall tokens turns seconds).
;;; A Tally is (tally id question asked right answers): one question over the runs given.

(require racket/cmdline racket/file racket/list racket/string racket/math racket/runtime-path json)

(provide (struct-out asked) (struct-out tally) tallies missed-always missed-sometimes passes?
         set-aside-ids mean median)

(define-runtime-path set-aside-file "set-aside.json")

(struct asked (id question correct? answer truth precision recall tokens turns seconds) #:transparent)
(struct tally (id question asked right answers) #:transparent)

;; set-aside-ids : jsexpr -> (hash id class)   set-aside.json's questions by id
(define (set-aside-ids j)
  (for/hash ([q (in-list (hash-ref j 'questions '()))])
    (values (hash-ref q 'id) (hash-ref q 'class "set aside"))))

;; run-asked : path -> (listof Asked)   a scored run's questions
(define (run-asked dir)
  (define f (build-path dir "eval" "agent_results_eval.json"))
  (unless (file-exists? f)
    (raise-user-error 'gate "~a is not scored: no eval/agent_results_eval.json (fab/score.sh writes it)" dir))
  (for/list ([r (in-list (call-with-input-file f read-json))])
    (define usage (let ([u (hash-ref r 'usage #f)]) (if (hash? u) u (hasheq))))
    (define (number key from) (let ([v (hash-ref from key #f)]) (and (real? v) (not (nan? v)) v)))
    (asked (hash-ref r 'question_id)
           (hash-ref r 'question "")
           (equal? (hash-ref r 'answer_correctness 0) 1)
           (format "~a" (hash-ref r 'agent_answer ""))
           (format "~a" (hash-ref r 'true_answer ""))
           (number 'precision r) (number 'recall r)
           (number 'input usage) (number 'turns usage) (number 'seconds usage))))

;; tallies : (listof Asked) -> (listof Tally)   by question, in the order first asked
(define (tallies as)
  (define order (remove-duplicates (map asked-id as)))
  (define by (for/fold ([h (hash)]) ([a (in-list as)]) (hash-update h (asked-id a) (lambda (l) (cons a l)) '())))
  (for/list ([id (in-list order)])
    (define mine (reverse (hash-ref by id)))
    (tally id (asked-question (car mine)) (length mine) (count asked-correct? mine)
           (for/list ([a (in-list mine)] #:unless (asked-correct? a)) (asked-answer a)))))

;; missed-always, missed-sometimes : (listof Tally) -> (listof Tally)
(define (missed-always ts) (filter (lambda (t) (zero? (tally-right t))) ts))
(define (missed-sometimes ts) (filter (lambda (t) (< 0 (tally-right t) (tally-asked t))) ts))

;; passes? : (listof Tally) natural -> boolean   the in-scope tallies pass with at most `slips`
;; questions missed in some run and none missed in every run
(define (passes? ts slips)
  (and (null? (missed-always ts)) (<= (length (missed-sometimes ts)) slips)))

(define (mean xs) (if (null? xs) 0 (/ (apply + xs) (length xs))))
(define (median xs)
  (define v (sort xs <))
  (define n (length v))
  (cond [(zero? n) 0]
        [(odd? n) (list-ref v (quotient n 2))]
        [else (/ (+ (list-ref v (sub1 (quotient n 2))) (list-ref v (quotient n 2))) 2)]))

;; shown : string natural -> string   one line of a text, cut
(define (shown s n)
  (define line (string-normalize-spaces s))
  (if (> (string-length line) n) (string-append (substring line 0 n) "…") line))

(module+ main
  (define slips 0)
  (define out #f)
  (define dirs
    (command-line
     #:program "gate"
     #:once-each
     [("--slips") n "in-scope questions that may be missed in some run and not all (default 0)" (set! slips (string->number n))]
     [("--json") f "also write the figures to this file" (set! out f)]
     #:args dir dir))
  (when (null? dirs) (raise-user-error 'gate "give the scored run directories"))
  (define aside (set-aside-ids (call-with-input-file set-aside-file read-json)))
  (define all (append-map run-asked dirs))
  (define ts (tallies all))
  (define-values (apart scope) (partition (lambda (t) (hash-has-key? aside (tally-id t))) ts))
  (define (asked-of ts) (apply + (map tally-asked ts)))
  (define (right-of ts) (apply + (map tally-right ts)))
  (define (pct a b) (if (zero? b) "-" (format "~a%" (/ (round (* 1000.0 (/ a b))) 10.0))))
  (define always (missed-always scope))
  (define sometimes (missed-sometimes scope))
  (define ok? (passes? scope slips))
  (printf "runs ~a, questions ~a, answers ~a\n" (length dirs) (length ts) (length all))
  (printf "as scored       ~a of ~a (~a)\n" (right-of ts) (asked-of ts) (pct (right-of ts) (asked-of ts)))
  (printf "set aside       ~a questions (set-aside.json): ~a of ~a marked right\n" (length apart) (right-of apart) (asked-of apart))
  (printf "in scope        ~a of ~a (~a) over ~a questions: ~a right every time, ~a missed sometimes, ~a missed every time\n"
          (right-of scope) (asked-of scope) (pct (right-of scope) (asked-of scope)) (length scope)
          (- (length scope) (length always) (length sometimes)) (length sometimes) (length always))
  (for ([group (list (cons "missed every time" always) (cons "missed sometimes" sometimes))] #:when (pair? (cdr group)))
    (printf "\n~a:\n" (car group))
    (for ([t (in-list (cdr group))])
      (printf "  ~a  right ~a of ~a  ~a\n      answered: ~a\n" (tally-id t) (tally-right t) (tally-asked t)
              (shown (tally-question t) 110) (shown (string-join (remove-duplicates (tally-answers t)) " ; ") 110))))
  (define (figures key) (filter values (map key all)))
  (define tokens (figures asked-tokens))
  (printf "\na question costs  input tokens: mean ~a, median ~a   turns: mean ~a   seconds: mean ~a\n"
          (exact-round (mean tokens)) (exact-round (median tokens))
          (/ (round (* 100.0 (mean (figures asked-turns)))) 100.0) (/ (round (* 10.0 (mean (figures asked-seconds)))) 10.0))
  (printf "citations         precision ~a   recall ~a\n"
          (/ (round (* 1000.0 (mean (figures asked-precision)))) 1000.0)
          (/ (round (* 1000.0 (mean (map (lambda (a) (or (asked-recall a) 0)) all)))) 1000.0))
  (printf "\n~a\n" (if ok? "PASS" (format "FAIL (allowed: 0 missed every time, ~a missed sometimes)" slips)))
  (when out
    (call-with-output-file out #:exists 'truncate
      (lambda (o)
        (write-json (hasheq 'runs (length dirs) 'questions (length ts)
                            'as_scored (list (right-of ts) (asked-of ts))
                            'in_scope (list (right-of scope) (asked-of scope))
                            'missed_every_time (map tally-id always) 'missed_sometimes (map tally-id sometimes)
                            'input_tokens_mean (exact-round (mean tokens)) 'input_tokens_median (exact-round (median tokens))
                            'turns_mean (exact->inexact (mean (figures asked-turns)))
                            'seconds_mean (exact->inexact (mean (figures asked-seconds)))
                            'pass ok?)
                    o))))
  (exit (if ok? 0 1)))

(module+ test
  (require rackunit)
  (define (a id ok? [answer "x"]) (asked id (string-append "question " id) ok? answer "t" 1.0 1.0 40000 3 9.0))
  (define ts (tallies (list (a "q1" #t) (a "q2" #f "70") (a "q3" #t) (a "q1" #t) (a "q2" #f "70") (a "q3" #f "none"))))
  (check-equal? (map tally-id ts) '("q1" "q2" "q3"))
  (check-equal? (map tally-right ts) '(2 0 1))
  (check-equal? (tally-answers (cadr ts)) '("70" "70"))
  (check-equal? (map tally-id (missed-always ts)) '("q2"))
  (check-equal? (map tally-id (missed-sometimes ts)) '("q3"))
  (check-false (passes? ts 1) "a question missed every time fails whatever slips are allowed")
  (define scope (filter (lambda (t) (not (equal? (tally-id t) "q2"))) ts))
  (check-false (passes? scope 0))
  (check-true (passes? scope 1))
  (check-true (passes? (list (car ts)) 0))
  (check-equal? (median '(3 1 2)) 2)
  (check-equal? (median '(4 1 2 3)) 5/2)
  (check-equal? (mean '()) 0)
  ;; the file itself: every question once, each of a class the file describes
  (define j (call-with-input-file set-aside-file read-json))
  (define ids (set-aside-ids j))
  (check-equal? (hash-count ids) (length (hash-ref j 'questions)))
  (check-equal? (hash-count ids) 18)
  (for ([(id class) (in-hash ids)])
    (check-true (hash-has-key? (hash-ref j 'classes) (string->symbol class)) id)))
