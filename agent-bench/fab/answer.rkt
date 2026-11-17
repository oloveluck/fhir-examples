#lang racket/base

;;; answer.rkt — a question's query asked of a workspace's tables, and what follows from it written
;;; down: the answer, the resources it rests on, and how the query's shape differs from its kind's.
;;;
;;;   racket -l- fhir-examples/agent-bench/fab/answer [--kind N] [--say TEXT] [--out answer.json] "<SQL>"
;;;
;;; run in the question's workspace (the tables, `examples/<n>.md`). It
;;;   1. runs the query and prints its rows;
;;;   2. says the answer as the benchmark's people state one — the value alone, every row's value
;;;      when there are several, yes/no for a comparison, "none" when nothing was found;
;;;   3. finds the resources the answer rests on as the benchmark does (check-ids.rkt's
;;;      `row-queries`): the rows of the query's main table that meet its conditions, each row's
;;;      `…fhir_id` columns — every row of a sum, a count or a group, not one of them;
;;;   4. with --kind N, sets the query's shape (what it selects, groups by, orders by and limits,
;;;      literals aside) beside the shapes of kind N's examples, and says so when it is none of them;
;;;      and, when the workspace holds the question (question.json) and examples/checks.json, says
;;;      what query-checks.rkt finds: a phrase of the question with no condition, a name the
;;;      question does not give; and says when the first or last row it picked has no value;
;;;   5. writes {"answer", "resources"} to --out (answer.json), and when it had no note at all ends
;;;      with a line `done: …` (a session's hook may end the session on it) — unless a decisive note stands
;;;      (query-checks.rkt's `hold?`: the averaging unit only other kinds say, a value where the
;;;      question asks whether): then nothing is written and it says so; the same query given a
;;;      second time is written.
;;; The agent reads the rows and the notes; when the answer stated is not what the rows say, it gives
;;; the query again with --say TEXT, and TEXT is written as the answer over the same resources.
;;;
;;; A Shape is a string: a query with its WHERE conditions left out and its literals as `?`.

(require racket/cmdline racket/file racket/list racket/string json
         (only-in fhir/lang/workspace run-result-columns run-result-rows)
         (only-in "check-ids.rkt" row-queries id-columns sub-selects main-table)
         (only-in "query-checks.rkt" query-notes comparison? asks-whether hold? first-pick))

(provide answer-text shape example-queries shape-note all-rows empty-pick-note held? shown-note other-kinds done-line
         tied-values tie-note)

;; ---- the answer ---------------------------------------------------------------------------------
;; count? : string -> boolean   a query that counts
(define (count? sql) (regexp-match? #px"^\\s*SELECT\\s+COUNT\\s*\\(" sql))

;; cell-text : Cell -> string
(define (cell-text c)
  (cond [(and (real? c) (integer? c)) (number->string (inexact->exact c))]
        [(real? c) (number->string c)]
        [else (format "~a" c)]))

;; answer-text : string (listof (listof Cell)) boolean -> string   `found?`: some resource stands
;; behind the rows
(define (answer-text sql rows found?)
  (define cells (filter (lambda (c) (not (eq? c 'null))) (append* rows)))
  (cond
    [(null? cells) "none: nothing on record"]
    [(and (comparison? sql) (= (length cells) 1) (member (car cells) '(0 1 0.0 1.0)))
     (cond [(= 1 (car cells)) "yes"] [found? "no"] [else "no: none on record"])]
    [(and (count? sql) (= (length cells) 1) (equal? (car cells) 0)) "none: nothing on record"]
    [else (string-join (for/list ([r (in-list rows)] #:unless (andmap (lambda (c) (eq? c 'null)) r))
                         (string-join (map cell-text (filter (lambda (c) (not (eq? c 'null))) r)) " | "))
                       ", ")]))

;; ---- an answer held back -----------------------------------------------------------------------------
;; held-file : the query whose answer was held back, kept in the question's workspace
(define held-file ".held-query")

;; tied-values : (listof (list value key)) -> (listof value)   of rows in order, the distinct
;; values of those that share the first row's key — when there is more than one
(define (tied-values rows)
  (cond [(null? rows) '()]
        [else
         (define key (cadr (car rows)))
         (define values (remove-duplicates (for/list ([r (in-list rows)] #:when (equal? (cadr r) key)) (car r))))
         (if (> (length values) 1) values '())]))

;; tie-note : string (query -> (listof (listof Cell))) (listof n) -> (or string #f)   said of a
;; query that takes the first or last row when several rows share that place and differ in what
;; is selected: which one `LIMIT 1` returns is chance. `kinds` are the kinds whose examples
;; return every such row. The benchmark's own queries of this shape never meet such a tie (481
;; in the train and validation splits, none).
(define (tie-note sql rows-of kinds)
  (define pick (first-pick sql))
  (and pick
       (let* ([selected (car pick)] [rest (cadr pick)] [order (caddr pick)] [direction (cadddr pick)]
              [rows (with-handlers ([exn:fail? (lambda (_) '())])
                      (rows-of (format "SELECT ~a, ~a FROM ~a ORDER BY ~a ~a LIMIT 50" selected order rest order direction)))]
              [tied (tied-values (for/list ([r (in-list rows)] #:when (= (length r) 2)) r))])
         (and (pair? tied)
              (format "hold: ~a rows share the ~a `~a` (~a) and differ in `~a`: ~a. `LIMIT 1` returns one of them, by chance. A query of this schema that asks what was first or last returns every row of that time: `SELECT DISTINCT ~a FROM … AND ~a = ( SELECT DISTINCT ~a FROM … ORDER BY ~a ~a LIMIT 1 )`~a."
                      (length tied) (if (equal? direction "DESC") "last" "first") order (cadr (car rows)) selected
                      (string-join (for/list ([v (in-list (take tied (min 4 (length tied))))]) (format "~a" v)) ", ")
                      selected order order order direction
                      (if (pair? kinds) (format ", as kind ~a's example does (`./kind ~a`)" (car kinds) (car kinds)) ""))))))

;; same-table-first : (listof n) string -> (listof n)   kinds whose first example reads the table
;; `sql` reads, before the others
(define (same-table-first kinds sql)
  (define table (main-table sql))
  (define (same? k)
    (define file (build-path "examples" (format "~a.md" k)))
    (and (file-exists? file)
         (let ([qs (example-queries (file->string file))]) (and (pair? qs) (equal? (main-table (car qs)) table)))))
  (define-values (same other) (partition same? kinds))
  (append same other))

;; done-line : string   what ends the output when the answer is written and no note was printed
(define done-line "done: the answer is written, and nothing above needs a second look.")

;; other-kinds : (listof string) -> (listof string)   the kinds a decisive note points to
;; (`./kind 25`), each once, in the order named
(define (other-kinds notes)
  (remove-duplicates
   (for*/list ([n (in-list notes)] #:when (hold? n) [m (in-list (regexp-match* #px"`\\./kind (\\d+)`" n #:match-select cadr))]) m)))

;; shown-note : string -> string   a note as it is printed: a decisive one reads as any other
(define (shown-note n) (if (hold? n) (string-append "note: " (substring n 6)) n))

;; held? : string (listof string) path -> boolean   the answer of this query is not written now:
;; a decisive note stands, and the query is not the one held back just before
(define (held? sql notes file)
  (and (ormap hold? notes)
       (not (and (file-exists? file) (equal? (file->string file) sql)))))

;; ---- the rows an answer rests on ------------------------------------------------------------------
;; all-rows : string -> string   a row query without its grouping: every row of each group. A
;; grouping that is then ordered or limited chooses among the groups, and is kept.
(define (all-rows q)
  (define m (regexp-match-positions #px"\\sGROUP BY\\s[^()]*(\\([^()]*\\)[^()]*)*$" q))
  (if (and m (not (regexp-match? #px"ORDER BY|LIMIT" (substring q (caar m)))))
      (substring q 0 (caar m))
      q))

;; ---- shapes ----------------------------------------------------------------------------------------
;; depth-0 : string -> (listof index)   the positions outside every parenthesis and quote
(define (depth-0? q)
  (define n (string-length q))
  (define v (make-vector n #f))
  (let loop ([i 0] [depth 0] [quoted? #f])
    (when (< i n)
      (define c (string-ref q i))
      (cond [quoted? (loop (add1 i) depth (not (char=? c #\')))]
            [(char=? c #\') (loop (add1 i) depth #t)]
            [(char=? c #\() (loop (add1 i) (add1 depth) #f)]
            [(char=? c #\)) (loop (add1 i) (max 0 (sub1 depth)) #f)]
            [else (vector-set! v i (zero? depth)) (loop (add1 i) depth #f)])))
  (lambda (i) (vector-ref v i)))

;; clause-start : string regexp -> index or #f   where a clause of the query itself begins
(define (clause-start q rx)
  (define top? (depth-0? q))
  (for/first ([m (in-list (regexp-match-positions* rx q))] #:when (top? (car m))) (car m)))

;; shape : string -> Shape   what a query selects and from where, and how it groups, orders and
;; limits — its conditions left out, its literals `?`, a sub-select it selects or reads from as
;; its own shape
(define (shape sql) (slots (shape* sql)))
(define (shape* sql)
  (define q (string-trim (regexp-replace #px";\\s*$" (regexp-replace* #px"\\s+" sql " ") "")))
  (define where (clause-start q #px"\\bWHERE\\b"))
  (define tail (clause-start q #px"\\b(GROUP BY|ORDER BY|LIMIT)\\b"))
  (define head (substring q 0 (or where tail (string-length q))))
  (define head* (for/fold ([h head]) ([s (in-list (remove-duplicates (append (sub-selects q) (from-selects head))))])
                  (string-replace h s (shape* s))))
  (define text (string-append (string-trim head*) (if tail (string-append " " (substring q tail)) "")))
  (string-downcase
   (regexp-replace* #px"\\s+" (regexp-replace* #px"\\b[0-9]+(\\.[0-9]+)?\\b" (regexp-replace* #px"'[^']*'" text "?") "?") " ")))

;; slots : string -> string   what a kind leaves open besides names and times, written one way: the
;; direction of an ordering ("first"/"last", "highest"/"lowest"), the aggregate ("average",
;; "maximum"), the comparison ("less than", "greater than"); and the spaces inside parentheses
(define (slots text)
  (for/fold ([t text]) ([r (in-list '((#px"\\b(asc|desc)\\b" "asc/desc") (#px"\\b(min|max|avg|sum)\\(" "agg(")
                                      (#px" (<=|>=|<|>) " " <> ") (#px"\\( " "(") (#px" \\)" ")")))])
    (regexp-replace* (car r) t (cadr r))))

;; from-selects : string -> (listof string)   the sub-selects a head reads from: `FROM ( SELECT … ) AS t`
(define (from-selects head)
  (define m (regexp-match-positions #px"\\bFROM\\s*\\(" head))
  (cond [(not m) '()]
        [else
         (define start (sub1 (cdar m)))
         (define end (let loop ([i start] [depth 0])
                       (cond [(= i (string-length head)) i]
                             [(char=? (string-ref head i) #\() (loop (add1 i) (add1 depth))]
                             [(char=? (string-ref head i) #\)) (if (= depth 1) i (loop (add1 i) (sub1 depth)))]
                             [else (loop (add1 i) depth)])))
         (list (string-trim (substring head (add1 start) end)))]))

;; example-queries : string -> (listof string)   the queries of an examples file (`SQL: …` lines)
(define (example-queries text)
  (for/list ([l (in-list (string-split text "\n"))] #:when (string-prefix? l "SQL: ")) (string-trim (substring l 5))))

;; shape-note : string (listof string) -> string or #f   said when a query has the shape of none
;; of its kind's examples
(define (shape-note sql examples)
  (define mine (shape sql))
  (define theirs (remove-duplicates (map shape examples)))
  (and (pair? theirs) (not (member mine theirs))
       (format "note: this kind's example~a\n  ~a\nand your query is\n  ~a\nIf the difference is not one the question asks for (a name, a number, a time), write it as the example does."
               (if (= (length theirs) 1) " is" "s are") (string-join theirs "\n  ") mine)))

;; empty-pick-note : string (listof (listof Cell)) -> string or #f   said when a query that picks
;; rows by an ordering (the first, the last) and selects a plain column picked rows with no value in
;; it. No query of the train or validation split answers so: a first or last value on record is one
;; that was recorded.
(define (empty-pick-note sql rows)
  (define q (string-trim (regexp-replace* #px"\\s+" sql " ")))
  (define m (regexp-match #px"^SELECT (?:DISTINCT )?([a-z_]+\\.[a-z_]+) FROM .* ORDER BY [^()]*LIMIT [0-9]+;?$" q))
  (and m (pair? rows) (andmap (lambda (r) (andmap (lambda (c) (eq? c 'null)) r)) rows)
       (format "note: the row this query picks has no value in `~a`. When the question asks for the first or the last one on record, a row without a value is not one: add `AND ~a IS NOT NULL` and run it again."
               (cadr m) (cadr m))))

;; ---- running ---------------------------------------------------------------------------------------
;; cells : run-result -> (values (listof symbol) (listof (listof Cell)))
(define (cells r)
  (define cols (map (lambda (c) (string->symbol (format "~a" c))) (run-result-columns r)))
  (values cols
          (for/list ([row (in-list (run-result-rows r))])
            (for/list ([c (in-list cols)]) (let ([v (hash-ref row c 'null)]) (if (or (string? v) (real? v)) v 'null))))))

(module+ main
  (define kind #f)
  (define said #f)
  (define out "answer.json")
  (define sql
    (command-line
     #:program "answer"
     #:once-each
     [("--kind") n "the kind of question (examples/<n>.md): the query's shape is set beside its examples'" (set! kind n)]
     [("--say") text "the answer to write, in place of the one read from the rows" (set! said text)]
     [("--out") f "the answer file (default answer.json)" (set! out f)]
     #:args (sql) sql))
  (define open-hub (dynamic-require 'fhir/mcp/workspace 'open-hub))
  (define execute (dynamic-require 'fhir/mcp/run 'execute))
  (define h (open-hub (current-directory)))
  (define (run q) (execute h "sql" #f q (hasheq)))
  (define-values (columns rows)
    (with-handlers ([exn:fail? (lambda (e) (eprintf "~a\n" (car (string-split (exn-message e) "\n"))) (exit 1))])
      (cells (run sql))))
  (printf "~a row~a (~a)\n" (length rows) (if (= (length rows) 1) "" "s")
          (string-join (for/list ([c (in-list columns)]) (let ([n (symbol->string c)]) (if (> (string-length n) 40) (string-append (substring n 0 40) "…") n))) ", "))
  (for ([r (in-list (take rows (min 40 (length rows))))]) (printf "  ~a\n" (string-join (map cell-text r) " | ")))
  (when (> (length rows) 40) (printf "  … ~a more\n" (- (length rows) 40)))
  ;; the resources: the rows of the main table, each row's id columns
  (define resources
    (with-handlers ([exn:fail? (lambda (e) (printf "resources: not found from this query (~a): select the fhir_id columns yourself\n" (car (string-split (exn-message e) "\n"))) '())])
      (remove-duplicates
       (append*
        (for/list ([q (in-list (map all-rows (row-queries sql)))])
          (define-values (cols rs) (cells (run q)))
          (define ids (id-columns cols))
          (for*/list ([r (in-list rs)] [c (in-list cols)] [v (in-value (list-ref r (index-of cols c)))]
                      #:when (and (memq c ids) (string? v))
                      [id (in-list (string-split v #px"[\\s,]+"))] #:when (regexp-match? #rx"/" id))
            id))))))
  (define answer (or said (answer-text sql rows (pair? resources))))
  (printf "answer: ~a\n" answer)
  (printf "resources: ~a~a\n" (length resources)
          (if (pair? resources) (format " (~a~a)" (string-join (take resources (min 3 (length resources))) ", ") (if (> (length resources) 3) ", …" "")) ""))
  ;; the notes: the query's shape beside its kind's examples, and what the train split's queries
  ;; say a query of this kind and of this question holds (query-checks.rkt)
  (define examples
    (let ([file (and kind (build-path "examples" (format "~a.md" kind)))])
      (cond [(not kind) '()]
            [(file-exists? file) (example-queries (file->string file))]
            [else (printf "note: there is no examples/~a.md\n" kind) '()])))
  (define question
    (if (file-exists? "question.json") (call-with-input-file "question.json" read-json) (hasheq)))
  ;; a comparison where the question asks whether is the question's own shape, whatever the kind's is
  (define asked-shape? (and (asks-whether (hash-ref question 'question "")) (comparison? sql)))
  (define own-notes (filter values (list (and (not asked-shape?) (shape-note sql examples)) (empty-pick-note sql rows))))
  (for ([note (in-list own-notes)]) (printf "~a\n" note))
  (define notes
    (cond
      [(and (file-exists? "question.json") (file-exists? (build-path "examples" "checks.json")))
       (define q question)
       (define checks (call-with-input-file (build-path "examples" "checks.json") read-json))
       ;; a column's distinct values, asked of the workspace when a check needs them
       (define (values-of column)
         (define parts (string-split column "."))
         (with-handlers ([exn:fail? (lambda (_) '())])
           (define-values (_cols rs) (cells (run (format "SELECT DISTINCT ~a FROM ~a" (cadr parts) (car parts)))))
           (filter string? (map car rs))))
       (append (query-notes sql kind checks (hash-ref q 'question "") (hash-ref q 'assumption "") examples values-of)
               (let ([tie (tie-note sql (lambda (query) (let-values ([(_cols rs) (cells (run query))]) rs))
                                    (same-table-first (hash-ref checks 'ties '()) sql))])
                 (if tie (list tie) '())))]
      [else '()]))
  (for ([n (in-list notes)]) (printf "~a\n" (shown-note n)))
  ;; a decisive note holds the answer back once: the same query given again is written
  (cond
    [(held? sql notes held-file)
     (call-with-output-file held-file #:exists 'truncate (lambda (o) (write-string sql o)))
     (printf "NOT written to ~a: ~a says this query does not answer the question as it is asked. Correct the query and run it again. (If the note is mistaken, run this same command once more and it is written.)\n"
             out (if (= 1 (count hold? notes)) "the last note" "a note above"))
     ;; the kind the note points to, shown here: the query to copy is one command away, not two
     (for ([k (in-list (other-kinds notes))])
       (define file (build-path "examples" (format "~a.md" k)))
       (when (file-exists? file)
         (printf "\nKind ~a, which the note names (run it as `./answer --kind ~a …`):\n~a\n" k k (string-trim (file->string file)))))]
    [else
     (when (file-exists? held-file) (delete-file held-file))
     (call-with-output-file out #:exists 'truncate
       (lambda (o) (write-json (hasheq 'answer answer 'resources resources) o)))
     (printf "written to ~a\n" out)
     (when (and (null? own-notes) (null? notes)) (printf "~a\n" done-line))]))

(module+ test
  (require rackunit)
  ;; a tie at the first or last row
  (check-equal? (tied-values '(("GRAM STAIN" "2110-01-02 03:00:00") ("RESPIRATORY CULTURE" "2110-01-02 03:00:00") ("URINE CULTURE" "2110-01-01 00:00:00")))
                '("GRAM STAIN" "RESPIRATORY CULTURE"))
  (check-equal? (tied-values '(("a" 2) ("a" 2) ("b" 1))) '() "the tied rows say the same")
  (check-equal? (tied-values '(("a" 2) ("b" 1))) '())
  (check-equal? (tied-values '()) '())
  (let ([sql "SELECT m.test_name FROM m WHERE m.hadm_id IN ( SELECT 1 ) ORDER BY m.charttime DESC LIMIT 1"])
    (define note (tie-note sql (lambda (q) '(("GRAM STAIN" "2110-01-02 03:00:00") ("RESPIRATORY CULTURE" "2110-01-02 03:00:00"))) '(15 24)))
    (check-true (hold? note))
    (check-regexp-match #rx"2 rows share the last `m.charttime` \\(2110-01-02 03:00:00\\) and differ in `m.test_name`: GRAM STAIN, RESPIRATORY CULTURE" note)
    (check-equal? (other-kinds (list note)) '("15"))
    (check-false (tie-note sql (lambda (q) '(("GRAM STAIN" "2110-01-02 03:00:00"))) '(15)))
    (check-false (tie-note "SELECT COUNT(*) FROM m" (lambda (q) (error "not asked")) '(15))))
  ;; the kinds a decisive note names
  (check-equal? (other-kinds (list "hold: … the kinds whose questions do: 25, 38 (`./kind 25`). If yours is one of those, copy its example instead."
                                   "note: … (`./kind 7`)" "hold: again (`./kind 25`)"))
                '("25"))
  (check-regexp-match #rx"^done: the answer is written" done-line)
  ;; the answer
  (check-equal? (answer-text "SELECT chartevents.valuenum FROM chartevents WHERE x = 1" '((61.7)) #t) "61.7")
  (check-equal? (answer-text "SELECT labevents.valuenum FROM labevents" '((83.6) (84.2)) #t) "83.6, 84.2")
  (check-equal? (answer-text "SELECT COUNT(*)>0 FROM prescriptions WHERE drug IN ( 'a', 'b' )" '((1)) #t) "yes")
  (check-equal? (answer-text "SELECT COUNT(*)>0 FROM prescriptions WHERE drug = 'a'" '((0)) #f) "no: none on record")
  (check-equal? (answer-text "SELECT ( SELECT a FROM t WHERE x = 1 ) < ( SELECT a FROM t WHERE x = 2 )" '((0)) #t) "no")
  (check-equal? (answer-text "SELECT ( SELECT a FROM t ) - ( SELECT a FROM t )" '((null)) #f) "none: nothing on record")
  (check-equal? (answer-text "SELECT ( SELECT a FROM t ) - ( SELECT a FROM t )" '((-1.0)) #t) "-1")
  (check-equal? (answer-text "SELECT COUNT(*) FROM icustays WHERE x = 1" '((0)) #f) "none: nothing on record")
  (check-equal? (answer-text "SELECT COUNT(*) FROM icustays WHERE x = 1" '((2)) #t) "2")
  (check-equal? (answer-text "SELECT t.a FROM t" '() #f) "none: nothing on record")
  (check-equal? (answer-text "SELECT t.a, t.b FROM t" '(("x" 2) ("y" null)) #t) "x | 2, y")
  (check-equal? (answer-text "SELECT admissions.admission_type FROM admissions WHERE s = 1" '(("EW EMER.")) #t) "EW EMER.")
  (check-false (comparison? "SELECT strftime('%Y', t.c) FROM t WHERE t.a = 1") "a comparison in WHERE is not one in the select list")
  ;; every row of a group
  (check-equal? (all-rows "SELECT t.* FROM t WHERE t.a IN ( SELECT b FROM u ) GROUP BY strftime('%Y-%m',t.c)") "SELECT t.* FROM t WHERE t.a IN ( SELECT b FROM u )")
  (check-equal? (all-rows "SELECT t.* FROM t GROUP BY t.d ORDER BY COUNT(*) DESC LIMIT 3") "SELECT t.* FROM t GROUP BY t.d ORDER BY COUNT(*) DESC LIMIT 3")
  (check-equal? (all-rows "SELECT t.* FROM t WHERE t.a IN ( SELECT b FROM u GROUP BY b ) ORDER BY t.c") "SELECT t.* FROM t WHERE t.a IN ( SELECT b FROM u GROUP BY b ) ORDER BY t.c")
  ;; shapes
  (check-equal? (shape "SELECT AVG(chartevents.valuenum) FROM chartevents WHERE chartevents.stay_id IN ( SELECT icustays.stay_id FROM icustays WHERE icustays.hadm_id = 5 ORDER BY icustays.intime LIMIT 1 ) AND chartevents.charttime >= '2100-01' GROUP BY strftime('%Y-%m',chartevents.charttime);")
                "select agg(chartevents.valuenum) from chartevents group by strftime(?,chartevents.charttime)")
  (check-equal? (shape "SELECT labevents.valuenum FROM labevents WHERE labevents.itemid IN ( SELECT 1 ) ORDER BY labevents.charttime DESC LIMIT 1")
                "select labevents.valuenum from labevents order by labevents.charttime asc/desc limit ?")
  (check-equal? (shape "SELECT ( SELECT t.v FROM t WHERE t.a = 1 ORDER BY t.c DESC LIMIT 1 ) - ( SELECT t.v FROM t WHERE t.a = 1 ORDER BY t.c ASC LIMIT 1 )")
                "select (select t.v from t order by t.c asc/desc limit ?) - (select t.v from t order by t.c asc/desc limit ?)")
  (check-equal? (shape "SELECT T1.drug FROM ( SELECT p.drug, COUNT(*) AS c FROM p WHERE p.x = 2 GROUP BY p.drug ) AS T1 WHERE T1.c >= 2")
                "select t1.drug from (select p.drug, count(*) as c from p group by p.drug) as t1")
  (check-equal? (example-queries "Kind: k\n\nQ: one?\nAssume: (nothing)\nSQL: SELECT 1\n\nQ: two?\nSQL: SELECT 2\n") '("SELECT 1" "SELECT 2"))
  (check-false (shape-note "SELECT MAX(t.v) FROM t WHERE t.a = 7 AND t.c >= '2100'" '("SELECT MIN(t.v) FROM t WHERE t.a = 1")) "a name, a time, another aggregate: the kind's slots")
  (check-false (shape-note "SELECT (SELECT t.v FROM t ORDER BY t.c DESC LIMIT 1) > (SELECT t.v FROM t LIMIT 1)" '("SELECT ( SELECT t.v FROM t ORDER BY t.c ASC LIMIT 1 ) < ( SELECT t.v FROM t LIMIT 1 )")))
  (check-regexp-match #rx"group by" (shape-note "SELECT AVG(t.v) FROM t WHERE t.a = 7" '("SELECT AVG(t.v) FROM t WHERE t.a = 1 GROUP BY strftime('%Y',t.c)")))
  (check-false (shape-note "SELECT 1" '()) "no example, no note")
  ;; a picked row with no value
  (define pick "SELECT transfers.careunit FROM transfers WHERE transfers.hadm_id IN ( SELECT 1 ) ORDER BY transfers.intime DESC LIMIT 1")
  (check-regexp-match #rx"AND transfers.careunit IS NOT NULL" (empty-pick-note pick '((null))))
  (check-false (empty-pick-note pick '(("Transplant"))))
  (check-false (empty-pick-note pick '()) "no row: nothing on record")
  (check-false (empty-pick-note "SELECT MAX(t.v) FROM t WHERE t.a = 1" '((null))) "an aggregate over nothing")
  (check-false (empty-pick-note "SELECT t.v FROM t WHERE t.a = 1" '((null))) "no ordering picks the row")
  ;; held back
  (define f (make-temporary-file "held~a"))
  (delete-file f)
  (check-false (held? "SELECT 1" '("note: a") f))
  (check-true (held? "SELECT 1" '("note: a" "hold: b") f))
  (void (call-with-output-file f (lambda (o) (write-string "SELECT 1" o))))
  (check-false (held? "SELECT 1" '("hold: b") f) "the same query a second time is written")
  (check-true (held? "SELECT 2" '("hold: b") f) "another query is held in its turn")
  (delete-file f)
  (check-equal? (shown-note "hold: the question") "note: the question")
  (check-equal? (shown-note "note: x") "note: x"))
