#lang racket/base

;;; check-ids.rkt — the resources a workspace's tables put behind an answer, held to the resources
;;; FHIR-AgentBench puts behind it, with no model.
;;;
;;;   racket -l- fhir-examples/agent-bench/fab/check-ids [--split train] [--table T]… [--limit N]
;;;          [--show N] [--ids FILE] [--json OUT] WORKSPACE
;;;
;;; The benchmark scores an answer's citations too: the FHIR resources an agent names against
;;; `true_fhir_ids`. It derives those from the answer's query (create_question_fhir_dataset.py,
;;; utils/sql_to_fhir_utils.py): the query is asked again for the ROWS of its main table — its
;;; select list replaced by `<table>.*`, everything after FROM kept; a query that compares or
;;; subtracts two sub-selects is each sub-select's rows — and each row is the resource(s) the FHIR
;;; export made of it. A workspace whose tables keep the resource behind each row in a column
;;; named `fhir_id` (or ending in `_fhir_id`, when a row stands on several) can be asked the same:
;;; the same rewrite, the id columns of the rows that come back. Where the two sets differ, either
;;; a table names another resource than the benchmark does or the rule for which rows to cite is
;;; not the one written here; the report says which ids, by table.
;;;
;;; A Citation is (citation id table expected got sql resources): the benchmark's ids and the
;;; workspace's (bare ids, the resource type dropped; `got` a string when the query failed), the
;;; queries asked, and the benchmark's ids as `Type/id`.
;;;
;;; FAB_REPO: a checkout of github.com/glee4810/FHIR-AgentBench.

(require racket/cmdline racket/file racket/list racket/string json
         (only-in fhir/lang/workspace run-result-columns run-result-rows)
         (only-in "make-sample.rkt" read-csv)
         (only-in "make-examples.rkt" read-python))

(provide cited-queries row-queries sub-selects first-sub-select main-table expected-ids expected-resources id-columns
         recall precision)

