#lang racket/base

;;; spec-first.rkt — experiment S of value-experiment/PROTOCOL.md: a measure implemented from its
;;; English narrative (N) or from its CQL (S), by independent implementers, held to its authors'
;;; test cases.
;;;
;;;   racket spec-first.rkt run OUT [--implementers 5] [--measures a,b] [--arms N,S] [--parallel 4] [--model M]
;;;   racket spec-first.rkt score OUT       each implementation run over every case of its measure
;;;   racket spec-first.rkt report OUT      right, agreement and cost by arm, with the intervals
;;;
;;; An implementation is OUT/<measure>-<arm>-<i>/: the implementer's directory (measure.py among
;;; its files), record.json (the session: tokens, seconds, commands), and after `score`,
;;; score.json: for each case of the measure, whether it was in the sample, the expected
;;; populations, and the answer or the error.
;;;
;;; Data definitions.
;;; An Outcome is (outcome sample? right? answer): one case under one implementation; answer is
;;; the four booleans in `populations`' order, or #f when the implementation failed on the case.
;;; An Impl is (impl measure arm outcomes cost): outcomes is a hash case-id -> Outcome; cost a
;;; hasheq of the session's input_tokens, output_tokens, seconds, turns.

(require racket/file racket/list racket/string racket/math racket/system racket/runtime-path json
         "materials.rkt"
         (only-in "../../agent-bench/run-agent.rkt" run-item in-parallel audit current-resume? read-json-file write-json-file))

(provide (struct-out outcome) (struct-out impl)
         share-right agreement difference bootstrap-difference permutation-p agreement-interval)

