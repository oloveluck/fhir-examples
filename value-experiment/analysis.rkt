#lang racket/base

;;; analysis.rkt — the comparisons of value-experiment/PROTOCOL.md, as it states them.
;;;
;;;   racket analysis.rkt fab NAME_L=RUN_DIR,RUN_DIR,… NAME_G=RUN_DIR,… [NAME_OTHER=RUN_DIR,…]…
;;;
;;; Two arms' scored FHIR-AgentBench runs (fab/score.sh), paired by question: the share right of
;;; each, the difference with its interval, McNemar's test, the cost ratio with its interval, and
;;; the verdict the protocol defines; then the questions by which arm is right, what a session of
;;; each arm cost and called (the sessions' record.json), and where any further arm named stands
;;; on the same questions. Every figure of RESULTS.md's section M is printed by this command or by
;;; agent-bench/report.rkt (retrieval precision and recall, from the benchmark's own grader).
;;;
;;; Data definitions.
;;; A Pass is (pass right? cost): one run of one task by one arm; cost is a real (input tokens) or #f.
;;; A Paired is (paired id ls gs): one task's passes by the two arms compared, L first.
;;; An Interval is (interval low high).
;;; A Comparison is (comparison tasks share-l share-g difference diff-interval p cost-ratio
;;;   ratio-interval verdict); verdict is 'more-right | 'cheaper | 'worse | 'no-difference-shown.

(require racket/list racket/math racket/string racket/file json)

(provide (struct-out pass) (struct-out paired) (struct-out interval) (struct-out comparison)
         overlap neither call-kind tool-use tokens-a-task quantile records session-costs
         share-right mcnemar-exact holm bootstrap-interval compare verdict-of clear-null?
         minimum-difference non-inferiority-margin cost-ratio-bound)

(struct pass (right? cost) #:transparent)
(struct paired (id ls gs) #:transparent)
(struct interval (low high) #:transparent)
(struct comparison (tasks share-l share-g difference diff-interval p cost-ratio ratio-interval verdict) #:transparent)

;; the protocol's numbers
(define minimum-difference 0.05)      ; "a difference of at least 5 points"
(define non-inferiority-margin -0.03) ; "not worse (interval above −3 points)"
(define cost-ratio-bound 0.67)        ; "at two thirds of G's cost or less"
(define resamples 10000)

;; share-right : (listof Pass) -> real   the share of a task's passes that were right
(define (share-right ps) (if (null? ps) 0 (/ (count pass-right? ps) (length ps))))

;; mean : (listof real) -> real
(define (mean xs) (if (null? xs) 0 (/ (apply + xs) (length xs))))

;; mean-cost : (listof Pass) -> real | #f   over the passes that have one
(define (mean-cost ps)
  (define cs (filter values (map pass-cost ps)))
  (and (pair? cs) (mean cs)))

;; ---- McNemar's exact test -------------------------------------------------------------------------
;; choose : n k -> integer
(define (choose n k) (for/fold ([c 1]) ([i (in-range k)]) (/ (* c (- n i)) (+ i 1))))

;; mcnemar-exact : natural natural -> real   the two-sided exact p for b tasks right under L only
;; and c right under G only (a task counts as right when every pass of it was)
(define (mcnemar-exact b c)
  (define n (+ b c))
  (if (zero? n)
      1
      (min 1 (* 2 (/ (for/sum ([k (in-range (+ 1 (min b c)))]) (choose n k)) (expt 2 n))))))

;; ---- Holm's correction ----------------------------------------------------------------------------
;; holm : (listof (cons name p)) [alpha] -> (listof (list name p adjusted rejected?))   in the
;; order given; adjusted p-values are monotone in the order of the raw ones
(define (holm ps [alpha 0.05])
  (define m (length ps))
  (define sorted (sort ps < #:key cdr))
  (define adjusted
    (for/fold ([out '()] [highest 0] #:result (reverse out)) ([np (in-list sorted)] [i (in-naturals)])
      (define a (min 1 (max highest (* (- m i) (cdr np)))))
      (values (cons (cons (car np) a) out) a)))
  (for/list ([np (in-list ps)])
    (define a (cdr (assoc (car np) adjusted)))
    (list (car np) (cdr np) a (< a alpha))))

;; ---- the bootstrap --------------------------------------------------------------------------------
;; bootstrap-interval : (vectorof X) ((listof X) -> real | #f) [seed] -> Interval | #f   the 2.5th
;; and 97.5th percentiles of the statistic over resamples of the tasks, with replacement
(define (bootstrap-interval items statistic [seed 20261122])
  (define n (vector-length items))
  (define rng (make-pseudo-random-generator))
  (parameterize ([current-pseudo-random-generator rng])
    (random-seed seed)
    (define values-seen
      (for*/list ([_ (in-range resamples)]
                  [v (in-value (statistic (for/list ([_ (in-range n)]) (vector-ref items (random n)))))]
                  #:when v)
        v))
    (and (pair? values-seen)
         (let* ([sorted (list->vector (sort values-seen <))] [k (vector-length sorted)])
           (interval (vector-ref sorted (exact-floor (* 0.025 (- k 1))))
                     (vector-ref sorted (exact-ceiling (* 0.975 (- k 1)))))))))

;; difference : (listof Paired) -> real   mean over tasks of (L's share right − G's)
(define (difference ps) (mean (for/list ([p (in-list ps)]) (- (share-right (paired-ls p)) (share-right (paired-gs p))))))

;; cost-ratio : (listof Paired) -> real | #f   L's mean cost over G's, over the tasks both have a cost for
(define (cost-ratio ps)
  (define both (for*/list ([p (in-list ps)] [l (in-value (mean-cost (paired-ls p)))] [g (in-value (mean-cost (paired-gs p)))]
                           #:when (and l g))
                 (cons l g)))
  (and (pair? both) (positive? (mean (map cdr both)))
       (/ (mean (map car both)) (mean (map cdr both)))))

;; verdict-of : real Interval (or/c #f Interval) -> symbol   the protocol's "adds significant value"
(define (verdict-of diff diff-ci ratio-ci)
  (cond [(and (> (interval-low diff-ci) 0) (>= diff minimum-difference)) 'more-right]
        [(and (< (interval-high diff-ci) 0) (<= diff (- minimum-difference))) 'worse]
        [(and ratio-ci (> (interval-low diff-ci) non-inferiority-margin) (< (interval-high ratio-ci) cost-ratio-bound)) 'cheaper]
        [else 'no-difference-shown]))

;; clear-null? : Interval (or/c #f Interval) -> boolean   the protocol's "clear null" (amendment
;; M): the difference's interval inside ±5 points and the cost ratio's inside 0.67 to 1.5. A
;; comparison that shows no difference and is not a clear null is the one the stated extension
;; is for.
(define (clear-null? diff-ci ratio-ci)
  (and (>= (interval-low diff-ci) (- minimum-difference)) (<= (interval-high diff-ci) minimum-difference)
       (or (not ratio-ci)
           (and (>= (interval-low ratio-ci) cost-ratio-bound) (<= (interval-high ratio-ci) (/ 1 cost-ratio-bound))))))

;; compare : (listof Paired) -> Comparison
(define (compare ps)
  (define items (list->vector ps))
  (define diff (difference ps))
  (define diff-ci (bootstrap-interval items difference))
  (define ratio (cost-ratio ps))
  (define ratio-ci (and ratio (bootstrap-interval items cost-ratio)))
  (define b (count (lambda (p) (and (all-right? (paired-ls p)) (not (all-right? (paired-gs p))))) ps))
  (define c (count (lambda (p) (and (all-right? (paired-gs p)) (not (all-right? (paired-ls p))))) ps))
  (comparison (length ps)
              (mean (map (lambda (p) (share-right (paired-ls p))) ps))
              (mean (map (lambda (p) (share-right (paired-gs p))) ps))
              diff diff-ci (mcnemar-exact b c) ratio ratio-ci
              (verdict-of diff diff-ci ratio-ci)))

;; ---- FHIR-AgentBench's scored runs ------------------------------------------------------------------
;; run-passes : path -> (hash id Pass)   a scored run (eval/agent_results_eval.json)
(define (run-passes dir)
  (define f (build-path dir "eval" "agent_results_eval.json"))
  (unless (file-exists? f) (raise-user-error 'analysis "~a is not scored (fab/score.sh)" dir))
  (for/hash ([r (in-list (call-with-input-file f read-json))])
    (define usage (let ([u (hash-ref r 'usage #f)]) (if (hash? u) u (hasheq))))
    (values (hash-ref r 'question_id)
            (pass (equal? (hash-ref r 'answer_correctness 0) 1)
                  (let ([v (hash-ref usage 'input #f)]) (and (real? v) (not (nan? v)) v))))))

;; ---- what else a comparison is read with ------------------------------------------------------------
;; all-right? : (listof Pass) -> boolean   right in every pass that was run
(define (all-right? xs) (and (pair? xs) (andmap pass-right? xs)))

;; overlap : (listof Paired) -> (list both only-l only-g neither)   the tasks by which arm is right
(define (overlap ps)
  (define (n l? g?) (count (lambda (p) (and (eq? l? (all-right? (paired-ls p))) (eq? g? (all-right? (paired-gs p))))) ps))
  (list (n #t #t) (n #t #f) (n #f #t) (n #f #f)))

;; neither : (listof Paired) -> (listof id)   the tasks neither arm is right on
(define (neither ps)
  (for/list ([p (in-list ps)] #:unless (or (all-right? (paired-ls p)) (all-right? (paired-gs p)))) (paired-id p)))

;; call-kind : string -> string   a recorded tool call ("mcp__fhir__query {…}") as the kind of call it
;; is: the tool, and for a tool that takes a language, the language
(define (call-kind command)
  (define m (regexp-match #rx"^([^ ]+) ?(.*)$" command))
  (define tool (last (string-split (cadr m) "__")))
  (define arguments (with-handlers ([exn:fail? (lambda (_) #f)]) (string->jsexpr (caddr m))))
  (define language (and (hash? arguments) (hash-ref arguments 'language #f)))
  (if (string? language) (format "~a ~a" tool language) tool))

;; tool-use : (listof path) -> (listof (cons kind count))   the calls a run's sessions made
;; (each question's record.json), by kind, most first
(define (tool-use dirs)
  (define counts
    (for*/fold ([h (hash)]) ([r (in-list (records dirs))] [c (in-list (hash-ref r 'commands '()))])
      (hash-update h (call-kind c) add1 0)))
  (sort (hash->list counts) (lambda (a b) (or (> (cdr a) (cdr b)) (and (= (cdr a) (cdr b)) (string<? (car a) (car b)))))))

;; records : (listof path) -> (listof jsexpr)   each session's record.json of some runs
(define (records dirs)
  (for*/list ([d (in-list dirs)] [q (in-list (directory-list d #:build? #t))]
              #:when (file-exists? (build-path q "record.json")))
    (call-with-input-file (build-path q "record.json") read-json)))

;; quantile : (listof real) real -> real   the value at share q of the sorted list, between the two
;; nearest when q falls between them (q = 1/2 is the median)
(define (quantile xs q)
  (define v (list->vector (sort xs <)))
  (define at (* q (sub1 (vector-length v))))
  (define low (floor at))
  (define high (min (sub1 (vector-length v)) (add1 low)))
  (+ (vector-ref v low) (* (- at low) (- (vector-ref v high) (vector-ref v low)))))

;; session-costs : (listof jsexpr) -> (hash symbol real)   what a session of these records costs:
;; input tokens (mean, median, 90th percentile), output tokens, tool calls and seconds (means)
(define (session-costs rs)
  (define (field k) (filter real? (map (lambda (r) (hash-ref r k #f)) rs)))
  (define in (field 'input_tokens))
  (hasheq 'input (mean in) 'input-median (quantile in 1/2) 'input-90th (quantile in 9/10)
          'output (mean (field 'output_tokens))
          'calls (mean (map (lambda (r) (length (hash-ref r 'commands '()))) rs))
          'seconds (mean (field 'seconds))))

;; tokens-a-task : (hash id (listof Pass)) (listof id) -> (or/c #f real)   input tokens a task, over ids
(define (tokens-a-task arm ids)
  (define costs (filter values (for*/list ([id (in-list ids)] [p (in-list (hash-ref arm id '()))]) (pass-cost p))))
  (and (pair? costs) (mean costs)))

;; arm-passes : (listof path) -> (hash id (listof Pass))
(define (arm-passes dirs)
  (for*/fold ([h (hash)]) ([d (in-list dirs)] [(id p) (in-hash (run-passes d))])
    (hash-update h id (lambda (l) (append l (list p))) '())))

;; pairs : (hash id (listof Pass)) (hash id (listof Pass)) -> (listof Paired)   the tasks both arms ran
(define (pairs l g)
  (for/list ([id (in-list (sort (hash-keys l) string<?))] #:when (hash-ref g id #f))
    (paired id (hash-ref l id) (hash-ref g id))))

(define (percent x) (format "~a%" (/ (round (* 1000.0 x)) 10.0)))
(define (points x) (format "~a~a" (if (negative? x) "" "+") (/ (round (* 1000.0 x)) 10.0)))
(define (two x) (/ (round (* 100.0 x)) 100.0))

;; report : string string Comparison -> void
(define (report name-l name-g c)
  (printf "~a against ~a, ~a tasks both ran\n" name-l name-g (comparison-tasks c))
  (printf "  right           ~a ~a, ~a ~a\n" name-l (percent (comparison-share-l c)) name-g (percent (comparison-share-g c)))
  (printf "  difference      ~a points (95% interval ~a to ~a); McNemar p = ~a\n"
          (points (comparison-difference c)) (points (interval-low (comparison-diff-interval c)))
          (points (interval-high (comparison-diff-interval c))) (two (comparison-p c)))
  (when (comparison-cost-ratio c)
    (printf "  input tokens    ~a's are ~a of ~a's (95% interval ~a to ~a)\n" name-l (two (comparison-cost-ratio c)) name-g
            (two (interval-low (comparison-ratio-interval c))) (two (interval-high (comparison-ratio-interval c)))))
  (printf "  verdict         ~a\n"
          (case (comparison-verdict c)
            [(more-right) (format "~a is right more often (the protocol's \"significant value\")" name-l)]
            [(cheaper) (format "~a is not worse and costs two thirds or less (the protocol's \"significant value\")" name-l)]
            [(worse) (format "~a is right less often" name-l)]
            [else (if (clear-null? (comparison-diff-interval c) (comparison-ratio-interval c))
                      "no difference shown, and a clear null (the intervals are inside the protocol's bounds)"
                      "no difference shown, and not a clear null: the protocol's one extension applies")])))

;; report-overlap : string string (listof Paired) -> void
(define (report-overlap name-l name-g ps)
  (define o (overlap ps))
  (printf "  by task         right under both ~a, under ~a only ~a, under ~a only ~a, under neither ~a\n"
          (first o) name-l (second o) name-g (third o) (fourth o)))

;; report-sessions : string (listof path) -> void   what a session of the arm cost and what it called
(define (report-sessions name dirs)
  (define rs (records dirs))
  (when (pair? rs)
    (define c (session-costs rs))
    (define (k x) (format "~ak" (/ (round (/ x 100.0)) 10.0)))
    (define (one x) (/ (round (* 10.0 x)) 10.0))
    (printf "  a ~a session: input tokens ~a (median ~a, 90th percentile ~a), output tokens ~a, ~a tool calls, ~a s\n"
            name (k (hash-ref c 'input)) (k (hash-ref c 'input-median)) (k (hash-ref c 'input-90th))
            (inexact->exact (round (hash-ref c 'output))) (one (hash-ref c 'calls)) (one (hash-ref c 'seconds)))
    (printf "    its calls: ~a\n"
            (string-join (for/list ([u (in-list (tool-use dirs))]) (format "~a ~a" (cdr u) (car u))) ", "))))

;; report-other : string (hash id (listof Pass)) (listof Paired) -> void   another arm on the same
;; tasks: not one of the comparison's two, so no test, only where it stands
(define (report-other name arm ps)
  (define ids (filter (lambda (id) (hash-ref arm id #f)) (map paired-id ps)))
  (define missed (filter (lambda (id) (hash-ref arm id #f)) (neither ps)))
  (define cost (tokens-a-task arm ids))
  (printf "~a on the same tasks (~a of them run): right on ~a~a; of the ~a neither arm is right on, right on ~a\n"
          name (length ids) (count (lambda (id) (all-right? (hash-ref arm id))) ids)
          (if cost (format ", ~ak input tokens a task" (/ (round (/ cost 100.0)) 10.0)) "")
          (length missed) (count (lambda (id) (all-right? (hash-ref arm id))) missed)))

(module+ main
  (define args (vector->list (current-command-line-arguments)))
  (define (arm-of spec)
    (define m (regexp-match #rx"^([^=]+)=(.+)$" spec))
    (unless m (raise-user-error 'analysis "an arm is NAME=RUN_DIR,RUN_DIR,…: ~a" spec))
    (cons (cadr m) (string-split (caddr m) ",")))
  (unless (and (>= (length args) 3) (equal? (car args) "fab"))
    (raise-user-error 'analysis "analysis.rkt fab NAME_L=RUN_DIR,… NAME_G=RUN_DIR,… [NAME_OTHER=RUN_DIR,…]…"))
  (define l (arm-of (cadr args)))
  (define g (arm-of (caddr args)))
  (define ps (pairs (arm-passes (cdr l)) (arm-passes (cdr g))))
  (report (car l) (car g) (compare ps))
  (report-overlap (car l) (car g) ps)
  (report-sessions (car l) (cdr l))
  (report-sessions (car g) (cdr g))
  (for ([other (in-list (map arm-of (cdddr args)))])
    (report-other (car other) (arm-passes (cdr other)) ps)))

(module+ test
  (require rackunit)
  (check-equal? (share-right (list (pass #t 1) (pass #f 1) (pass #t 1))) 2/3)
  ;; the tasks by which arm is right; a task is right when every pass of it is
  (define four
    (list (paired "a" (list (pass #t 1)) (list (pass #t 1))) (paired "b" (list (pass #t 1)) (list (pass #f 1)))
          (paired "c" (list (pass #f 1)) (list (pass #t 1))) (paired "d" (list (pass #f 1)) (list (pass #f 1)))
          (paired "e" (list (pass #t 1) (pass #f 1)) (list (pass #f 1) (pass #f 1)))))
  (check-equal? (overlap four) '(1 1 1 2))
  (check-equal? (neither four) '("d" "e"))
  (check-equal? (quantile '(4 1 3 2 5) 1/2) 3)
  (check-equal? (quantile '(1 2 3 4) 1/2) 5/2)
  (check-equal? (quantile '(10 20) 9/10) 19)
  (check-equal? (quantile '(7) 9/10) 7)
  (check-equal? (tokens-a-task (hash "a" (list (pass #t 10) (pass #t 30)) "b" (list (pass #f #f))) '("a" "b" "z")) 20)
  ;; a recorded call by its kind
  (check-equal? (call-kind "mcp__fhir__query {\"language\":\"search\",\"text\":\"Patient?name=a b\"}") "query search")
  (check-equal? (call-kind "mcp__fhir__describe {\"ref\":\"data\"}") "describe")
  (check-equal? (call-kind "mcp__rest__python {\"code\":\"print(1)\"}") "python")
  (check-equal? (call-kind "mcp__rest__get {cut off") "get")
  (check-equal? (call-kind "Bash") "Bash")
  (let ([dir (make-temporary-file "analysis-~a" 'directory)])
    (for ([q (in-list '("q1" "q2"))] [cs (in-list '(("mcp__rest__get {}" "mcp__rest__python {}") ("mcp__rest__get {}")))])
      (make-directory (build-path dir q))
      (call-with-output-file (build-path dir q "record.json")
        (lambda (o) (write-json (hasheq 'commands cs 'input_tokens (* 1000 (length cs)) 'output_tokens 10 'seconds 2.5) o))))
    (make-directory (build-path dir "eval"))
    (check-equal? (tool-use (list dir)) '(("get" . 2) ("python" . 1)))
    (check-equal? (session-costs (records (list dir)))
                  (hasheq 'input 1500 'input-median 1500 'input-90th 1900 'output 10 'calls 3/2 'seconds 2.5))
    (delete-directory/files dir))
  ;; McNemar, exact: 10 against 0 is 2·(1/2)^10; even counts are 1; nothing discordant is 1
  (check-equal? (mcnemar-exact 10 0) 1/512)
  (check-equal? (mcnemar-exact 0 10) 1/512)
  (check-equal? (mcnemar-exact 3 3) 1)
  (check-equal? (mcnemar-exact 0 0) 1)
  (check-equal? (mcnemar-exact 1 5) (* 2 (/ (+ 1 6) 64)))
  ;; Holm: the smallest is multiplied by m, the next by m−1 and never below the one before
  (check-equal? (holm '((a . 0.01) (b . 0.04) (c . 0.03)))
                '((a 0.01 0.03 #t) (b 0.04 0.06 #f) (c 0.03 0.06 #f)))
  (check-equal? (map cadddr (holm '((a . 0.001) (b . 0.02) (c . 0.02)))) '(#t #t #t))
  ;; a clear difference: L right on every task, G on half
  (define clear
    (for/list ([i (in-range 60)])
      (paired (number->string i) (list (pass #t 100) (pass #t 100) (pass #t 100))
              (list (pass (even? i) 300) (pass (even? i) 300) (pass (even? i) 300)))))
  (define c1 (compare clear))
  (check-equal? (comparison-share-l c1) 1)
  (check-equal? (comparison-share-g c1) 1/2)
  (check-equal? (comparison-difference c1) 1/2)
  (check-true (> (interval-low (comparison-diff-interval c1)) 0.3))
  (check-equal? (comparison-cost-ratio c1) 1/3)
  (check-equal? (comparison-verdict c1) 'more-right)
  ;; equally right, a third of the cost: cheaper
  (define same
    (for/list ([i (in-range 60)])
      (paired (number->string i) (list (pass (< i 55) 100)) (list (pass (< i 55) 300)))))
  (check-equal? (comparison-verdict (compare same)) 'cheaper)
  (check-equal? (comparison-p (compare same)) 1)
  ;; equally right at the same cost, and a difference too small to count: nothing shown
  (define level (for/list ([i (in-range 60)]) (paired (number->string i) (list (pass (< i 55) 100)) (list (pass (< i 54) 100)))))
  (check-equal? (comparison-verdict (compare level)) 'no-difference-shown)
  ;; the other way round is said too
  (define behind (for/list ([p (in-list clear)]) (paired (paired-id p) (paired-gs p) (paired-ls p))))
  (check-equal? (comparison-verdict (compare behind)) 'worse)
  ;; the interval is the same for the same data (a seeded generator)
  (check-equal? (comparison-diff-interval (compare level)) (comparison-diff-interval (compare level)))
  (check-equal? (verdict-of 0.02 (interval -0.01 0.05) (interval 0.4 0.5)) 'cheaper)
  (check-equal? (verdict-of 0.02 (interval -0.05 0.05) (interval 0.4 0.5)) 'no-difference-shown)
  (check-equal? (verdict-of 0.06 (interval 0.01 0.1) #f) 'more-right)
  (check-equal? (verdict-of 0.04 (interval 0.01 0.1) #f) 'no-difference-shown)
  ;; a clear null is both intervals inside the bounds
  (check-true (clear-null? (interval -0.03 0.04) (interval 0.8 1.2)))
  (check-false (clear-null? (interval -0.03 0.08) (interval 0.8 1.2)))
  (check-false (clear-null? (interval -0.03 0.04) (interval 0.5 0.9)))
  (check-true (clear-null? (interval -0.03 0.04) #f)))
