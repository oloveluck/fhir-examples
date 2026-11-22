#lang racket/base

;;; analysis.rkt — the comparisons of value-experiment/PROTOCOL.md, as it states them.
;;;
;;;   racket analysis.rkt fab NAME_L=RUN_DIR,RUN_DIR,… NAME_G=RUN_DIR,…
;;;
;;; Two arms' scored FHIR-AgentBench runs (fab/score.sh), paired by question: the share right of
;;; each, the difference with its interval, McNemar's test, the cost ratio with its interval, and
;;; the verdict the protocol defines.
;;;
;;; Data definitions.
;;; A Pass is (pass right? cost): one run of one task by one arm; cost is a real (input tokens) or #f.
;;; A Paired is (paired id ls gs): one task's passes by the two arms compared, L first.
;;; An Interval is (interval low high).
;;; A Comparison is (comparison tasks share-l share-g difference diff-interval p cost-ratio
;;;   ratio-interval verdict); verdict is 'more-right | 'cheaper | 'worse | 'no-difference-shown.

(require racket/list racket/math racket/string racket/file json)

(provide (struct-out pass) (struct-out paired) (struct-out interval) (struct-out comparison)
         share-right mcnemar-exact holm bootstrap-interval compare verdict-of
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

;; compare : (listof Paired) -> Comparison
(define (compare ps)
  (define items (list->vector ps))
  (define diff (difference ps))
  (define diff-ci (bootstrap-interval items difference))
  (define ratio (cost-ratio ps))
  (define ratio-ci (and ratio (bootstrap-interval items cost-ratio)))
  (define (all-right? xs) (and (pair? xs) (andmap pass-right? xs)))
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
            [else "no difference shown"])))

(module+ main
  (define args (vector->list (current-command-line-arguments)))
  (define (arm-of spec)
    (define m (regexp-match #rx"^([^=]+)=(.+)$" spec))
    (unless m (raise-user-error 'analysis "an arm is NAME=RUN_DIR,RUN_DIR,…: ~a" spec))
    (cons (cadr m) (string-split (caddr m) ",")))
  (unless (and (= (length args) 3) (equal? (car args) "fab"))
    (raise-user-error 'analysis "analysis.rkt fab NAME_L=RUN_DIR,… NAME_G=RUN_DIR,…"))
  (define l (arm-of (cadr args)))
  (define g (arm-of (caddr args)))
  (report (car l) (car g) (compare (pairs (arm-passes (cdr l)) (arm-passes (cdr g))))))

(module+ test
  (require rackunit)
  (check-equal? (share-right (list (pass #t 1) (pass #f 1) (pass #t 1))) 2/3)
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
  (check-equal? (verdict-of 0.04 (interval 0.01 0.1) #f) 'no-difference-shown))
