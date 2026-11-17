#lang racket/base

;;; check-rows.rkt — a workspace's tables held to the relational database itself, row for row.
;;;
;;;   racket -l- fhir-examples/agent-bench/fab/check-rows [--table T]… [--show N] REFERENCE.sqlite WORKSPACE
;;;
;;; check-tables.rkt asks a workspace the benchmark's queries: it sees a table only through the
;;; rows those queries happen to read. When the relational data is at hand — FHIR-AgentBench's
;;; database is the MIMIC-IV Clinical Database Demo's CSV files loaded by its create_db.py — each
;;; table of the schema (schema.md) can be compared whole: the rows only the reference has, the
;;; rows only the workspace has, and for each column how many of its values the other side lacks,
;;; which says which column to look at. Rows are compared as multisets (a table has no key here),
;;; cells as check-tables compares them (a number and its text are one value).
;;;
;;; A Row is a (listof Cell); a Cell is a string, a number or 'null.
;;; A Comparison is (comparison table columns reference workspace missing extra by-column):
;;; counts of rows, the rows only one side has, and per column the count of reference values the
;;; workspace lacks.

(require racket/cmdline racket/file racket/list racket/string racket/runtime-path db
         (only-in fhir/lang/workspace run-result-columns run-result-rows))

(provide schema-tables multiset-difference cell-key compare-rows (struct-out comparison))

(define-runtime-path schema-file "schema.md")