(struct outcome (sample? right? answer) #:transparent)
(struct impl (measure arm outcomes cost) #:transparent)

(define-runtime-path try-script "try.py")

;; ---- run ---------------------------------------------------------------------------------------------
;; what an implementer may do: Python and reading and writing in its own directory
(define builtin '("Bash" "Read" "Write" "Edit" "Glob" "Grep"))
(define allowed '("Bash(python3:*)" "Bash(ls:*)" "Bash(cat:*)" "Bash(head:*)" "Bash(tail:*)" "Bash(grep:*)" "Bash(wc:*)"
                  "Read" "Write" "Edit" "Glob" "Grep"))
;; what its commands must not name: the network, and where the material came from
(define forbidden '("http://" "https://" "urllib" "requests" "socket" "pip " "curl" "wget" "git " "/home/" "qicore-2024" "ecqm-content"))

(define (impl-id m arm i) (format "~a-~a-~a" (short-name m) arm i))

;; run-one! : dir measure Arm natural model -> void
(define (run-one! out m arm i model)
  (define id (impl-id m arm i))
  (define work (build-path out id))
  (define rec
    (run-item id (task-prompt m arm) work model allowed
              #:prepare (lambda () (prepare-task! m arm work))
              #:builtin builtin #:timeout 3000 #:max-turns 150))
  (define bad (audit rec forbidden))
  (unless (null? bad) (display-lines-to-file bad (build-path work "AUDIT") #:exists 'truncate))
  (printf "~a ~as in ~a out ~a turns ~a~a\n" id (hash-ref rec 'seconds) (hash-ref rec 'input_tokens)
          (hash-ref rec 'output_tokens) (hash-ref rec 'turns)
          (cond [(not (file-exists? (build-path work "measure.py"))) "  NO measure.py"] [(null? bad) ""] [else "  AUDIT"]))
  (flush-output))

;; ---- score -------------------------------------------------------------------------------------------
;; implementations : dir -> (listof (list id measure Arm))   the implementation directories of a run
(define (implementations out)
  (for*/list ([m (in-list measures)] [arm (in-list '(N S))] [i (in-range 1 100)]
              #:when (directory-exists? (build-path out (impl-id m arm i))))
    (list (impl-id m arm i) m arm)))

;; score-one! : dir id measure dir -> void   the implementation's measure.py over every case
(define (score-one! out id m cases-dir)
  (define work (build-path out id))
  (define results-file (build-path work "results.json"))
  (define measure-file (build-path work "measure.py"))
  (when (file-exists? results-file) (delete-file results-file))
  (define results
    (cond [(not (file-exists? measure-file)) (hasheq)]
          [else
           ;; what the run prints goes to a file: a pipe nobody reads would stop it
           (define log (open-output-file (build-path work "score.log") #:exists 'truncate))
           (define-values (proc _o i _e)
             (subprocess log #f 'stdout (find-executable-path "python3")
                         (path->string try-script) "--cases" (path->string cases-dir) "--measure" (path->string measure-file)
                         "--valuesets" (path->string (build-path work "valuesets.json")) "--json" (path->string results-file)))
           (close-output-port i)
           (unless (sync/timeout 900 proc) (subprocess-kill proc #t))
           (close-output-port log)
           (if (file-exists? results-file) (read-json-file results-file) (hasheq))]))
  (write-json-file
   (build-path work "score.json")
   (hasheq 'measure m
           'cases (for/hasheq ([c (in-list (case-ids m))])
                    (define r (hash-ref results (string->symbol c) (hasheq 'error "no answer: measure.py missing, or the run did not finish")))
                    (define expected (case-expected m c))
                    (define answer (hash-ref r 'answer #f))
                    (values (string->symbol c)
                            (hasheq 'sample (sample-case? m c)
                                    'expected (for/hasheq ([p (in-list populations)]) (values (string->symbol p) (hash-ref expected p)))
                                    'answer (or answer (json-null))
                                    'error (hash-ref r 'error (json-null))
                                    'right (and answer (for/and ([p (in-list populations)])
                                                         (equal? (hash-ref answer (string->symbol p) 'none) (hash-ref expected p))))))))))

;; read-impl : dir id measure Arm -> Impl   a scored implementation
(define (read-impl out id m arm)
  (define score (read-json-file (build-path out id "score.json")))
  (define rec (let ([f (build-path out id "record.json")]) (if (file-exists? f) (read-json-file f) (hasheq))))
  (impl m arm
        (for/hash ([(c v) (in-hash (hash-ref score 'cases))])
          (define answer (hash-ref v 'answer))
          (values (symbol->string c)
                  (outcome (hash-ref v 'sample) (and (hash-ref v 'right) #t)
                           (and (hash? answer) (for/list ([p (in-list populations)]) (hash-ref answer (string->symbol p)))))))
        (for/hasheq ([k (in-list '(input_tokens output_tokens seconds turns))])
          (values k (let ([v (hash-ref rec k 0)]) (if (real? v) v 0))))))

;; ---- analysis ----------------------------------------------------------------------------------------
(define (mean xs) (if (null? xs) 0 (/ (apply + xs) (length xs))))

;; held-cases : Impl -> (listof string)   the cases an implementer was not shown, in name order
(define (held-cases i)
  (sort (for/list ([(c o) (in-hash (impl-outcomes i))] #:unless (outcome-sample? o)) c) string<?))

;; share-right : (listof Impl) [(listof case) per impl] -> real   pooled over implementations and
;; their held-out cases
(define (share-right impls)
  (define rights (for*/list ([i (in-list impls)] [c (in-list (held-cases i))])
                   (if (outcome-right? (hash-ref (impl-outcomes i) c)) 1 0)))
  (mean rights))

;; of-arm : (listof Impl) Arm [measure] -> (listof Impl)
(define (of-arm impls arm [m #f])
  (filter (lambda (i) (and (eq? (impl-arm i) arm) (or (not m) (equal? (impl-measure i) m)))) impls))

;; difference : (listof Impl) -> real   S's share right less N's
(define (difference impls) (- (share-right (of-arm impls 'S)) (share-right (of-arm impls 'N))))

;; agreement : (listof Impl) -> real   over the held-out cases of the measures these implement, the
;; share on which every implementation of a measure gives the same four answers (a failure on a
;; case agrees with nothing)
(define (agreement impls)
  (mean (for*/list ([m (in-list (remove-duplicates (map impl-measure impls)))]
                    [group (in-value (filter (lambda (i) (equal? (impl-measure i) m)) impls))]
                    [c (in-list (held-cases (car group)))])
          (define answers (map (lambda (i) (outcome-answer (hash-ref (impl-outcomes i) c))) group))
          (if (and (andmap values answers) (= 1 (length (remove-duplicates answers)))) 1 0))))

(define (seeded-rng seed)
  (define rng (make-pseudo-random-generator))
  (parameterize ([current-pseudo-random-generator rng]) (random-seed seed))
  rng)

(define (percentiles vs)
  (define sorted (list->vector (sort vs <)))
  (define k (vector-length sorted))
  (cons (vector-ref sorted (exact-floor (* 0.025 (- k 1)))) (vector-ref sorted (exact-ceiling (* 0.975 (- k 1))))))

;; resampled : (listof Impl) rng (listof Arm) -> (listof Impl)   within each measure: its held-out
;; cases drawn with replacement (the same draw for every arm: a case is paired), and within each
;; measure and arm its implementations drawn with replacement. An implementation's outcomes become
;; a list in the drawn cases' order, under fresh names, so a case drawn twice counts twice.
(define (resampled impls rng [resample-impls? #t])
  (parameterize ([current-pseudo-random-generator rng])
    (append*
     (for/list ([m (in-list (remove-duplicates (map impl-measure impls)))])
       (define group (filter (lambda (i) (equal? (impl-measure i) m)) impls))
       (define cases (list->vector (held-cases (car group))))
       (define n (vector-length cases))
       (define drawn (for/list ([_ (in-range n)]) (vector-ref cases (random n))))
       (append*
        (for/list ([arm (in-list (remove-duplicates (map impl-arm group)))])
          (define mine (list->vector (filter (lambda (i) (eq? (impl-arm i) arm)) group)))
          (for/list ([k (in-range (vector-length mine))])
            (define i (vector-ref mine (if resample-impls? (random (vector-length mine)) k)))
            (impl m arm
                  (for/hash ([c (in-list drawn)] [j (in-naturals)])
                    (values (format "~a#~a" c j) (hash-ref (impl-outcomes i) c)))
                  (impl-cost i)))))))))

;; bootstrap-difference : (listof Impl) [natural] -> (cons low high)   the 95% interval of S − N
(define (bootstrap-difference impls [resamples 4000])
  (define rng (seeded-rng 20261122))
  (percentiles (for/list ([_ (in-range resamples)]) (exact->inexact (difference (resampled impls rng))))))

;; agreement-interval : (listof Impl) [natural] -> (cons low high)   of agreement(S) − agreement(N),
;; the cases resampled (the implementers are the ones there are)
(define (agreement-interval impls [resamples 4000])
  (define rng (seeded-rng 20261123))
  (percentiles (for/list ([_ (in-range resamples)])
                 (define r (resampled impls rng #f))
                 (exact->inexact (- (agreement (of-arm r 'S)) (agreement (of-arm r 'N)))))))

;; permutation-p : (listof Impl) [natural] -> real   how often arm labels shuffled within each
;; measure give a difference at least as large (two-sided)
(define (permutation-p impls [shuffles 20000])
  (define rng (seeded-rng 20261124))
  (define observed (abs (difference impls)))
  (define by-measure (for/list ([m (in-list (remove-duplicates (map impl-measure impls)))])
                       (filter (lambda (i) (equal? (impl-measure i) m)) impls)))
  (parameterize ([current-pseudo-random-generator rng])
    (/ (for/sum ([_ (in-range shuffles)])
         (define relabelled
           (append* (for/list ([group (in-list by-measure)])
                      (for/list ([i (in-list (shuffle group))] [arm (in-list (map impl-arm group))])
                        (impl (impl-measure i) arm (impl-outcomes i) (impl-cost i))))))
         (if (>= (abs (difference relabelled)) observed) 1 0))
       shuffles)))

;; ---- report ------------------------------------------------------------------------------------------
(define (percent x) (format "~a%" (/ (round (* 1000.0 x)) 10.0)))
(define (points x) (format "~a~a" (if (negative? x) "" "+") (/ (round (* 1000.0 x)) 10.0)))
(define (thousands x) (format "~ak" (/ (round (/ x 100.0)) 10.0)))

(define (report impls)
  (define (cost-mean arm key) (mean (map (lambda (i) (hash-ref (impl-cost i) key)) (of-arm impls arm))))
  (printf "implementations: ~a from the narrative (N), ~a from the specification (S)\n"
          (length (of-arm impls 'N)) (length (of-arm impls 'S)))
  (printf "held-out cases: ~a\n\n" (for/sum ([m (in-list (remove-duplicates (map impl-measure impls)))])
                                     (length (held-cases (car (filter (lambda (i) (equal? (impl-measure i) m)) impls))))))
  (printf "~a  ~a  ~a  ~a  ~a\n" "measure  " "N right (each implementer)        " "N agree" "S right (each implementer)        " "S agree")
  (for ([m (in-list (remove-duplicates (map impl-measure impls)))])
    (define (each arm) (string-join (map (lambda (i) (percent (share-right (list i)))) (of-arm impls arm m)) " "))
    (printf "~a  ~a  ~a  ~a  ~a\n" (short-name m) (each 'N) (percent (agreement (of-arm impls 'N m)))
            (each 'S) (percent (agreement (of-arm impls 'S m)))))
  (define d (difference impls))
  (define ci (bootstrap-difference impls))
  (define ad (- (agreement (of-arm impls 'S)) (agreement (of-arm impls 'N))))
  (define aci (agreement-interval impls))
  (printf "\nright        N ~a, S ~a: S − N = ~a points (95% interval ~a to ~a; permutation p = ~a)\n"
          (percent (share-right (of-arm impls 'N))) (percent (share-right (of-arm impls 'S)))
          (points d) (points (car ci)) (points (cdr ci)) (exact->inexact (/ (round (* 10000 (permutation-p impls))) 10000)))
  (printf "agreement    N ~a, S ~a: S − N = ~a points (95% interval ~a to ~a)\n"
          (percent (agreement (of-arm impls 'N))) (percent (agreement (of-arm impls 'S)))
          (points ad) (points (car aci)) (points (cdr aci)))
  (printf "cost         an implementation: N ~a input and ~a output tokens, ~a turns, ~a s; S ~a and ~a, ~a turns, ~a s\n"
          (thousands (cost-mean 'N 'input_tokens)) (thousands (cost-mean 'N 'output_tokens))
          (exact->inexact (/ (round (* 10 (cost-mean 'N 'turns))) 10)) (exact-round (cost-mean 'N 'seconds))
          (thousands (cost-mean 'S 'input_tokens)) (thousands (cost-mean 'S 'output_tokens))
          (exact->inexact (/ (round (* 10 (cost-mean 'S 'turns))) 10)) (exact-round (cost-mean 'S 'seconds)))
  (printf "verdict      ~a\n"
          (cond [(and (> (car ci) 0) (>= d 0.05)) "the specification's implementers are right more often (the protocol's \"significant value\")"]
                [(and (< (cdr ci) 0) (<= d -0.05)) "the narrative's implementers are right more often"]
                [else "no difference shown in being right"])))

(module+ main
  (define args (vector->list (current-command-line-arguments)))
  (define (option name default)
    (define at (member name args))
    (if (and at (pair? (cdr at))) (cadr at) default))
  (when (< (length args) 2) (raise-user-error 'spec-first "spec-first.rkt run|score|report OUT [options]"))
  (define out (path->complete-path (cadr args)))
  (case (car args)
    [("run")
     (define k (string->number (option "--implementers" "5")))
     (define chosen (let ([names (string-split (option "--measures" (string-join (map short-name measures) ",")) ",")])
                      (filter (lambda (m) (member (short-name m) names)) measures)))
     (define arms (map string->symbol (string-split (option "--arms" "N,S") ",")))
     (define model (option "--model" "sonnet"))
     (when (member "--resume" args) (current-resume? #t))
     (make-directory* out)
     (define items (for*/list ([i (in-range 1 (+ k 1))] [m (in-list chosen)] [arm (in-list arms)]) (list m arm i)))
     (void (in-parallel (string->number (option "--parallel" "4")) items
                        (lambda (it) (run-one! out (car it) (cadr it) (caddr it) model))))
     (printf "ALL DONE: ~a implementations\n" (length items))]
    [("score")
     (define cases-root (build-path out "_cases"))
     (for ([m (in-list measures)])
       (define dir (build-path cases-root (short-name m)))
       (unless (directory-exists? dir) (write-cases! m dir (lambda (_) #t))))
     (for ([it (in-list (implementations out))])
       (score-one! out (car it) (cadr it) (build-path cases-root (short-name (cadr it))))
       (define i (read-impl out (car it) (cadr it) (caddr it)))
       (printf "~a held-out right ~a\n" (car it) (percent (share-right (list i)))))]
    [("report") (report (for/list ([it (in-list (implementations out))]) (read-impl out (car it) (cadr it) (caddr it))))]
    [else (raise-user-error 'spec-first "spec-first.rkt run|score|report OUT [options]")]))

(module+ test
  (require rackunit)
  ;; a made measure of 10 held-out cases and 2 sample ones; an implementation right on the first k
  (define (made m arm k [wrong-answer '(#t #t #f #f)])
    (impl m arm
          (for/hash ([c (in-range 12)])
            (define held? (< c 10))
            (values (format "c~a" c)
                    (outcome (not held?) (or (not held?) (< c k)) (if (or (not held?) (< c k)) '(#t #t #f #t) wrong-answer))))
          (hasheq 'input_tokens 1000 'output_tokens 100 'seconds 10 'turns 5)))
  (define impls (append (for/list ([_ (in-range 5)]) (made "m" 'S 10))
                        (list (made "m" 'N 5) (made "m" 'N 5) (made "m" 'N 5) (made "m" 'N 4) (made "m" 'N 5))))
  ;; the sample is not counted: every S implementation is right on its 10 held-out cases
  (check-equal? (share-right (of-arm impls 'S)) 1)
  (check-equal? (share-right (of-arm impls 'N)) 12/25)
  (check-equal? (difference impls) 13/25)
  ;; agreement: S's five agree on every case; N's agree on the four every one gets right and on
  ;; the five every one gets wrong the same way, not on the one that one of them alone gets wrong
  (check-equal? (agreement (of-arm impls 'S)) 1)
  (check-equal? (agreement (of-arm impls 'N)) 9/10)
  ;; the same wrong answer is agreement; a failure is not
  (check-equal? (agreement (list (made "m" 'N 5) (made "m" 'N 5))) 1)
  (check-equal? (agreement (list (made "m" 'N 5 #f) (made "m" 'N 5 #f))) 1/2)
  ;; the interval holds the difference, is the same each time, and excludes zero here
  (define ci (bootstrap-difference impls 500))
  (check-true (<= (car ci) 0.52 (cdr ci)))
  (check-true (> (car ci) 0))
  (check-equal? ci (bootstrap-difference impls 500))
  (check-true (< (permutation-p impls 2000) 0.05))
  ;; no difference: the labels do not matter
  (define level (append (for/list ([_ (in-range 5)]) (made "m" 'S 8)) (for/list ([_ (in-range 5)]) (made "m" 'N 8))))
  (check-equal? (difference level) 0)
  (check-equal? (permutation-p level 200) 1)
  (check-true (<= (car (agreement-interval impls 300)) 0.1 (cdr (agreement-interval impls 300)))))
