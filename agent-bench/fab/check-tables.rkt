#lang racket/base

;;; check-tables.rkt — a workspace's tables held to FHIR-AgentBench's own queries, with no model.
;;;
;;;   racket -l- fhir-examples/agent-bench/fab/check-tables WORKSPACE [--split train] [--table T]…
;;;          [--limit N] [--show N] [--ids FILE] [--json OUT]
;;;
;;; The benchmark's answers are SQL over MIMIC-IV's relational tables (`sql_query`, `true_answer` in
;;; its questions_answers_sql_fhir.csv); an agent is given the same data as FHIR. A workspace that
;;; defines those tables over the FHIR store — ViewDefinitions (`*.view.json`) and tables defined
;;; over them (`*.sql`) — can be asked the benchmark's own queries, unchanged, and each answer
;;; compared with the benchmark's. The pass rate says how faithfully the tables state the schema;
;;; a failure names the question, the query, what was expected and what came back.
;;;
;;; An Outcome is (outcome id table ok? expected got): `got` the rows as lists of cells, or a string
;;; (the error). A Cell is a string, a number or 'null.
;;;
;;; FAB_REPO: a checkout of github.com/glee4810/FHIR-AgentBench.

(require racket/cmdline racket/file racket/list racket/string json
         (only-in fhir/lang/workspace run-result-columns run-result-rows)
         (only-in "make-sample.rkt" read-csv))

(provide parse-answer same-answer?)

