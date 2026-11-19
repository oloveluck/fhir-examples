#lang racket/base

;;; tables-server.rkt — the tables arm's three commands as the tools of one process.
;;;
;;;   racket -l- fhir-examples/agent-bench/fab/tables-server [DIR]
;;;
;;; A Model Context Protocol server on stdin/stdout (one JSON object a line) over the question's
;;; workspace DIR (the current directory when none is given). Its tools are the commands of the
;;; `tables` arm, each answering the text the command prints:
;;;
;;;   kind    {numbers [every_phrase]}  `./kind N …`: the examples of those kinds, then the time phrases
;;;                               the question says (all of them with `every_phrase`), and — the first
;;;                               time — what to do next (examples/next.md, when the run wrote one)
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
;;; where `./kind` printed all 31, and the instructions for writing and submitting the query with
;;; the example they are about, once, where the prompt held them from the first call.
;;;
;;; The protocol is the little of MCP a tool server needs (initialize, ping, tools/list,
;;; tools/call): no resources, no prompts, nothing announced that a client would turn into more
;;; definitions.

(require racket/file racket/list racket/port racket/promise racket/string json
         (only-in "answer.rkt" answer!)
         (only-in "query-checks.rkt" said-times))

(provide handle tool tables-tools kind-text phrases-text tool-wording)

;; A Tool is (tool name description schema run): run : (hash symbol -> jsexpr) -> string, the text
;; answered; it raises exn:fail for what the caller got wrong, which is answered as the tool's error.
(struct tool (name description schema run))

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

;; kind-text : dir (listof integer) [all-phrases? first?] -> string   the examples of those kinds,
;; then how a time phrase is written (run.rkt's `./kind` script prints these, with every phrase),
;; and, the first time, what to do next (examples/next.md)
(define (kind-text dir numbers [all? #t] [first? #f])
  (define (example n)
    (define file (build-path dir "examples" (format "~a.md" n)))
    (if (file-exists? file) (string-append (file->string file) "\n") (format "there is no kind ~a\n" n)))
  (define next (build-path dir "examples" "next.md"))
  (string-append
   (string-append* (map example numbers))
   (phrases-text dir all?)
   (if (and first? (file-exists? next)) (string-append "\n" (file->string next) "\n") "")))

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
         "How a kind of question is answered: for each number, a question or two of that kind, what each assumes and the query that answers it; then how the time phrases of your question are written in such a query."
         (hasheq 'type "object" 'required '("numbers")
                 'properties (hasheq 'numbers (hasheq 'type "array" 'items (hasheq 'type "integer"))
                                     'every_phrase (hasheq 'type "boolean" 'description "Leave out. True only after a time phrase of your question was not among those shown.")))
         (lambda (args)
           (define first? (not (unbox asked-before?)))
           (set-box! asked-before? #t)
           (kind-text dir (integers (hash-ref args 'numbers '())) (eq? (hash-ref args 'every_phrase #f) #t) first?)))
   (tool "sql"
         "One SQLite statement over the tables; its rows come back as JSON. For looking a name up as the tables write it."
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

;; ---- the protocol -----------------------------------------------------------------------------------
(define protocol-versions '("2025-06-18" "2025-03-26" "2024-11-05"))

;; handle : Message (listof Tool) -> jsexpr | #f   the response to a request; #f for a notification
(define (handle m tools)
  (define id (hash-ref m 'id #f))
  (define params (let ([p (hash-ref m 'params #f)]) (if (hash? p) p (hasheq))))
  (define (result r) (hasheq 'jsonrpc "2.0" 'id id 'result r))
  (define (failure code message) (hasheq 'jsonrpc "2.0" 'id id 'error (hasheq 'code code 'message message)))
  (define (said text error?) (result (hasheq 'content (list (hasheq 'type "text" 'text text)) 'isError error?)))
  (and id
       (case (hash-ref m 'method #f)
         [("initialize")
          (result (hasheq 'protocolVersion (let ([asked (hash-ref params 'protocolVersion #f)])
                                             (if (member asked protocol-versions) asked (car protocol-versions)))
                          'capabilities (hasheq 'tools (hasheq))
                          'serverInfo (hasheq 'name "tables" 'version "1")))]
         [("ping") (result (hasheq))]
         [("tools/list")
          (result (hasheq 'tools (for/list ([t (in-list tools)])
                                   (hasheq 'name (tool-name t) 'description (tool-description t) 'inputSchema (tool-schema t)))))]
         [("tools/call")
          (define t (findf (lambda (t) (equal? (tool-name t) (hash-ref params 'name #f))) tools))
          (define args (let ([a (hash-ref params 'arguments #f)]) (if (hash? a) a (hasheq))))
          (cond [(not t) (failure -32602 (format "unknown tool ~a" (hash-ref params 'name #f)))]
                [else (with-handlers ([exn:fail? (lambda (e) (said (exn-message e) #t))])
                        (said ((tool-run t) args) #f))])]
         [else (failure -32601 (format "unknown method ~a" (hash-ref m 'method #f)))])))

(module+ main
  (define dir (path->complete-path (let ([args (current-command-line-arguments)])
                                     (if (zero? (vector-length args)) (current-directory) (vector-ref args 0)))))
  ;; opened while the client is still starting and the model reading: the first call waits for it
  (define opened (delay/thread (open-workspace dir)))
  (define tools (tables-tools dir opened))
  (define out (current-output-port))
  (let loop ()
    (define line (read-line (current-input-port) 'any))
    (unless (eof-object? line)
      (define m (with-handlers ([exn:fail? (lambda (_) #f)]) (string->jsexpr line)))
      (define response (and (hash? m) (handle m tools)))
      (when response (write-json response out) (newline out) (flush-output out))
      (loop))))

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
