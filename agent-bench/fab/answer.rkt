#lang racket/base

;;; answer.rkt — a question's query asked of a workspace's tables, and what follows from it written
;;; down: the answer, the resources it rests on, and how the query's shape differs from its kind's.
;;;
;;;   racket -l- fhir-examples/agent-bench/fab/answer [--kind N] [--out answer.json] "<SQL>"
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
;;;   5. writes {"answer", "resources"} to --out (answer.json).
;;; The agent reads the rows and the notes, and writes the file itself only when it disagrees.
;;;
;;; A Shape is a string: a query with its WHERE conditions left out and its literals as `?`.

(require racket/cmdline racket/file racket/list racket/string json
         (only-in fhir/lang/workspace run-result-columns run-result-rows)
         (only-in "check-ids.rkt" row-queries id-columns sub-selects))

(provide answer-text shape example-queries shape-note all-rows)

;; ---- the answer ---------------------------------------------------------------------------------
;; comparison? : string -> boolean   a query whose select list is a comparison: its 1/0 is yes/no
(define (comparison? sql)
  (define q (regexp-replace* #px"\\s+" sql " "))
  (define outer (regexp-replace* #px"\\([^()]*\\)" (regexp-replace* #px"\\([^()]*\\)" (regexp-replace* #px"\\([^()]*\\)" (regexp-replace* #px"\\([^()]*\\)" q "G") "G") "G") "G"))
  (define select-list (car (string-split (string-append outer " ") " FROM ")))
  (regexp-match? #px"^SELECT .*(>|<|=)" select-list))

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

;; ---- running ---------------------------------------------------------------------------------------
;; cells : run-result -> (values (listof symbol) (listof (listof Cell)))
(define (cells r)
  (define cols (map (lambda (c) (string->symbol (format "~a" c))) (run-result-columns r)))
  (values cols
          (for/list ([row (in-list (run-result-rows r))])
            (for/list ([c (in-list cols)]) (let ([v (hash-ref row c 'null)]) (if (or (string? v) (real? v)) v 'null))))))

(module+ main
  (define kind #f)
  (define out "answer.json")
  (define sql
    (command-line
     #:program "answer"
     #:once-each
     [("--kind") n "the kind of question (examples/<n>.md): the query's shape is set beside its examples'" (set! kind n)]
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
  (define answer (answer-text sql rows (pair? resources)))
  (printf "answer: ~a\n" answer)
  (printf "resources: ~a~a\n" (length resources)
          (if (pair? resources) (format " (~a~a)" (string-join (take resources (min 3 (length resources))) ", ") (if (> (length resources) 3) ", …" "")) ""))
  (when kind
    (define file (build-path "examples" (format "~a.md" kind)))
    (cond [(file-exists? file)
           (define note (shape-note sql (example-queries (file->string file))))
           (when note (printf "~a\n" note))]
          [else (printf "note: there is no examples/~a.md\n" kind)]))
  (call-with-output-file out #:exists 'truncate
    (lambda (o) (write-json (hasheq 'answer answer 'resources resources) o)))
  (printf "written to ~a\n" out))

(module+ test
  (require rackunit)
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
  (check-false (shape-note "SELECT 1" '()) "no example, no note"))