;; ---- the benchmark's rewrite ------------------------------------------------------------------------
;; groups : string -> (listof (cons start end))   the parenthesised groups at depth 0, as the
;; positions of `(` and of the character after its `)`; quoted text is skipped
(define (groups q)
  (define n (string-length q))
  (let loop ([i 0] [depth 0] [start #f] [quoted? #f] [acc '()])
    (cond
      [(= i n) (reverse acc)]
      [quoted? (loop (add1 i) depth start (not (char=? (string-ref q i) #\')) acc)]
      [else
       (case (string-ref q i)
         [(#\') (loop (add1 i) depth start #t acc)]
         [(#\() (loop (add1 i) (add1 depth) (if (zero? depth) i start) #f acc)]
         [(#\)) (if (= depth 1)
                    (loop (add1 i) 0 #f #f (cons (cons start (add1 i)) acc))
                    (loop (add1 i) (max 0 (sub1 depth)) start #f acc))]
         [else (loop (add1 i) depth start #f acc)])])))

;; select? : string -> boolean   a parenthesised group that is a query
(define (select? group) (regexp-match? #px"^\\(\\s*SELECT\\b" group))

;; inside : string -> string   a group without its parentheses
(define (inside group) (string-trim (substring group 1 (sub1 (string-length group)))))

;; top-from : string -> index or #f   where the query's own FROM stands (outside every group)
(define (top-from q)
  (define gs (groups q))
  (for/first ([m (in-list (regexp-match-positions* #px"\\bFROM\\b" q))]
              #:unless (for/or ([g (in-list gs)]) (< (car g) (car m) (cdr g))))
    (car m)))

;; sub-selects : string -> (listof string)   the sub-selects of a query's select list, without
;; their parentheses: `SELECT (SELECT …) - (SELECT …)` has two
(define (sub-selects q)
  (define end (or (top-from q) (string-length q)))
  (for/list ([g (in-list (groups q))]
             #:when (and (< (car g) end) (select? (substring q (car g) (cdr g)))))
    (inside (substring q (car g) (cdr g)))))

;; first-sub-select : string -> string or #f   the first parenthesised query anywhere in `q`
(define (first-sub-select q)
  (let loop ([gs (groups q)])
    (cond [(null? gs) #f]
          [else
           (define g (substring q (car (car gs)) (cdr (car gs))))
           (cond [(select? g) (inside g)]
                 [(first-sub-select (inside g)) => values]
                 [else (loop (cdr gs))])])))

;; main-table : string -> string   what follows the first FROM, as the benchmark reads it
(define (main-table q)
  (define m (regexp-match #px"FROM\\s+(\\S+)" q))
  (if m (cadr m) ""))

;; rows-of : string -> string   a query asked for its main table's rows: `SELECT <table>.*` and
;; everything from its first FROM on
(define (rows-of q)
  (define from (caar (or (regexp-match-positions #px"FROM\\b" q) (list (cons (string-length q) 0)))))
  (define table (main-table q))
  (format "SELECT ~a ~a" (if (string-prefix? table "(") "*" (string-append table ".*"))
          (regexp-replace #px";\\s*$" (substring q from) "")))

;; row-queries : string -> (listof string)   the queries whose rows the benchmark cites for `q`:
;;   - the title of a diagnosis or procedure is its diagnoses_icd / procedures_icd sub-select;
;;   - a query that reads from a sub-select is that sub-select;
;;   - a query over sub-selects in its select list is each of them;
;;   - any other is itself.
(define (row-queries q0)
  (define q (string-trim (regexp-replace* #px"\\s+" q0 " ")))
  (cond
    [(regexp-match? #px"^SELECT d_icd_(diagnoses|procedures)\\.long_title FROM d_icd_" q)
     (cond [(first-sub-select q) => row-queries] [else '()])]
    [(pair? (sub-selects q)) (map rows-of (sub-selects q))]
    [(string-prefix? (main-table q) "(")
     (cond [(first-sub-select q) => row-queries] [else '()])]
    [else (list (rows-of q))]))

;; cited-queries : Question -> (listof string)
(define (cited-queries q) (row-queries (hash-ref q 'sql_query)))

;; ---- ids ------------------------------------------------------------------------------------------
;; expected-resources : string -> (listof string)   `true_fhir_ids`, a Python dict of resource type
;; -> ids, as `Type/id`
(define (expected-resources text)
  (define v (if (string=? (string-trim text) "") (hash) (read-python text)))
  (remove-duplicates
   (for*/list ([type (in-list (sort (hash-keys v) string<?))] [id (in-list (let ([ids (hash-ref v type)]) (if (list? ids) ids '())))])
     (format "~a/~a" type id))))

;; expected-ids : string -> (listof string)   the same as bare ids
(define (expected-ids text) (remove-duplicates (append-map bare (expected-resources text))))

;; id-columns : (listof symbol) -> (listof symbol)   the columns that name a resource behind a row
(define (id-columns columns)
  (filter (lambda (c) (regexp-match? #px"(^|_)fhir_ids?$" (symbol->string c))) columns))

;; bare : string -> (listof string)   `Type/id` (or several, separated by spaces or commas) as ids
(define (bare cell)
  (for/list ([s (in-list (string-split cell #px"[\\s,]+"))] #:unless (string=? s ""))
    (last (string-split s "/"))))

;; recall : (listof id) (listof id) -> 0 or 1   the benchmark's binary recall: every expected id cited
(define (recall expected got) (if (andmap (lambda (e) (member e got)) expected) 1 0))

;; precision : (listof id) (listof id) -> real   the share of the cited ids that are expected
(define (precision expected got)
  (cond [(null? got) (if (null? expected) 1 0)]
        [else (/ (count (lambda (g) (member g expected)) got) (length got))]))

;; ---- running --------------------------------------------------------------------------------------
(struct citation (id table expected got sql resources) #:transparent)

;; questions : csv-file -> (listof (hash column -> string))
(define (questions file)
  (define rows (read-csv (file->string file)))
  (define header (map string->symbol (car rows)))
  (for/list ([r (in-list (cdr rows))] #:when (= (length r) (length header)))
    (for/hasheq ([k (in-list header)] [v (in-list r)]) (values k v))))

;; cite : (sql -> run-result) Question -> Citation
(define (cite run q)
  (define sqls (cited-queries q))
  (define got
    (with-handlers ([exn:fail? (lambda (e) (car (string-split (exn-message e) "\n")))])
      (remove-duplicates
       (append*
        (for/list ([sql (in-list sqls)])
          (define r (run sql))
          (define cols (id-columns (map (lambda (c) (string->symbol (format "~a" c))) (run-result-columns r))))
          (for*/list ([row (in-list (run-result-rows r))] [c (in-list cols)]
                      #:when (string? (hash-ref row c #f))
                      [id (in-list (bare (hash-ref row c)))])
            id))))))
  (citation (hash-ref q 'question_id) (hash-ref q 'main_table_name "?")
            (expected-ids (hash-ref q 'true_fhir_ids "")) got (string-join sqls " ;; ")
            (expected-resources (hash-ref q 'true_fhir_ids ""))))

(define (exact? c) (and (list? (citation-got c)) (equal? (sort (citation-expected c) string<?) (sort (citation-got c) string<?))))

(module+ main
  (define split "train")
  (define tables '())
  (define limit #f)
  (define show 5)
  (define ids-file #f)
  (define json-out #f)
  (define workspace
    (command-line
     #:program "check-ids"
     #:once-each
     [("--split") s "train (default), valid or test" (set! split s)]
     [("--limit") n "the first N questions" (set! limit (string->number n))]
     [("--show") n "differing questions to print per table (default 5)" (set! show (string->number n))]
     [("--ids") f "only the question ids listed in this file (one to a line; a prefix is enough)" (set! ids-file f)]
     [("--json") f "write every citation to this file" (set! json-out f)]
     #:multi
     [("--table") t "only questions whose main table is T" (set! tables (cons t tables))]
     #:args (workspace) workspace))
  (define repo (or (getenv "FAB_REPO") (raise-user-error 'check-ids "FAB_REPO names a checkout of FHIR-AgentBench")))
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
  (define cs (for/list ([q (in-list qs)]) (cite (lambda (sql) (execute h "sql" #f sql (hasheq))) q)))
  (printf "~a questions of the ~a split, ~a s\n" (length cs) (if ids "listed" split)
          (round (/ (- (current-inexact-milliseconds) started) 1000)))
  ;; a question the benchmark cites nothing for is counted apart: its metrics are another case
  (define (line name group)
    (define cited (filter (lambda (c) (pair? (citation-expected c))) group))
    (define ok (filter (lambda (c) (list? (citation-got c))) cited))
    (define (mean f) (if (null? ok) "-" (real->decimal-string (/ (for/sum ([c (in-list ok)]) (f (citation-expected c) (citation-got c))) (length ok)) 3)))
    (printf "  ~a ~a ~a ~a ~a ~a\n" (~a* name 20) (~a* (length cited) 6) (~a* (count exact? cited) 6)
            (~a* (mean recall) 7) (~a* (mean precision) 10)
            (let ([none (filter (lambda (c) (null? (citation-expected c))) group)])
              (format "~a/~a" (count (lambda (c) (null? (citation-got c))) none) (length none)))))
  (printf "  ~a ~a ~a ~a ~a ~a\n" (~a* "table" 20) (~a* "cited" 6) (~a* "exact" 6) (~a* "recall" 7) (~a* "precision" 10) "none cited: none here")
  (for ([g (in-list (sort (group-by citation-table cs) string<? #:key (lambda (g) (citation-table (car g)))))])
    (line (citation-table (car g)) g))
  (line "all" cs)
  (define differing (filter (lambda (c) (and (pair? (citation-expected c)) (not (exact? c)))) cs))
  (for ([g (in-list (sort (group-by citation-table differing) string<? #:key (lambda (g) (citation-table (car g)))))])
    (printf "\n~a: ~a differ\n" (citation-table (car g)) (length g))
    (for ([c (in-list (take g (min show (length g))))])
      (define got (citation-got c))
      (cond
        [(string? got) (printf "  ~a ~a\n    ~a\n" (substring (citation-id c) 0 8) got (citation-sql c))]
        [else
         (define missing (remove* got (citation-expected c)))
         (define extra (remove* (citation-expected c) got))
         (printf "  ~a expected ~a, here ~a: ~a missing~a, ~a extra~a\n    ~a\n" (substring (citation-id c) 0 8)
                 (length (citation-expected c)) (length got)
                 (length missing) (if (pair? missing) (format " (~a)" (findf (lambda (r) (string-suffix? r (car missing))) (citation-resources c))) "")
                 (length extra) (if (pair? extra) (format " (~a)" (car extra)) "")
                 (citation-sql c))])))
  (when json-out
    (call-with-output-file json-out #:exists 'truncate
      (lambda (o) (write-json (for/list ([c (in-list cs)])
                                (hasheq 'id (citation-id c) 'table (citation-table c) 'exact (and (exact? c) #t)
                                        'expected (citation-expected c)
                                        'got (if (list? (citation-got c)) (citation-got c) (format "~a" (citation-got c)))
                                        'sql (citation-sql c)))
                              o))))
  (exit (if (null? differing) 0 1)))

;; ~a* : any width -> string   padded on the right
(define (~a* x n) (let ([s (format "~a" x)]) (string-append s (make-string (max 1 (- n (string-length s))) #\space))))

(module+ test
  (require rackunit)
  (check-equal? (row-queries "SELECT COUNT(*)>0 FROM prescriptions WHERE prescriptions.drug IN ( 'Docusate (Liquid)', 'Heparin' ) AND prescriptions.hadm_id IN ( SELECT admissions.hadm_id FROM admissions WHERE admissions.subject_id = 1 )")
                '("SELECT prescriptions.* FROM prescriptions WHERE prescriptions.drug IN ( 'Docusate (Liquid)', 'Heparin' ) AND prescriptions.hadm_id IN ( SELECT admissions.hadm_id FROM admissions WHERE admissions.subject_id = 1 )")
                "the select list replaced, the rest kept; a parenthesis in a name is text")
  (check-equal? (row-queries "SELECT ( SELECT labevents.valuenum FROM labevents WHERE labevents.itemid = 1 ORDER BY labevents.charttime DESC LIMIT 1 ) - ( SELECT labevents.valuenum FROM labevents WHERE labevents.itemid = 1 ORDER BY labevents.charttime ASC LIMIT 1 );")
                '("SELECT labevents.* FROM labevents WHERE labevents.itemid = 1 ORDER BY labevents.charttime DESC LIMIT 1"
                  "SELECT labevents.* FROM labevents WHERE labevents.itemid = 1 ORDER BY labevents.charttime ASC LIMIT 1")
                "two sub-selects compared: the rows of each")
  (check-equal? (row-queries "SELECT d_icd_diagnoses.long_title FROM d_icd_diagnoses WHERE d_icd_diagnoses.icd_code IN ( SELECT diagnoses_icd.icd_code FROM diagnoses_icd WHERE diagnoses_icd.hadm_id IN ( SELECT admissions.hadm_id FROM admissions WHERE admissions.subject_id = 1 ) )")
                '("SELECT diagnoses_icd.* FROM diagnoses_icd WHERE diagnoses_icd.hadm_id IN ( SELECT admissions.hadm_id FROM admissions WHERE admissions.subject_id = 1 )")
                "a diagnosis's title: the diagnoses it is the title of")
  (check-equal? (row-queries "SELECT T1.drug FROM ( SELECT prescriptions.drug, COUNT(*) AS c FROM prescriptions GROUP BY prescriptions.drug ) AS T1 WHERE T1.c > 1")
                '("SELECT prescriptions.* FROM prescriptions GROUP BY prescriptions.drug")
                "a query over a sub-select: the sub-select's rows")
  (check-equal? (sub-selects "SELECT COUNT(*) FROM t WHERE t.x IN ( SELECT y FROM u )") '() "a sub-select after FROM is not in the select list")
  (check-equal? (first-sub-select "SELECT a FROM t WHERE f(x) = 1 AND t.x IN ( SELECT y FROM u )") "SELECT y FROM u")
  (check-equal? (main-table "SELECT x FROM  labevents WHERE 1") "labevents")
  (check-equal? (sort (expected-ids "{'Medication': ['a', 'b'], 'MedicationRequest': ['c', 'a']}") string<?) '("a" "b" "c"))
  (check-equal? (expected-resources "{'Observation': ['o'], 'Medication': ['a', 'b']}") '("Medication/a" "Medication/b" "Observation/o"))
  (check-equal? (expected-ids "{}") '())
  (check-equal? (id-columns '(subject_id fhir_id medication_fhir_id drug specimen_fhir_ids fhir_identity)) '(fhir_id medication_fhir_id specimen_fhir_ids))
  (check-equal? (bare "Observation/abc") '("abc"))
  (check-equal? (bare "Medication/a Medication/b,c") '("a" "b" "c"))
  (check-equal? (list (recall '("a" "b") '("a" "b" "c")) (recall '("a" "b") '("a"))) '(1 0))
  (check-equal? (list (precision '("a" "b") '("a" "b" "c" "d")) (precision '() '()) (precision '("a") '())) '(1/2 1 0)))
