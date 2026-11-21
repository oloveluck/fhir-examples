#lang racket/base

;;; tables-server.rkt — the tables arm's three commands as the tools of one process.
;;;
;;;   racket -l- fhir-examples/agent-bench/fab/tables-server [DIR]
;;;
;;; A Model Context Protocol server on stdin/stdout (one JSON object a line) over the question's
;;; workspace DIR (the current directory when none is given). Its tools are the commands of the
;;; `tables` arm, each answering the text the command prints:
;;;
;;;   kind    {numbers [names] [every_phrase]}  `./kind N …`: the examples of those kinds; how the
;;;                               tables write each of `names` (the names the question gives, looked
;;;                               up in the columns the train split's queries compare with one); the
;;;                               time phrases the question says (all of them with `every_phrase`);
;;;                               and — the first time — the schema and what to do next
;;;                               (examples/next.md, when the run wrote one)
;;;   sql     {text}              `raco fhir-mcp call query language=sql text=…`: the rows, as JSON
;;;   answer  {kind, sql [say]}   `./answer --kind N [--say TEXT] "SQL"`: rows, answer, resources,
;;;                               notes; the answer file written (answer.rkt's `answer!`)
;;;
;;; Why a server where a shell would do. Measured on the shell form (results/2026-11-17-held-out-
;;; and-efficiency.md): every call of the model carries the shell tool's definition (1.8k tokens)
;;; whether or not a question needs a shell, and each command starts a process that loads the
;;; toolkit and opens the workspace (1.2 to 1.4 s) before it reads one row. Here the three
;;; definitions are a few hundred tokens and the workspace is opened once, while the model is
;;; reading the question.
;;;
;;; What a call of the model carries, it carries again in every later call. So the tools say what
;;; is needed when it is needed: the conditions of the two or so time phrases the question's words
;;; hold (query-checks.rkt `said-times`: every phrase of every validation question is among them)
;;; where `./kind` printed all 31, and the schema and the instructions for writing and submitting
;;; the query with the example they are about, once, where the prompt held them from the first
;;; call. The first call picks a kind and gives the question's names, which needs neither: `kind`
;;; looks the names up (the agent asked the tables itself, which is what it needed the schema for).
;;;
;;; The protocol is the little of MCP a tool server needs (../tool-server.rkt).

(require racket/file racket/list racket/port racket/promise racket/string json
         "../tool-server.rkt"
         (only-in "answer.rkt" answer! cells)
         (only-in "query-checks.rkt" said-times))

(provide handle tool tables-tools kind-text phrases-text names-text tool-wording)

;; A Workspace is (workspace run query): what the tools ask of the opened workspace —
;;   run   : string -> run-result          a statement's rows (answer.rkt reads them)
;;   query : string -> (values string boolean)   a statement as the `query` verb answers it
(struct workspace (run query))

;; ---- what each tool says --------------------------------------------------------------------------
;; json-file : path -> jsexpr | #f
(define (json-file f) (and (file-exists? f) (with-handlers ([exn:fail? (lambda (_) #f)]) (call-with-input-file f read-json))))

;; phrases-text : dir boolean -> string   how the time phrases are written in a query: those the
;; question's words hold (question.json, read by checks.json's `times`; phrases.json has each
;; kind's line), or all of them — when asked, or when the workspace cannot say which
(define (phrases-text dir all?)
  (define head "How a time phrase is written in such a query (with your column and your current time in place of the ones shown):\n")
  (define lines (json-file (build-path dir "examples" "phrases.json")))
  (define times (let ([c (json-file (build-path dir "examples" "checks.json"))]) (and (hash? c) (hash-ref c 'times #f))))
  (define question (let ([q (json-file (build-path dir "question.json"))]) (and (hash? q) (hash-ref q 'question #f))))
  (cond
    [(or all? (not (and (list? lines) (list? times) (string? question))))
     (define phrases (build-path dir "examples" "phrases.md"))
     (string-append head (if (file-exists? phrases) (file->string phrases) "") "\n")]
    [else
     (define said (said-times question times))
     (define mine (for/list ([l (in-list lines)] #:when (member (hash-ref l 'type #f) said)) (hash-ref l 'line "")))
     (define others (format "the ~a kinds of time phrase these queries know: `kind` with `every_phrase: true` lists how each is written" (length lines)))
     (if (null? mine)
         (format "Your question's words hold none of ~a.\n" others)
         (string-append "How the time phrases of your question are written in such a query (with your column and your current time in place of the ones shown):\n"
                        (string-join mine "\n")
                        (format "\n(If your question has a time phrase that is none of these, they are ~a of ~a.)\n" (length mine) others)))]))

;; kind-text : dir (listof integer) [all-phrases? first? names] -> string   the examples of those
;; kinds, then `names` (how the tables write the names given: `names-text`), how a time phrase is
;; written (run.rkt's `./kind` script prints these, with every phrase), and, the first time, what
;; to do next (examples/next.md)
(define (kind-text dir numbers [all? #t] [first? #f] [names ""])
  (define (example n)
    (define file (build-path dir "examples" (format "~a.md" n)))
    (if (file-exists? file) (string-append (file->string file) "\n") (format "there is no kind ~a\n" n)))
  (define next (build-path dir "examples" "next.md"))
  (string-append
   (string-append* (map example numbers))
   (if (equal? names "") "" (string-append names "\n"))
   (phrases-text dir all?)
   (if (and first? (file-exists? next)) (string-append "\n" (file->string next) "\n") "")))

;; ---- names -----------------------------------------------------------------------------------------
;; A question gives a name in lower case inside its sentence; the tables have it as the hospital
;; writes it. The columns that hold names are those the train split's queries compare with one
;; (checks.json's `names`, query-checks.rkt `name-columns`), and beside some of them every such
;; query states another column of the row (`beside`, `name-companions`: an item's `linksto`, the
;; table its records are in), which is said with the name: two things may share one.
;;
;; A Row is (list column value beside), of `near-statement` (list column value beside how):
;; `beside` the conditions that go with the value, as SQL (" AND d_items.linksto = 'outputevents'").

;; quoted : string -> string   an SQL string literal
(define (quoted s) (string-append "'" (string-replace s "'" "''") "'"))

;; folded : string -> string   a name with case and surrounding spaces aside
(define (folded s) (string-downcase (string-trim s)))

;; beside-sql : column (listof column) -> string   an SQL expression: the text of the conditions
;; on the row's companion columns, "" when there are none
(define (beside-sql column companions)
  (define table (car (string-split column ".")))
  (define mine (filter (lambda (o) (equal? (car (string-split o ".")) table)) companions))
  (if (null? mine)
      "''"
      (string-join
       (for/list ([o (in-list mine)])
         (format "' AND ~a = ''' || replace(coalesce(~a, ''), '''', '''''') || ''''" o (cadr (string-split o "."))))
       " || ")))

;; companions-of : (hash symbol -> (listof column)) column -> (listof column)
(define (companions-of beside column)
  (let ([v (hash-ref beside (string->symbol column) '())]) (if (list? v) (filter string? v) '())))

;; exact-statement : (listof column) (listof name) [beside] -> string   each column's values that
;; are one of the names, case and surrounding spaces aside
(define (exact-statement columns names [beside (hasheq)])
  (string-join
   (for/list ([c (in-list columns)])
     (define parts (string-split c "."))
     (format "SELECT DISTINCT '~a' AS col, ~a AS name, ~a AS beside FROM ~a WHERE lower(trim(~a)) IN (~a)"
             c (cadr parts) (beside-sql c (companions-of beside c)) (car parts) (cadr parts) (string-join (map quoted names) ", ")))
   " UNION ALL "))

;; near-statement : (listof column) name [beside] -> string   for a name no column holds exactly:
;; each column's values that hold it (`how` 1), and those it holds as whole words (`how` 2: "nu
;; route" holds the route `NU`), six of each a column
(define (near-statement columns name [beside (hasheq)])
  (define pattern (quoted (string-append "%" (regexp-replace* #px"[%_\\\\]" name "\\\\&") "%")))
  (define padded (quoted (string-append " " name " ")))
  (string-join
   (for/list ([c (in-list columns)])
     (define parts (string-split c "."))
     (define-values (table col) (values (car parts) (cadr parts)))
     (define with (beside-sql c (companions-of beside c)))
     (string-append
      (format "SELECT * FROM (SELECT DISTINCT '~a' AS col, ~a AS name, ~a AS beside, 1 AS how FROM ~a WHERE lower(~a) LIKE ~a ESCAPE '\\' LIMIT 6)"
              c col with table col pattern)
      " UNION ALL "
      (format "SELECT * FROM (SELECT DISTINCT '~a' AS col, ~a AS name, ~a AS beside, 2 AS how FROM ~a WHERE length(trim(~a)) > 1 AND instr(~a, ' ' || lower(trim(~a)) || ' ') > 0 LIMIT 6)"
              c col with table col padded col)))
   " UNION ALL "))

;; grouped : (listof column) (listof Row) -> (listof (list column beside (listof value)))   the
;; rows by column (in the columns' order) and by what goes with the value
(define (grouped columns rows)
  (for*/list ([c (in-list columns)]
              [mine (in-value (filter (lambda (r) (equal? (car r) c)) rows))]
              [b (in-list (remove-duplicates (map caddr mine)))])
    (list c b (remove-duplicates (for/list ([r (in-list mine)] #:when (equal? (caddr r) b)) (cadr r))))))

;; names-text : (string -> (listof Row)) (listof column) (listof string) [beside] -> string
;; how the tables write each name given: the columns that hold it exactly (every spelling, and
;; what every query says beside it), else the values that hold it or that it holds, else that
;; nothing does. `rows-of` answers a statement's rows.
(define (names-text rows-of columns given [beside (hasheq)])
  (define names (remove-duplicates (filter non-empty-string? (map folded given))))
  (cond
    [(or (null? names) (null? columns)) ""]
    [else
     (define exact (rows-of (exact-statement columns names beside)))
     (define (line name)
       (define mine (grouped columns (filter (lambda (r) (equal? (folded (cadr r)) name)) exact)))
       (cond
         [(pair? mine)
          (format "  \"~a\": ~a" name
                  (string-join (for/list ([m (in-list mine)])
                                 (define values (caddr m))
                                 (if (= (length values) 1)
                                     (format "`~a = ~a~a`" (car m) (quoted (car values)) (cadr m))
                                     (format "`~a IN (~a)~a`" (car m) (string-join (map quoted values) ", ") (cadr m))))
                               ", or "))]
         [else
          (define near (rows-of (near-statement columns name beside)))
          (define (shown m)
            (define with (regexp-replace #rx"^ AND " (cadr m) ""))
            (format "`~a` ~a~a" (car m) (string-join (map quoted (caddr m)) ", ") (if (equal? with "") "" (format " (~a)" with))))
          (define (listed how)
            (define found (grouped columns (for/list ([r (in-list near)] #:when (equal? (cadddr r) how)) r)))
            (and (pair? found) (string-join (map shown found) "; ")))
          (define-values (holding held) (values (listed 1) (listed 2)))
          (if (or holding held)
              (format "  \"~a\": no column holds it exactly.~a~a If one is what the question means, name it exactly; else look further with `sql`."
                      name
                      (if holding (format " Names that hold it: ~a." holding) "")
                      (if held (format " Names it holds: ~a." held) ""))
              (format "  \"~a\": no name in the tables is it, holds it or is held by it (~a). Give the name as the question words it, or look further with `sql`."
                      name (string-join columns ", ")))]))
     (string-append "The names you gave, as the tables write them (name each exactly so, with every spelling and condition shown; a kind whose example reads another table is not the name's kind):\n"
                    (string-join (map line names) "\n") "\n")]))

;; tool-wording : string -> string   answer.rkt's text, which names its shell commands, in the
;; words of a caller that has tools: `./kind 25` is the kind tool, "this same command" a call
(define (tool-wording text)
  (for/fold ([s text])
            ([rule (in-list '((#px"`\\./kind (\\d+)`" "the `kind` tool: \\1")
                              (#px"run it as `\\./answer --kind (\\d+) …`" "give `answer` its number as `kind`")
                              (#px"run this same command once more" "call `answer` once more with the same query")))])
    (regexp-replace* (car rule) s (cadr rule))))

;; integers : jsexpr -> (listof integer)   a tool's numbers argument: a list of them, or one
(define (integers v)
  (define (whole x) (cond [(exact-integer? x) x]
                          [(and (real? x) (integer? x)) (inexact->exact x)]
                          [(and (string? x) (string->number (string-trim x))) => whole]
                          [else (raise-user-error (format "`~a` is not a kind's number" x))]))
  (map whole (if (list? v) v (list v))))

;; need : arguments symbol -> string
(define (need args key)
  (define v (hash-ref args key #f))
  (unless (and (string? v) (non-empty-string? (string-trim v))) (raise-user-error (format "`~a` is required" key)))
  v)

;; tables-tools : dir (promise Workspace) -> (listof Tool)
(define (tables-tools dir opened)
  (define text (hasheq 'type "string"))
  (define asked-before? (box #f))   ; what to do next is said with the first example, once
  (list
   (tool "kind"
         "How a kind of question is answered: for each number, a question or two of that kind, what each assumes and the query that answers it; then how the tables write each of `names`, and how the time phrases of your question are written in such a query."
         (hasheq 'type "object" 'required '("numbers")
                 'properties (hasheq 'numbers (hasheq 'type "array" 'items (hasheq 'type "integer"))
                                     'names (hasheq 'type "array" 'items text
                                                    'description "Each name your question gives (a lab test, a drug, an output, a care unit, a specimen, a procedure), as the question words it.")
                                     'every_phrase (hasheq 'type "boolean" 'description "Leave out. True only after a time phrase of your question was not among those shown.")))
         (lambda (args)
           (define numbers (integers (hash-ref args 'numbers '())))
           (define given (let ([v (hash-ref args 'names '())]) (filter string? (if (list? v) v (list v)))))
           (define checks (let ([c (json-file (build-path dir "examples" "checks.json"))]) (if (hash? c) c (hasheq))))
           (define columns (filter string? (hash-ref checks 'names '())))
           (define beside (let ([b (hash-ref checks 'beside (hasheq))]) (if (hash? b) b (hasheq))))
           (define names
             (cond [(null? given) ""]
                   [(null? columns) "The names are not looked up here: look each up with `sql`.\n"]
                   [else (names-text (lambda (statement)
                                       (define-values (_cols rows) (cells ((workspace-run (force opened)) statement)))
                                       (for/list ([r (in-list rows)] #:when (and (string? (car r)) (string? (cadr r))))
                                         (list* (car r) (cadr r) (if (string? (caddr r)) (caddr r) "") (cdddr r))))
                                     columns given beside)]))
           (define first? (not (unbox asked-before?)))
           (set-box! asked-before? #t)
           (kind-text dir numbers (eq? (hash-ref args 'every_phrase #f) #t) first? names)))
   (tool "sql"
         "One SQLite statement over the tables; its rows come back as JSON. For looking further when `kind` did not find a name."
         (hasheq 'type "object" 'required '("text") 'properties (hasheq 'text text))
         (lambda (args)
           (define-values (answered error?) ((workspace-query (force opened)) (need args 'text)))
           (if error? (raise-user-error answered) answered)))
   (tool "answer"
         "The query that answers the question: runs it, prints its rows, states the answer, finds the resources behind it, and writes the answer file. `kind` is the number of the example the query was copied from. `say` only when the answer it stated is not what the rows say: the same query again, with the answer said."
         (hasheq 'type "object" 'required '("kind" "sql")
                 'properties (hasheq 'kind (hasheq 'type "integer") 'sql text 'say text))
         (lambda (args)
           (define kind (number->string (car (integers (hash-ref args 'kind (lambda () (raise-user-error "`kind` is required")))))))
           (define said (let ([s (hash-ref args 'say #f)]) (and (string? s) (non-empty-string? (string-trim s)) s)))
           (define sql (need args 'sql))
           (define run (workspace-run (force opened)))
           (tool-wording
            (parameterize ([current-directory dir])
              (with-output-to-string (lambda () (answer! run sql kind said "answer.json")))))))))

;; open-workspace : dir -> Workspace   the toolkit loaded and the workspace opened (most of a second)
(define (open-workspace dir)
  (define open-hub (dynamic-require 'fhir/mcp/workspace 'open-hub))
  (define with-hub (dynamic-require 'fhir/mcp/workspace 'with-hub))
  (define execute (dynamic-require 'fhir/mcp/run 'execute))
  (define workspace-tools (dynamic-require 'fhir/mcp/verbs 'workspace-tools))
  (define tool-name (dynamic-require 'fhir/mcp/tools 'tool-name))
  (define call-tool (dynamic-require 'fhir/mcp/tools 'call-tool))
  (define h (parameterize ([current-directory dir]) (open-hub dir)))
  (define query (findf (lambda (t) (equal? (tool-name t) "query")) (workspace-tools h)))
  (workspace (lambda (sql) (parameterize ([current-directory dir]) (execute h "sql" #f sql (hasheq))))
             (lambda (sql) (parameterize ([current-directory dir])
                             (with-hub h (lambda () (call-tool query (hasheq 'language "sql" 'text sql))))))))

(module+ main
  (define dir (path->complete-path (let ([args (current-command-line-arguments)])
                                     (if (zero? (vector-length args)) (current-directory) (vector-ref args 0)))))
  ;; opened while the client is still starting and the model reading: the first call waits for it
  (define opened (delay/thread (open-workspace dir)))
  (serve-tools (tables-tools dir opened)))

(module+ test
  (require rackunit)
  ;; the wording: each text answer.rkt and query-checks.rkt write about a shell command
  (check-equal? (tool-wording "the kinds whose questions do: 25, 38 (`./kind 25`). If yours is one of those")
                "the kinds whose questions do: 25, 38 (the `kind` tool: 25). If yours is one of those")
  (check-equal? (tool-wording "Kind 15, which the note names (run it as `./answer --kind 15 …`):")
                "Kind 15, which the note names (give `answer` its number as `kind`):")
  (check-equal? (tool-wording "(If the note is mistaken, run this same command once more and it is written.)")
                "(If the note is mistaken, call `answer` once more with the same query and it is written.)")
  (check-equal? (tool-wording "3 rows (a)\n  1\nanswer: 1\n") "3 rows (a)\n  1\nanswer: 1\n")
  (check-equal? (integers '(3 "15" 7.0)) '(3 15 7))
  (check-equal? (integers 4) '(4))
  (check-exn #rx"not a kind's number" (lambda () (integers '("first"))))
  ;; a workspace of two examples and a table that answers one row
  (define dir (make-temporary-file "tables-server-~a" 'directory))
  (make-directory* (build-path dir "examples"))
  (display-to-file "Kind: K three\n\nQ: q\nAssume: (nothing)\nSQL: SELECT t.v FROM t\n" (build-path dir "examples" "3.md"))
  (display-to-file "- \"today\": `AND x`" (build-path dir "examples" "phrases.md"))
  (check-equal? (kind-text dir '(3 9))
                (string-append "Kind: K three\n\nQ: q\nAssume: (nothing)\nSQL: SELECT t.v FROM t\n\n"
                               "there is no kind 9\n"
                               "How a time phrase is written in such a query (with your column and your current time in place of the ones shown):\n"
                               "- \"today\": `AND x`\n"))
  ;; the phrases a question says: with the question, the phrases by kind and the forms of each kind
  (define (write-json-file v . path) (call-with-output-file (apply build-path dir path) #:exists 'truncate (lambda (o) (write-json v o))))
  (write-json-file (list (hasheq 'type "day" 'line "- \"today\": `AND x`") (hasheq 'type "year" 'line "- \"in 2142\": `AND y`")
                         (hasheq 'type "first" 'line "- \"first\": `ORDER BY t ASC LIMIT 1`"))
                   "examples" "phrases.json")
  (write-json-file (hasheq 'times (list (hasheq 'type "day" 'forms '("\\btoday\\b")) (hasheq 'type "year" 'forms '("\\bin [0-9]+\\b"))
                                        (hasheq 'type "first" 'forms '("\\bfirst\\b"))))
                   "examples" "checks.json")
  (write-json-file (hasheq 'question "What was the first weight of patient 1 in 2150?") "question.json")
  (check-equal? (phrases-text dir #f)
                (string-append "How the time phrases of your question are written in such a query (with your column and your current time in place of the ones shown):\n"
                               "- \"in 2142\": `AND y`\n- \"first\": `ORDER BY t ASC LIMIT 1`\n"
                               "(If your question has a time phrase that is none of these, they are 2 of the 3 kinds of time phrase these queries know: `kind` with `every_phrase: true` lists how each is written.)\n"))
  (check-regexp-match #rx"\"today\": `AND x`\n$" (phrases-text dir #t))
  (write-json-file (hasheq 'question "What is the gender of patient 1?") "question.json")
  (check-equal? (phrases-text dir #f)
                "Your question's words hold none of the 3 kinds of time phrase these queries know: `kind` with `every_phrase: true` lists how each is written.\n")
  ;; the names: each as the tables write it, every spelling, by the column that holds it and with
  ;; what goes beside it
  (let* ([asked '()]
         [table '(("p.drug" "Amlodipine" "") ("p.drug" "amLODIPine" "") ("d.label" "OR Urine" " AND d.linksto = 'outputevents'")
                  ("d.label" "Cerebral Ventricular #1" " AND d.linksto = 'outputevents'") ("m.spec" "URINE" "")
                  ("d.label" "Urine" " AND d.linksto = 'chartevents'") ("d.label" "Urine" " AND d.linksto = 'outputevents'"))]
         [rows-of (lambda (statement)
                    (set! asked (cons statement asked))
                    (cond [(regexp-match? #rx"LIKE" statement)
                           (define name (cadr (regexp-match #rx"LIKE '%([^%]*)%'" statement)))
                           (append (for/list ([r (in-list table)] #:when (string-contains? (string-downcase (cadr r)) name)) (append r '(1)))
                                   (for/list ([r (in-list table)] #:when (string-contains? (string-append " " name " ") (string-append " " (string-downcase (cadr r)) " ")))
                                     (append r '(2))))]
                          [else (filter (lambda (r) (member (string-append "'" (folded (cadr r)) "'") (regexp-match* #rx"'[^']*'" statement))) table)]))]
         [columns '("p.drug" "d.label" "m.spec")])
    (check-equal? (names-text rows-of columns '("amlodipine" " OR urine " "urine" "cerebral ventric" "or urine output" "no such thing" ""))
                  (string-append
                   "The names you gave, as the tables write them (name each exactly so, with every spelling and condition shown; a kind whose example reads another table is not the name's kind):\n"
                   "  \"amlodipine\": `p.drug IN ('Amlodipine', 'amLODIPine')`\n"
                   "  \"or urine\": `d.label = 'OR Urine' AND d.linksto = 'outputevents'`\n"
                   "  \"urine\": `d.label = 'Urine' AND d.linksto = 'chartevents'`, or `d.label = 'Urine' AND d.linksto = 'outputevents'`, or `m.spec = 'URINE'`\n"
                   "  \"cerebral ventric\": no column holds it exactly. Names that hold it: `d.label` 'Cerebral Ventricular #1' (d.linksto = 'outputevents'). If one is what the question means, name it exactly; else look further with `sql`.\n"
                   "  \"or urine output\": no column holds it exactly. Names it holds: `d.label` 'OR Urine', 'Urine' (d.linksto = 'outputevents'); `d.label` 'Urine' (d.linksto = 'chartevents'); `m.spec` 'URINE'. If one is what the question means, name it exactly; else look further with `sql`.\n"
                   "  \"no such thing\": no name in the tables is it, holds it or is held by it (p.drug, d.label, m.spec). Give the name as the question words it, or look further with `sql`.\n"))
    (check-equal? (length asked) 4 "one statement for the names, one more for each not found")
    (check-equal? (names-text rows-of columns '()) "")
    (check-equal? (names-text rows-of '() '("x")) ""))
  (check-equal? (exact-statement '("p.drug" "d.label") '("it's" "b") (hasheq 'd.label '("d.linksto")))
                (string-append "SELECT DISTINCT 'p.drug' AS col, drug AS name, '' AS beside FROM p WHERE lower(trim(drug)) IN ('it''s', 'b')"
                               " UNION ALL SELECT DISTINCT 'd.label' AS col, label AS name, ' AND d.linksto = ''' || replace(coalesce(linksto, ''), '''', '''''') || '''' AS beside FROM d WHERE lower(trim(label)) IN ('it''s', 'b')"))
  (check-equal? (near-statement '("p.drug") "5% dex_")
                (string-append "SELECT * FROM (SELECT DISTINCT 'p.drug' AS col, drug AS name, '' AS beside, 1 AS how FROM p WHERE lower(drug) LIKE '%5\\% dex\\_%' ESCAPE '\\' LIMIT 6)"
                               " UNION ALL SELECT * FROM (SELECT DISTINCT 'p.drug' AS col, drug AS name, '' AS beside, 2 AS how FROM p WHERE length(trim(drug)) > 1 AND instr(' 5% dex_ ', ' ' || lower(trim(drug)) || ' ') > 0 LIMIT 6)"))
  (check-regexp-match #rx"^Kind: K three.*\nNAMES\nYour question's words hold none" (kind-text dir '(3) #f #f "NAMES"))
  ;; what to do next comes with the first example, once
  (display-to-file "Next: write it." (build-path dir "examples" "next.md"))
  (check-regexp-match #rx"none of the 3 kinds.*\n\nNext: write it[.]\n$" (kind-text dir '(3) #f #t))
  (check-false (regexp-match? #rx"Next:" (kind-text dir '(3) #f #f)))
  (define asked '())
  (define tools (tables-tools dir (delay (workspace (lambda (sql) (error "not asked in this test"))
                                                     (lambda (sql) (set! asked (cons sql asked))
                                                       (if (regexp-match? #rx"nope" sql) (values "no such table: nope" #t) (values "{\"rows\":[]}" #f)))))))
  (define (request method [params (hasheq)] #:id [id 1]) (hasheq 'jsonrpc "2.0" 'id id 'method method 'params params))
  (define (answered m) (hash-ref (hash-ref m 'result) 'content))
  ;; initialize: the client's revision when it is one of ours; tools and nothing else announced
  (let ([r (hash-ref (handle (request "initialize" (hasheq 'protocolVersion "2025-03-26")) tools) 'result)])
    (check-equal? (hash-ref r 'protocolVersion) "2025-03-26")
    (check-equal? (hash-keys (hash-ref r 'capabilities)) '(tools)))
  (check-equal? (hash-ref (hash-ref (handle (request "initialize" (hasheq 'protocolVersion "1999-01-01")) tools) 'result) 'protocolVersion)
                "2025-06-18")
  (check-false (handle (hasheq 'jsonrpc "2.0" 'method "notifications/initialized") tools) "a notification has no response")
  (check-equal? (map (lambda (t) (hash-ref t 'name)) (hash-ref (hash-ref (handle (request "tools/list") tools) 'result) 'tools))
                '("kind" "sql" "answer"))
  ;; the definitions are what every call of the model carries: held small
  (check-true (< (string-length (jsexpr->string (hash-ref (handle (request "tools/list") tools) 'result))) 1500))
  (let ([first (hash-ref (car (answered (handle (request "tools/call" (hasheq 'name "kind" 'arguments (hasheq 'numbers '(3)))) tools))) 'text)]
        [second (hash-ref (car (answered (handle (request "tools/call" (hasheq 'name "kind" 'arguments (hasheq 'numbers '(3) 'every_phrase #t))) tools))) 'text)])
    (check-regexp-match #rx"^Kind: K three" first)
    (check-regexp-match #rx"Next: write it" first)
    (check-false (regexp-match? #rx"Next: write it" second) "said once")
    (check-regexp-match #rx"\"today\"" second "every phrase when asked"))
  (check-equal? (hash-ref (car (answered (handle (request "tools/call" (hasheq 'name "sql" 'arguments (hasheq 'text "SELECT 1"))) tools))) 'text)
                "{\"rows\":[]}")
  (check-equal? asked '("SELECT 1"))
  ;; what the caller got wrong is the tool's error, not the protocol's
  (let ([r (hash-ref (handle (request "tools/call" (hasheq 'name "sql" 'arguments (hasheq 'text "SELECT * FROM nope"))) tools) 'result)])
    (check-true (hash-ref r 'isError))
    (check-equal? (hash-ref (car (hash-ref r 'content)) 'text) "no such table: nope"))
  (check-true (hash-ref (hash-ref (handle (request "tools/call" (hasheq 'name "sql" 'arguments (hasheq))) tools) 'result) 'isError))
  (check-true (hash-ref (hash-ref (handle (request "tools/call" (hasheq 'name "answer" 'arguments (hasheq 'sql "SELECT 1"))) tools) 'result) 'isError)
              "an answer names its kind")
  (check-equal? (hash-ref (hash-ref (handle (request "tools/call" (hasheq 'name "explain")) tools) 'error) 'code) -32602)
  (check-equal? (hash-ref (hash-ref (handle (request "resources/list") tools) 'error) 'code) -32601)
  (delete-directory/files dir))