;; schema-tables : string -> (listof (cons table (listof column)))   the tables and columns of
;; schema.md's table: a row names its table, or leaves it empty to continue the one above
(define (schema-tables text)
  (define rows
    (for/list ([l (in-list (string-split text "\n"))]
               #:when (regexp-match? #px"^[|]\\s*(`[a-z_]+`)?\\s*[|]\\s*`" l))
      (define cells (map string-trim (string-split l "|" #:trim? #f)))
      (cons (cond [(regexp-match #px"`([a-z_]+)`" (cadr cells)) => cadr] [else #f])
            (regexp-match* #px"`([a-z_]+)`" (caddr cells) #:match-select cadr))))
  (for/fold ([acc '()] #:result (reverse acc)) ([r (in-list rows)])
    (cond [(car r) (cons (cons (car r) (cdr r)) acc)]
          [(null? acc) acc]
          [else (cons (cons (caar acc) (append (cdar acc) (cdr r))) (cdr acc))])))

;; cell-key : Cell -> string   one text for a value however it is typed: 5, 5.0 and "5" are one
(define (cell-key c)
  (define n (cond [(real? c) (and (rational? c) c)]
                  [(and (string? c) (string->number (string-trim c))) => (lambda (n) (and (rational? n) n))]
                  [else #f]))
  (cond [n (let ([r (/ (round (* (inexact->exact n) 10000)) 10000)]) (number->string (if (integer? r) r (exact->inexact r))))]
        [(string? c) (string-append "'" c)]
        [else "∅"]))

;; multiset-difference : (listof string) (listof string) -> (listof string)   the keys of `as`
;; that `bs` does not hold, each as often as it is short
(define (multiset-difference as bs)
  (define have (make-hash))
  (for ([b (in-list bs)]) (hash-update! have b add1 0))
  (for/list ([a (in-list as)]
             #:unless (let ([n (hash-ref have a 0)]) (and (positive? n) (hash-set! have a (sub1 n)) #t)))
    a))

(struct comparison (table columns reference workspace missing extra by-column) #:transparent)

;; compare-rows : string (listof string) (listof Row) (listof Row) -> Comparison
(define (compare-rows table columns ref ws)
  (define (row-key r) (string-join (map cell-key r) "\t"))
  (define ref-keys (map row-key ref))
  (define ws-keys (map row-key ws))
  (comparison table columns (length ref) (length ws)
              (multiset-difference ref-keys ws-keys)
              (multiset-difference ws-keys ref-keys)
              (for/list ([c (in-list columns)] [i (in-naturals)])
                (cons c (length (multiset-difference (map (lambda (r) (cell-key (list-ref r i))) ref)
                                                     (map (lambda (r) (cell-key (list-ref r i))) ws)))))))

;; cell : any -> Cell   a value of either database
(define (cell v) (cond [(or (string? v) (real? v)) v] [else 'null]))

(module+ main
  (define tables '())
  (define show 5)
  (define-values (reference workspace)
    (command-line
     #:program "check-rows"
     #:once-each
     [("--show") n "rows to print of each side's own (default 5)" (set! show (string->number n))]
     #:multi
     [("--table") t "only this table" (set! tables (cons t tables))]
     #:args (reference workspace) (values reference workspace)))
  (define schema (filter (lambda (t) (or (null? tables) (member (car t) tables)))
                         (schema-tables (file->string schema-file))))
  (define open-hub (dynamic-require 'fhir/mcp/workspace 'open-hub))
  (define execute (dynamic-require 'fhir/mcp/run 'execute))
  (define h (open-hub workspace))
  (define c (sqlite3-connect #:database reference #:mode 'read-only))
  (define results
    (for/list ([t (in-list schema)])
      (define select (format "SELECT ~a FROM ~a" (string-join (cdr t) ", ") (car t)))
      (define ref (for/list ([r (in-list (query-rows c select))]) (map cell (vector->list r))))
      (define ws
        (with-handlers ([exn:fail? (lambda (e) (car (string-split (exn-message e) "\n")))])
          (define r (execute h "sql" #f select (hasheq)))
          (define cols (map (lambda (c) (string->symbol (format "~a" c))) (run-result-columns r)))
          (for/list ([row (in-list (run-result-rows r))])
            (for/list ([col (in-list cols)]) (cell (hash-ref row col 'null))))))
      (if (string? ws) (cons (car t) ws) (compare-rows (car t) (cdr t) ref ws))))
  (disconnect c)
  (printf "~a ~a ~a ~a ~a  columns: values of the reference the workspace lacks\n"
          (~a* "table" 20) (~a* "reference" 10) (~a* "workspace" 10) (~a* "missing" 8) (~a* "extra" 8))
  (for ([r (in-list results)])
    (cond
      [(pair? r) (printf "~a ~a\n" (~a* (car r) 20) (cdr r))]
      [else
       (printf "~a ~a ~a ~a ~a  ~a\n" (~a* (comparison-table r) 20) (~a* (comparison-reference r) 10)
               (~a* (comparison-workspace r) 10) (~a* (length (comparison-missing r)) 8) (~a* (length (comparison-extra r)) 8)
               (string-join (for/list ([p (in-list (comparison-by-column r))] #:when (positive? (cdr p))) (format "~a ~a" (car p) (cdr p))) ", "))]))
  (for ([r (in-list results)] #:when (and (comparison? r) (positive? show)
                                          (or (pair? (comparison-missing r)) (pair? (comparison-extra r)))))
    (printf "\n~a (~a)\n" (comparison-table r) (string-join (comparison-columns r) ", "))
    (for ([side (list (cons "only the reference has" (comparison-missing r)) (cons "only the workspace has" (comparison-extra r)))]
          #:when (pair? (cdr side)))
      (printf "  ~a:\n" (car side))
      (for ([k (in-list (take (sort (cdr side) string<?) (min show (length (cdr side)))))])
        (printf "    ~a\n" (string-replace k "\t" " | ")))))
  (exit (if (for/and ([r (in-list results)])
              (and (comparison? r) (null? (comparison-missing r)) (null? (comparison-extra r))))
            0 1)))

;; ~a* : any width -> string   left-aligned in a column
(define (~a* x w)
  (define s (format "~a" x))
  (string-append s (make-string (max 0 (- w (string-length s))) #\space)))

(module+ test
  (require rackunit)
  (check-equal? (schema-tables (string-append "| table | column | meaning |\n|---|---|---|\n"
                                              "| `patients` | `subject_id` | the patient |\n| | `gender` | M or F |\n"
                                              "| `icustays` | `hadm_id`, `stay_id` | the stay |\n| | `intime`, `outtime` | when |\n"
                                              "\n`check-tables.rkt` asks a workspace.\n"))
                '(("patients" "subject_id" "gender") ("icustays" "hadm_id" "stay_id" "intime" "outtime")))
  (check-equal? (length (schema-tables (file->string schema-file))) 15)
  (check-equal? (map cell-key (list 5 5.0 "5" " 5 " 98.60000001 "5 mg" 'null "" "1e999")) '("5" "5" "5" "5" "98.6" "'5 mg" "∅" "'" "'1e999"))
  (check-equal? (multiset-difference '("a" "a" "b" "c") '("a" "c" "d")) '("a" "b"))
  (define cmp (compare-rows "t" '("id" "v")
                            '((1 "x") (2 "y") (2 "y") (3 null))
                            '((1 "x") ("2" "y") (3 "z") (4 "w"))))
  (check-equal? (list (comparison-reference cmp) (comparison-workspace cmp)) '(4 4))
  (check-equal? (comparison-missing cmp) '("2\t'y" "3\t∅") "a row twice in the reference and once in the workspace is short once")
  (check-equal? (comparison-extra cmp) '("3\t'z" "4\t'w"))
  (check-equal? (comparison-by-column cmp) '(("id" . 1) ("v" . 2))))