;; ---- the benchmark's answers ----------------------------------------------------------------------
;; parse-answer : string -> (listof (listof Cell))   numpy's printing of a result set: `[]`,
;; `[[1]]`, `[['a']\n ['b']]`, `[[None]]`, `[[109.6]\n [110. ]]`
(define (parse-answer s)
  (define inner (regexp-replace #px"^\\s*\\[(.*)\\]\\s*$" s "\\1"))
  (for/list ([row (in-list (regexp-match* #px"\\[((?:'(?:[^'\\\\]|\\\\.)*'|\"(?:[^\"\\\\]|\\\\.)*\"|[^\\]'\"])*)\\]" inner #:match-select cadr))])
    (for/list ([cell (in-list (regexp-match* #px"'(?:[^'\\\\]|\\\\.)*'|\"(?:[^\"\\\\]|\\\\.)*\"|[^\\s'\"]+" row))])
      (cond [(regexp-match #px"^['\"](.*)['\"]$" cell) => (lambda (m) (regexp-replace* #px"\\\\(.)" (cadr m) "\\1"))]
            [(member cell '("None" "nan")) 'null]
            [(string->number (regexp-replace #px"[.]$" cell "")) => values]
            [else cell]))))

;; same-cell? : Cell Cell -> boolean   numbers to six significant digits (numpy prints eight); a
;; number and its text are the same value
(define (same-cell? a b)
  (define (num x) (cond [(real? x) x] [(and (string? x) (string->number (string-trim x))) => (lambda (n) (and (real? n) n))] [else #f]))
  (cond [(and (eq? a 'null) (eq? b 'null)) #t]
        [(and (num a) (num b))
         (let ([x (num a)] [y (num b)]) (<= (abs (- x y)) (* 1e-6 (max 1 (abs x) (abs y)))))]
        [(and (string? a) (string? b)) (string=? a b)]
        [else #f]))

;; same-answer? : rows rows -> boolean   the same rows, in any order
(define (same-answer? expected got)
  (define (key row) (format "~s" (for/list ([c (in-list row)]) (if (real? c) (exact->inexact (/ (round (* c 1000)) 1000)) c))))
  (and (= (length expected) (length got))
       (let ([e (sort expected string<? #:key key)] [g (sort got string<? #:key key)])
         (for/and ([x (in-list e)] [y (in-list g)])
           (and (= (length x) (length y)) (andmap same-cell? x y))))))

;; ---- the questions ----------------------------------------------------------------------------------
;; questions : csv-file -> (listof (hash column -> string))
(define (questions file)
  (define rows (read-csv (file->string file)))
  (define header (map string->symbol (car rows)))
  (for/list ([r (in-list (cdr rows))]) (for/hasheq ([k (in-list header)] [v (in-list r)]) (values k v))))

;; ---- running ------------------------------------------------------------------------------------------
(struct outcome (id table ok? expected got sql) #:transparent)

;; ask : (sql -> run-result) question -> Outcome
(define (ask run q)
  (define expected (parse-answer (hash-ref q 'true_answer)))
  (define got
    (with-handlers ([exn:fail? (lambda (e) (car (string-split (exn-message e) "\n")))])
      (define r (run (hash-ref q 'sql_query)))
      (define cols (map (lambda (c) (string->symbol (format "~a" c))) (run-result-columns r)))
      (for/list ([row (in-list (run-result-rows r))])
        (for/list ([c (in-list cols)]) (let ([v (hash-ref row c 'null)]) (if (or (string? v) (real? v)) v 'null))))))
  (outcome (hash-ref q 'question_id) (hash-ref q 'main_table_name "?")
           (and (list? got) (same-answer? expected got)) expected got (hash-ref q 'sql_query)))

(module+ main
  (define split "train")
  (define tables '())
  (define limit #f)
  (define show 10)
  (define ids-file #f)
  (define json-out #f)
  (define workspace
    (command-line
     #:program "check-tables"
     #:once-each
     [("--split") s "train (default), valid or test" (set! split s)]
     [("--limit") n "the first N questions" (set! limit (string->number n))]
     [("--show") n "failures to print (default 10)" (set! show (string->number n))]
     [("--ids") f "only the question ids listed in this file (one to a line; a prefix is enough)" (set! ids-file f)]
     [("--json") f "write every outcome to this file" (set! json-out f)]
     #:multi
     [("--table") t "only questions whose main table is T" (set! tables (cons t tables))]
     #:args (workspace) workspace))
  (define repo (or (getenv "FAB_REPO") (raise-user-error 'check-tables "FAB_REPO names a checkout of FHIR-AgentBench")))
  (define ids (and ids-file (filter (lambda (l) (not (string=? l ""))) (map string-trim (file->lines ids-file)))))
  (define qs
    (let* ([all (questions (build-path repo "final_dataset" "questions_answers_sql_fhir.csv"))]
           [qs (filter (lambda (q) (and (or ids (equal? (hash-ref q 'split) split))
                                        (or (null? tables) (member (hash-ref q 'main_table_name) tables))
                                        (or (not ids) (for/or ([i (in-list ids)]) (string-prefix? (hash-ref q 'question_id) i)))))
                       all)])
      (if limit (take qs (min limit (length qs))) qs)))
  (define open-hub (dynamic-require 'fhir/mcp/workspace 'open-hub))
  (define execute (dynamic-require 'fhir/mcp/run 'execute))
  (define h (open-hub workspace))
  (define started (current-inexact-milliseconds))
  (define outcomes (for/list ([q (in-list qs)]) (ask (lambda (sql) (execute h "sql" #f sql (hasheq))) q)))
  (define (share os) (format "~a/~a" (count outcome-ok? os) (length os)))
  (printf "~a questions of the ~a split, ~a s\n" (length outcomes) (if ids "listed" split)
          (round (/ (- (current-inexact-milliseconds) started) 1000)))
  (for ([g (in-list (sort (group-by outcome-table outcomes) string<? #:key (lambda (g) (outcome-table (car g)))))])
    (printf "  ~a ~a\n" (~a* (outcome-table (car g)) 22) (share g)))
  (printf "  ~a ~a\n" (~a* "all" 22) (share outcomes))
  (define failures (filter (lambda (o) (not (outcome-ok? o))) outcomes))
  ;; failures by what went wrong: the errors by message, the rest together
  (define by-error (sort (group-by (lambda (o) (if (string? (outcome-got o)) (regexp-replace* #px"[0-9]{4,}" (outcome-got o) "N") "a different answer")) failures)
                         > #:key length))
  (for ([g (in-list by-error)])
    (printf "\n~a × ~a\n" (length g) (let ([o (car g)]) (if (string? (outcome-got o)) (regexp-replace* #px"[0-9]{4,}" (outcome-got o) "N") "a different answer")))
    (for ([o (in-list (take g (min show (length g))))])
      (printf "  ~a [~a]\n    ~a\n    expected ~s\n    got      ~s\n" (substring (outcome-id o) 0 8) (outcome-table o)
              (outcome-sql o) (outcome-expected o) (if (and (list? (outcome-got o)) (> (length (outcome-got o)) 12)) (append (take (outcome-got o) 12) '(…)) (outcome-got o)))))
  (when json-out
    (call-with-output-file json-out #:exists 'truncate
      (lambda (o) (write-json (for/list ([x (in-list outcomes)])
                                (hasheq 'id (outcome-id x) 'table (outcome-table x) 'ok (and (outcome-ok? x) #t)
                                        'expected (format "~s" (outcome-expected x)) 'got (format "~s" (outcome-got x))))
                              o))))
  (exit (if (null? failures) 0 1)))

;; ~a* : string width -> string   padded on the right
(define (~a* s n) (string-append s (make-string (max 1 (- n (string-length s))) #\space)))

(module+ test
  (require rackunit)
  (check-equal? (parse-answer "[]") '())
  (check-equal? (parse-answer "[[1]]") '((1)))
  (check-equal? (parse-answer "[[None]]") '((null)))
  (check-equal? (parse-answer "[['2133-12-31 02:00:00']]") '(("2133-12-31 02:00:00")))
  (check-equal? (parse-answer "[['Heparin']\n ['Sodium Chloride 0.9%  Flush']]") '(("Heparin") ("Sodium Chloride 0.9%  Flush")))
  (check-equal? (parse-answer "[[109.6]\n [110. ]]") '((109.6) (110)))
  (check-equal? (parse-answer "[[-1.]]") '((-1)))
  (check-equal? (parse-answer "[[\"Crohn's disease\"]]") '(("Crohn's disease")))
  (check-true (same-answer? '((109.6) (110)) '((110.0) (109.6))) "any order")
  (check-true (same-answer? '((108.88571429)) '((108.885714285714))))
  (check-true (same-answer? '((1)) '(("1"))) "a number and its text")
  (check-false (same-answer? '((1)) '()))
  (check-false (same-answer? '(("a")) '(("A"))))
  (check-true (same-answer? '((null)) '((null)))))
