#lang racket/base

;;; definition-first.rkt — experiment D of value-experiment/PROTOCOL.md: an operation declared in
;;; the capability language (L) against one built by hand in Python (G), through a build and three
;;; changes to its OperationDefinition, each server held to requests an independent agent wrote.
;;;
;;;   racket definition-first.rkt author SLOT "AREA" OUT [--model M]   an agent writes an operation's
;;;                                              four versions and their cases into tasks/SLOT
;;;   racket definition-first.rkt check SLOT OUT [--model M]   a second agent decides every request
;;;                                              on its own; what it decides otherwise is dropped
;;;   racket definition-first.rkt run OUT [--implementers 5] [--slots a,b] [--arms L,G] [--parallel 4]
;;;                                              [--model M] [--resume]   the lineages: four sessions each
;;;   racket definition-first.rkt score OUT [--parallel 4]   every stage's server started and sent
;;;                                              every case of its version
;;;   racket definition-first.rkt report OUT     the comparison the protocol states
;;;   racket definition-first.rkt misses OUT     each case some lineage gets wrong
;;;
;;; Data definitions (tasks.rkt has Slot, Version, Arm, Case).
;;; A Response is (response status body): what a server answered — status an integer, or #f when
;;;   it answered nothing; body a jsexpr, or #f when it is not JSON.
;;; A Lineage is one implementer's server through the four versions: OUT/<slot>-<arm>-<i>/v1 … v4,
;;;   each the directory its session left, with record.json (the session) and score.json (the
;;;   scorer's).

(require racket/file racket/list racket/string racket/math racket/port racket/tcp racket/path json
         net/http-client
         "tasks.rkt" "../implementers.rkt"
         (only-in "../analysis.rkt" verdict-of interval clear-null?)
         (only-in "../../agent-bench/run-agent.rkt" run-item in-parallel audit current-resume? read-json-file write-json-file))

(provide (struct-out response) wrong agree? lines-touched non-local-requests)

(struct response (status body) #:transparent)

;; ---- is an answer the expected one --------------------------------------------------------------------
;; near? : real real real -> boolean
(define (near? a e tolerance) (<= (abs (- a e)) (+ tolerance 1e-9)))

;; value-matches? : jsexpr jsexpr real -> boolean   an answered value against the expected one: a
;; number within the tolerance, an object by the keys the expected one gives, anything else equal
(define (value-matches? actual expected tolerance)
  (cond [(and (real? expected) (not (boolean? expected))) (and (real? actual) (near? actual expected tolerance))]
        [(hash? expected)
         (and (hash? actual)
              (for/and ([(k v) (in-hash expected)] #:unless (eq? k 'unit))
                (and (hash-has-key? actual k) (value-matches? (hash-ref actual k) v tolerance))))]
        [else (equal? actual expected)]))

;; value-keys : jsexpr -> (listof symbol)   the value[x] keys of a Parameters.parameter entry
(define (value-keys entry)
  (for/list ([k (in-hash-keys entry)] #:when (regexp-match? #rx"^value[A-Z]" (symbol->string k))) k))

;; output-matches? : jsexpr jsexpr -> boolean   an answered parameter against an expected output
;; {name, type, value, tolerance?}: the name, the one value key naming the declared type, the value
(define (output-matches? entry expected)
  (define key (string->symbol (hash-ref expected 'type)))
  (and (hash? entry)
       (equal? (hash-ref entry 'name #f) (hash-ref expected 'name))
       (equal? (value-keys entry) (list key))
       (value-matches? (hash-ref entry key) (hash-ref expected 'value) (hash-ref expected 'tolerance 0))))

;; outputs-wrong : (listof jsexpr) (listof jsexpr) -> (or/c #f string)   every expected output
;; answered once and nothing else answered
(define (outputs-wrong entries expected)
  (let loop ([expected expected] [left entries])
    (cond [(null? expected)
           (and (pair? left)
                (format "an output the definition does not declare here: ~a"
                        (string-join (map (lambda (e) (format "~a" (if (hash? e) (hash-ref e 'name "?") e))) left) ", ")))]
          [else
           (define e (car expected))
           (define hit (findf (lambda (entry) (output-matches? entry e)) left))
           (if hit
               (loop (cdr expected) (remq hit left))
               (format "output ~a: expected ~a ~a" (hash-ref e 'name) (hash-ref e 'type) (jsexpr->string (hash-ref e 'value))))])))

;; wrong : jsexpr Response -> (or/c #f string)   #f when the response is what the case expects,
;; else why it is not
(define (wrong expect r)
  (define status (response-status r))
  (define body (response-body r))
  (define type (and (hash? body) (hash-ref body 'resourceType #f)))
  (cond [(not status) "no answer"]
        [(equal? (hash-ref expect 'status) 200)
         (cond [(not (eqv? status 200)) (format "status ~a where 200 is expected" status)]
               [(not (equal? type "Parameters")) (format "a ~a where a Parameters is expected" (or type "body that is not a resource"))]
               [else (let ([entries (hash-ref body 'parameter '())])
                       (if (list? entries) (outputs-wrong entries (hash-ref expect 'outputs '())) "parameter is not a list"))])]
        [(not (<= 400 status 499)) (format "status ~a where a 4xx is expected" status)]
        [(not (equal? type "OperationOutcome")) (format "a ~a where an OperationOutcome is expected" (or type "body that is not a resource"))]
        [else #f]))

;; verdict->response : jsexpr -> Response   what the checking agent decided of a request, as the
;; answer of a server would be
(define (verdict->response v)
  (cond [(equal? (hash-ref v 'status #f) 200)
         (response 200 (hasheq 'resourceType "Parameters"
                               'parameter (for/list ([o (in-list (hash-ref v 'outputs '()))])
                                            (hasheq 'name (hash-ref o 'name) (string->symbol (hash-ref o 'type)) (hash-ref o 'value)))))]
        [(equal? (hash-ref v 'status #f) "4xx") (response 400 (hasheq 'resourceType "OperationOutcome"))]
        [else (response #f #f)]))

;; agree? : Case (or/c #f jsexpr) -> boolean   the author's expectation and the checker's verdict
(define (agree? c verdict)
  (and verdict (not (wrong (hash-ref c 'expect) (verdict->response verdict)))))

;; ---- the tasks: written by one agent, decided again by another ---------------------------------------
(define authoring-tools '("Bash(python3:*)" "Bash(ls:*)" "Bash(cat:*)" "Bash(head:*)" "Bash(tail:*)" "Bash(grep:*)" "Bash(wc:*)"
                          "Read" "Write" "Edit" "Glob" "Grep"))
(define builtin '("Bash" "Read" "Write" "Edit" "Glob" "Grep"))

;; author-prompt : string -> string
(define (author-prompt area)
  (string-append
   "You are writing the material of an experiment in which programmers implement a FHIR operation as an HTTP server "
   "and then keep it up to date as its definition changes. Only the files you write count. Work only in this directory; "
   "you may use python3 (standard library) to compute and to generate files.\n\n"
   "Design ONE clinical calculator as a FHIR operation, in this area: " area ". "
   "It must be a real calculation clinicians use (a published equation or score), stated completely enough that two "
   "programmers working apart compute the same answers.\n\n"
   "Write it in four versions, v1 to v4, as it might change over a year:\n"
   "- v1: the operation as first published.\n"
   "- v2: a new REQUIRED input is added, and the computation uses it.\n"
   "- v3: an existing input is constrained: its type changes, or it becomes bound to codes (or to fewer codes), or how many of it may be given changes.\n"
   "- v4: an output changes: one is renamed, or added, or changes its type.\n"
   "Each version keeps everything of the one before except what its change replaces. The operation's `code` stays the same.\n\n"
   "In every version the operation is at system level (called at /$<code>), has 4 to 7 input parameters and 2 to 4 output "
   "parameters, all flat (no parts, no resources). Input types are among decimal, integer, boolean, code, string, date and "
   "Quantity, with at least one decimal or integer, at least one code with a required binding, and at least one optional "
   "input. At least one rule on a value is one the definition cannot express (a range, a date not in the future, one input "
   "consistent with another) and is stated in the statement. Output types are among decimal, integer, boolean, code, string "
   "and Quantity.\n\n"
   "How a server is called and what it must answer is fixed by this contract, which the programmers are given word for word:\n\n"
   "--- CONTRACT.md ---\n" contract-text "--- end of CONTRACT.md ---\n\n"
   "For each version write a directory (v1, v2, v3, v4) holding:\n\n"
   "1. OperationDefinition.json — a FHIR R4 OperationDefinition: url, name, title, status, kind \"operation\", code, "
   "system true, type false, instance false, description, and parameter[] with name, use (in or out), min, max, type, "
   "documentation, and for a bound code binding {strength: \"required\", valueSet: <a canonical url>}.\n\n"
   "2. STATEMENT.md — complete and self-contained for its version (never \"as before\"): what each input means, with its "
   "unit; for each bound input the code system and every code the value set holds (there is no terminology server); every "
   "rule a value must meet; the computation step by step, with its constants; each output with its type, its unit, the number "
   "of decimals it is rounded to, and for an optional output when it is there.\n\n"
   "3. CHANGE.md (v2, v3, v4 only) — what changed since the version before, in a few lines, as a changelog entry says it.\n\n"
   "4. cases.json — at least 32 test requests for that version, a JSON array of\n"
   "   {\"id\": \"c01\", \"about\": \"<what it tests, a few words>\", \"change\": false, \"request\": <the Parameters resource>, \"expect\": …}\n"
   "   where expect is {\"status\": 200, \"outputs\": [{\"name\": …, \"type\": \"valueDecimal\", \"value\": …, \"tolerance\": …}, …]} "
   "for a request that conforms (every output the server must answer; `tolerance` on a number: half a unit of the last decimal "
   "place it is rounded to, 0 for an integer; a Quantity's value is {\"value\": …, \"unit\": …, \"system\": …, \"code\": …}), "
   "or {\"status\": \"4xx\"} for one that does not.\n"
   "   About three fifths conform, and between them take every branch of the computation, with optional inputs given and left out. "
   "The rest do not conform, each by ONE fault, and between them cover every kind of fault the contract names that this version "
   "can have: each required input missing, an input given more times than its maximum, a value under a key of another type, a "
   "code outside its binding, each rule of the statement broken. Do not write a case the contract says is not tested, or one "
   "whose answer the definition and the statement do not decide. Keep computed values away from the thresholds of a category "
   "unless the statement says which side the threshold is on.\n"
   "   In v2, v3 and v4 at least 10 cases have \"change\": true: a server still implementing the version before would answer "
   "them wrongly.\n"
   "   Ids are c01, c02, … in an order that mixes the kinds (every fifth case will be shown to the programmers as an example, "
   "without its expected answer).\n\n"
   "Compute the expected answers with a Python script you keep in the directory (make_cases.py), not by hand, and check that "
   "every cases.json parses and every request is a Parameters resource. When the four directories are complete, end with one short line."))

;; checker-prompt : -> string
(define (checker-prompt)
  (string-append
   "You are checking test material. This directory holds four versions (v1 to v4) of a FHIR operation. Each version has "
   "OperationDefinition.json (its definition), STATEMENT.md (what it computes and the rules its inputs must meet) and "
   "requests.json (test requests: a JSON array of {\"id\", \"request\"}). CONTRACT.md says how a server must answer.\n\n"
   "For every request of every version, decide for yourself what a correct server answers under that version's definition, "
   "statement and the contract. Nobody has told you the answers. Use python3 (standard library) to compute: write the "
   "computation from the statement yourself.\n\n"
   "Write, in each version's directory, verdicts.json: a JSON array with one object for each request,\n"
   "  {\"id\": …, \"status\": 200, \"outputs\": [{\"name\": …, \"type\": \"valueDecimal\", \"value\": …}, …]}   when the request conforms "
   "(every output a correct server answers; `type` is the key the value is under; a Quantity's value is {\"value\", \"unit\", \"system\", \"code\"}),\n"
   "  {\"id\": …, \"status\": \"4xx\", \"reason\": \"<the fault>\"}   when it does not conform,\n"
   "  {\"id\": …, \"status\": \"undecided\", \"reason\": \"<why>\"}   when the definition, the statement and the contract do not decide it.\n\n"
   "Work only in this directory. When the four verdicts.json files are written, end with one short line."))

(define (ensure-clean-directory! d) (when (directory-exists? d) (delete-directory/files d)) (make-directory* d))

;; author! : Slot string dir model -> void   the agent's four versions, put under tasks/<slot>
(define (author! slot area out model)
  (define work (build-path out (format "author-~a" slot)))
  (define rec (run-item (format "author-~a" slot) (author-prompt area) work model authoring-tools
                        #:builtin builtin #:timeout 3600 #:max-turns 200))
  (define dest (build-path tasks-root slot))
  (ensure-clean-directory! dest)
  (for ([v (in-list versions)])
    (define from (build-path work (format "v~a" v)))
    (define to (build-path dest (format "v~a" v)))
    (make-directory* to)
    (for ([n (in-list '("OperationDefinition.json" "STATEMENT.md" "CHANGE.md" "cases.json"))]
          #:when (file-exists? (build-path from n)))
      (copy-file (build-path from n) (build-path to n))))
  ;; the author's own scripts are kept beside, for whoever asks how an expected answer was computed
  (make-directory* (build-path dest "author"))
  (for ([f (in-list (find-files (lambda (p) (regexp-match? #rx"[.]py$" (path->string p))) work))])
    (copy-file f (build-path dest "author" (regexp-replace* #rx"/" (path->string (find-relative-path (simplify-path work) (simplify-path f))) "-")) #t))
  (printf "~a: ~as, ~a input tokens, ~a turns; cases ~a\n" slot (hash-ref rec 'seconds) (hash-ref rec 'input_tokens) (hash-ref rec 'turns)
          (for/list ([v (in-list versions)])
            (with-handlers ([exn:fail? (lambda (e) 'missing)]) (length (all-cases slot v))))))

;; check! : Slot dir model -> void   the second agent's verdicts; tasks/<slot>/v<k>/dropped.json
;; names each case it decided otherwise, or did not decide
(define (check! slot out model)
  (define work (build-path out (format "check-~a" slot)))
  (define (prepare)
    (display-to-file contract-text (build-path work "CONTRACT.md") #:exists 'truncate)
    (for ([v (in-list versions)])
      (define d (build-path work (format "v~a" v)))
      (make-directory* d)
      (write-json-file (build-path d "OperationDefinition.json") (definition slot v))
      (display-to-file (statement slot v) (build-path d "STATEMENT.md") #:exists 'truncate)
      (write-json-file (build-path d "requests.json")
                       (for/list ([c (in-list (all-cases slot v))]) (hasheq 'id (hash-ref c 'id) 'request (hash-ref c 'request))))))
  (define rec (run-item (format "check-~a" slot) (checker-prompt) work model authoring-tools
                        #:prepare prepare #:builtin builtin #:timeout 3600 #:max-turns 200))
  (for ([v (in-list versions)])
    (define f (build-path work (format "v~a" v) "verdicts.json"))
    (define verdicts (if (file-exists? f) (with-handlers ([exn:fail? (lambda (_) '())]) (read-json-file f)) '()))
    (define by-id (for/hash ([x (in-list (if (list? verdicts) verdicts '()))] #:when (hash? x)) (values (hash-ref x 'id #f) x)))
    (define dropped
      (for/list ([c (in-list (all-cases slot v))] #:unless (agree? c (hash-ref by-id (hash-ref c 'id) #f)))
        (define verdict (hash-ref by-id (hash-ref c 'id) #f))
        (hasheq 'id (hash-ref c 'id) 'about (hash-ref c 'about "")
                'author (hash-ref c 'expect)
                'checker (or verdict "no verdict"))))
    (define dir (build-path tasks-root slot (format "v~a" v)))
    (write-json-file (build-path dir "verdicts.json") (if (list? verdicts) verdicts '()))
    (write-json-file (build-path dir "dropped.json") dropped)
    (printf "~a v~a: ~a cases, ~a dropped, ~a kept (~a examples, ~a scored)\n" slot v (length (all-cases slot v)) (length dropped)
            (length (cases slot v)) (length (sample-cases-of slot v)) (length (held-cases-of slot v))))
  (printf "~a: checked in ~as, ~a input tokens\n" slot (hash-ref rec 'seconds) (hash-ref rec 'input_tokens)))

;; ---- run: an implementer's four sessions -----------------------------------------------------------
;; allowed : Arm -> (listof string)   Python, curl and files for both; the toolkit's commands for L
(define (allowed arm)
  (append '("Bash(python3:*)" "Bash(curl:*)" "Bash(ls:*)" "Bash(cat:*)" "Bash(head:*)" "Bash(tail:*)" "Bash(grep:*)"
            "Bash(wc:*)" "Bash(diff:*)" "Bash(kill:*)" "Bash(sleep:*)" "Read" "Write" "Edit" "Glob" "Grep")
          (if (eq? arm 'L) '("Bash(raco:*)" "Bash(racket:*)") '())))

;; what a session's commands must not name: the network's tools, and where the material came from
(define forbidden '("pip " "wget" "git clone" "github" "/home/" "/usr/" "fhir-examples" "value-experiment" "definition-first"))

;; non-local-requests : (listof string) -> (listof string)   the commands that name a host other
;; than the implementer's own server in a curl call
(define (non-local-requests commands)
  (for/list ([c (in-list commands)]
             #:when (and (regexp-match? #rx"curl" c)
                         (for/or ([host (in-list (regexp-match* #rx"https?://([^/:\" ']+)" c #:match-select cadr))])
                           (not (member host '("127.0.0.1" "localhost" "[::1]"))))
                         ;; a code system's url inside a request body is not a host called
                         (for/or ([target (in-list (regexp-match* #rx"curl[^|;&]*" c))])
                           (for/or ([host (in-list (regexp-match* #rx"(?<![\"'|#])https?://([^/:\" ']+)" target #:match-select cadr))])
                             (not (member host '("127.0.0.1" "localhost" "[::1]")))))))
    c))

(define (lineage-id slot arm i) (format "~a-~a-~a" slot arm i))
(define (stage-dir out slot arm i v) (build-path out (lineage-id slot arm i) (format "v~a" v)))

;; run-stage! : dir Slot Arm natural Version model -> void   one session of a lineage
(define (run-stage! out slot arm i v model)
  (define work (stage-dir out slot arm i v))
  (define before (and (> v 1) (stage-dir out slot arm i (sub1 v))))
  (define id (format "~a-v~a" (lineage-id slot arm i) v))
  (define rec
    (run-item id (task-prompt arm v) work model (allowed arm)
              #:prepare (lambda () (prepare-stage! slot arm v work before))
              #:builtin builtin #:timeout 3000 #:max-turns 150))
  (define bad (remove-duplicates (append (audit rec forbidden) (non-local-requests (hash-ref rec 'commands '())))))
  (unless (null? bad) (display-lines-to-file bad (build-path work "AUDIT") #:exists 'truncate))
  (printf "~a ~as in ~a out ~a turns ~a~a\n" id (hash-ref rec 'seconds) (hash-ref rec 'input_tokens)
          (hash-ref rec 'output_tokens) (hash-ref rec 'turns)
          (cond [(null? (implementation-files work)) "  NO implementation"] [(null? bad) ""] [else "  AUDIT"]))
  (flush-output))

;; run-lineage! : dir Slot Arm natural model -> void   the build, then each change in its own session
(define (run-lineage! out slot arm i model)
  (for ([v (in-list versions)]) (run-stage! out slot arm i v model)))

;; lineages : dir -> (listof (list Slot Arm natural))   the lineages a run holds
(define (lineages out)
  (for*/list ([slot (in-list (slots))] [arm (in-list arms)] [i (in-range 1 100)]
              #:when (directory-exists? (build-path out (lineage-id slot arm i))))
    (list slot arm i)))

;; ---- score: each stage's server, started and sent its version's cases --------------------------------
(define start-seconds (make-parameter 150))
(define request-seconds (make-parameter 30))

;; free-port : -> natural
(define (free-port)
  (define l (tcp-listen 0 1 #t "127.0.0.1"))
  (define-values (_a port _b _c) (tcp-addresses l #t))
  (tcp-close l)
  port)

;; listening? : natural -> boolean
(define (listening? port)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (define-values (i o) (tcp-connect "127.0.0.1" port))
    (close-input-port i) (close-output-port o)
    #t))

;; post : natural string jsexpr -> Response   the request sent to the server on the port
(define (post port code request)
  (define result (make-channel))
  (define worker
    (thread
     (lambda ()
       (channel-put
        result
        (with-handlers ([exn:fail? (lambda (_) (response #f #f))])
          (define-values (status-line _headers in)
            (http-sendrecv "127.0.0.1" (string-append "/$" code) #:port port #:method "POST"
                           #:headers '("Content-Type: application/fhir+json" "Accept: application/fhir+json")
                           #:data (jsexpr->bytes request)))
          (define status (let ([m (regexp-match #rx#"^HTTP/[0-9.]+ ([0-9]+)" status-line)]) (and m (string->number (bytes->string/utf-8 (cadr m))))))
          (define text (port->bytes in))
          (close-input-port in)
          (response status (with-handlers ([exn:fail? (lambda (_) #f)]) (bytes->jsexpr text))))))))
  (define r (sync/timeout (request-seconds) result))
  (unless r (kill-thread worker))
  (or r (response #f #f)))

;; call-with-server : dir Arm (natural -> X) (-> X) -> X   the arm's server of a directory started
;; on a free port; `use` is given the port once it listens, `failed` is called when it does not
(define (call-with-server dir arm use failed)
  (define port (free-port))
  (define command (map (lambda (a) (string-replace a "{port}" (number->string port))) (start-command arm)))
  (define log (open-output-file (build-path dir "server.log") #:exists 'truncate))
  (define proc
    (parameterize ([current-directory dir] [subprocess-group-enabled #t])
      (define-values (p _o i _e)
        (apply subprocess log #f 'stdout (find-executable-path (car command)) (cdr command)))
      (close-output-port i)
      p))
  (dynamic-wind
   void
   (lambda ()
     (define deadline (+ (current-inexact-milliseconds) (* 1000 (start-seconds))))
     (let wait ()
       (cond [(listening? port) (use port)]
             [(or (not (eq? (subprocess-status proc) 'running)) (> (current-inexact-milliseconds) deadline)) (failed)]
             [else (sleep 0.2) (wait)])))
   (lambda ()
     (subprocess-kill proc #t)
     (close-output-port log))))

;; file-lines : path -> (listof string)
(define (file-lines f) (with-handlers ([exn:fail? (lambda (_) '())]) (file->lines f)))

;; lines-touched : (listof string) (listof string) -> natural   the lines one text has that the
;; other lacks, both ways, each line counted as often as it stands
(define (lines-touched old new)
  (define (counts ls) (for/fold ([h (hash)]) ([l (in-list ls)]) (hash-update h l add1 0)))
  (define a (counts old))
  (define b (counts new))
  (+ (for/sum ([(l n) (in-hash b)]) (max 0 (- n (hash-ref a l 0))))
     (for/sum ([(l n) (in-hash a)]) (max 0 (- n (hash-ref b l 0))))))

;; implementation-lines : dir -> (hash string (listof string))   an implementation, file by file
(define (implementation-lines dir)
  (for/hash ([f (in-list (implementation-files dir))]) (values (path->string f) (file-lines (build-path dir f)))))

;; touched-between : dir dir -> natural   over every file of either implementation
(define (touched-between before after)
  (define a (implementation-lines before))
  (define b (implementation-lines after))
  (for/sum ([f (in-list (remove-duplicates (append (hash-keys a) (hash-keys b))))])
    (lines-touched (hash-ref a f '()) (hash-ref b f '()))))

;; score-stage! : dir Slot Arm natural Version -> void   score.json beside the stage's record
(define (score-stage! out slot arm i v)
  (define stage (stage-dir out slot arm i v))
  (define scratch (build-path out "_score" (format "~a-v~a" (lineage-id slot arm i) v)))
  (ensure-clean-directory! scratch)
  (for ([f (in-list (implementation-files stage))])
    (make-directory* (let-values ([(parent _n _d) (split-path (build-path scratch f))]) parent))
    (copy-file (build-path stage f) (build-path scratch f)))
  (define code (operation-code slot v))
  (define all (cases slot v))
  (define answers
    (if (null? (implementation-files stage))
        #f
        (call-with-server scratch arm
                          (lambda (port) (for/hash ([c (in-list all)]) (values (hash-ref c 'id) (post port code (hash-ref c 'request)))))
                          (lambda () #f))))
  (write-json-file
   (build-path stage "score.json")
   (hasheq 'slot slot 'arm (symbol->string arm) 'version v 'started (and answers #t)
           'lines (length (append* (hash-values (implementation-lines stage))))
           'touched (if (> v 1) (touched-between (stage-dir out slot arm i (sub1 v)) stage) (json-null))
           'cases (for/hasheq ([c (in-list all)] [k (in-naturals)])
                    (define r (if answers (hash-ref answers (hash-ref c 'id)) (response #f #f)))
                    (define why (if answers (wrong (hash-ref c 'expect) r) "the server did not start"))
                    (values (string->symbol (hash-ref c 'id))
                            (hasheq 'sample (sample-case? k) 'change (and (hash-ref c 'change #f) #t)
                                    'conforms (equal? (hash-ref (hash-ref c 'expect) 'status) 200)
                                    'status (or (response-status r) (json-null))
                                    'right (not why) 'why (or why (json-null)))))))
  (delete-directory/files scratch))

;; ---- read a scored run ---------------------------------------------------------------------------------
;; A case of a lineage is named "v<k>/<id>": its version is its stratum.
(define (case-version name) (car (string-split name "/")))

;; read-lineage : dir Slot Arm natural -> Impl   outcomes over every version; the cost of the
;; lineage, and of its three change sessions apart
(define (read-lineage out slot arm i)
  (define stages
    (for/list ([v (in-list versions)])
      (define d (stage-dir out slot arm i v))
      (list v (read-json-file (build-path d "score.json")) (read-json-file (build-path d "record.json")))))
  (define (total key from) (for/sum ([s (in-list stages)] #:when (>= (car s) from)) (let ([x (hash-ref (caddr s) key 0)]) (if (real? x) x 0))))
  (impl slot arm
        (for*/hash ([s (in-list stages)] [(c o) (in-hash (hash-ref (cadr s) 'cases))])
          (values (format "v~a/~a" (car s) c)
                  (outcome (hash-ref o 'sample) (and (hash-ref o 'right) #t)
                           (list (hash-ref o 'conforms) (hash-ref o 'change) (let ([w (hash-ref o 'why)]) (if (string? w) w #f))))))
        (hasheq 'input (total 'input_tokens 1) 'change-input (total 'input_tokens 2)
                'build-input (- (total 'input_tokens 1) (total 'input_tokens 2))
                'output (total 'output_tokens 1) 'change-output (total 'output_tokens 2)
                'seconds (total 'seconds 1) 'change-seconds (total 'seconds 2)
                'turns (total 'turns 1)
                'touched (for/sum ([s (in-list stages)]) (let ([x (hash-ref (cadr s) 'touched 0)]) (if (real? x) x 0)))
                'lines (hash-ref (cadr (last stages)) 'lines 0)
                'not-started (count (lambda (s) (not (hash-ref (cadr s) 'started))) stages))))

;; restricted : (listof Impl) (string -> boolean) -> (listof Impl)   the same lineages over the
;; cases the predicate keeps
(define (restricted impls keep?)
  (for/list ([i (in-list impls)])
    (impl (impl-unit i) (impl-arm i)
          (for/hash ([(c o) (in-hash (impl-outcomes i))] #:when (keep? c)) (values c o))
          (impl-cost i))))

;; ---- report --------------------------------------------------------------------------------------------
(define (percent x) (format "~a%" (/ (round (* 1000.0 x)) 10.0)))
(define (points x) (format "~a~a" (if (negative? x) "" "+") (/ (round (* 1000.0 x)) 10.0)))
(define (thousands x) (format "~ak" (/ (round (/ x 100.0)) 10.0)))
(define (two x) (/ (round (* 100.0 x)) 100.0))

;; report-right : string (listof Impl) -> (values real (cons real real))   one reading of "right"
(define (report-right label impls)
  (define d (difference impls 'L 'G))
  (define ci (bootstrap-difference impls 'L 'G #:stratum case-version))
  (printf "~a L ~a, G ~a: L − G = ~a points (95% interval ~a to ~a; permutation p = ~a)\n" label
          (percent (share-right (of-arm impls 'L))) (percent (share-right (of-arm impls 'G)))
          (points d) (points (car ci)) (points (cdr ci))
          (exact->inexact (/ (round (* 10000 (permutation-p impls 'L 'G))) 10000)))
  (values d ci))

;; report-cost : string (listof Impl) symbol -> (values real (cons real real))
(define (report-cost label impls key)
  (define (m arm) (mean (map (lambda (i) (hash-ref (impl-cost i) key)) (of-arm impls arm))))
  (define r (cost-ratio impls 'L 'G key))
  (define ci (cost-ratio-interval impls 'L 'G key))
  (printf "~a L ~a, G ~a: L/G = ~a (95% interval ~a to ~a)\n" label (thousands (m 'L)) (thousands (m 'G))
          (two r) (two (car ci)) (two (cdr ci)))
  (values r ci))

(define (verdict-text diff ci ratio-ci)
  (define d (interval (car ci) (cdr ci)))
  (define r (interval (car ratio-ci) (cdr ratio-ci)))
  (case (verdict-of diff d r)
    [(more-right) "the declared servers are right more often (the protocol's \"significant value\")"]
    [(cheaper) "the declared servers are not worse and cost two thirds or less (the protocol's \"significant value\")"]
    [(worse) "the declared servers are right less often"]
    [else (if (clear-null? d r)
              "no difference shown, and a clear null (the intervals are inside the protocol's bounds)"
              "no difference shown")]))

(define (report impls)
  (define (per-arm f) (for/list ([arm (in-list arms)]) (f (of-arm impls arm))))
  (printf "lineages: ~a declared in the capability language (L), ~a by hand in Python (G); four sessions each\n"
          (length (of-arm impls 'L)) (length (of-arm impls 'G)))
  (printf "requests scored: ~a (~a)\n\n"
          (for/sum ([u (in-list (units impls))]) (length (held-cases (car (of-arm impls 'L u)))))
          (string-join (for/list ([v (in-list versions)])
                         (format "v~a ~a" v (for/sum ([u (in-list (units impls))])
                                              (count (lambda (c) (equal? (case-version c) (format "v~a" v)))
                                                     (held-cases (car (of-arm impls 'L u)))))))
                       ", "))
  (printf "operation version  L right (each lineage)              G right (each lineage)\n")
  (for* ([u (in-list (units impls))] [v (in-list versions)])
    (define at (restricted impls (lambda (c) (equal? (case-version c) (format "v~a" v)))))
    (define (each arm) (string-join (map (lambda (i) (percent (share-right (list i)))) (of-arm at arm u)) " "))
    (printf "~a v~a  ~a    ~a\n" u v (each 'L) (each 'G)))
  (newline)
  (define-values (d ci) (report-right "right, every version   " impls))
  (define after (restricted impls (lambda (c) (not (equal? (case-version c) "v1")))))
  (define-values (d2 ci2) (report-right "right, after a change  " after))
  (call-with-values (lambda () (report-right "right, as first built  " (restricted impls (lambda (c) (equal? (case-version c) "v1"))))) void)
  (for ([label (in-list '("  requests that conform  " "  requests that do not   " "  about the change       "))]
        [keep? (in-list (list (lambda (o) (car (outcome-answer o))) (lambda (o) (not (car (outcome-answer o))))
                              (lambda (o) (cadr (outcome-answer o)))))])
    (define sub (for/list ([i (in-list impls)])
                  (impl (impl-unit i) (impl-arm i)
                        (for/hash ([(c o) (in-hash (impl-outcomes i))] #:when (keep? o)) (values c o)) (impl-cost i))))
    (printf "~a L ~a, G ~a (~a requests a lineage)\n" label (percent (share-right (of-arm sub 'L))) (percent (share-right (of-arm sub 'G)))
            (exact->inexact (two (mean (map (lambda (i) (length (held-cases i))) sub))))))
  (newline)
  (define-values (r rci) (report-cost "input tokens, a lineage     " impls 'input))
  (define-values (r2 rci2) (report-cost "input tokens, the changes   " impls 'change-input))
  (call-with-values (lambda () (report-cost "input tokens, the build     " impls 'build-input)) void)
  (define (m arm key) (mean (map (lambda (i) (hash-ref (impl-cost i) key)) (of-arm impls arm))))
  (printf "a lineage, L and G: output tokens ~a and ~a; seconds ~a and ~a (the changes ~a and ~a); model turns ~a and ~a\n"
          (thousands (m 'L 'output)) (thousands (m 'G 'output)) (exact-round (m 'L 'seconds)) (exact-round (m 'G 'seconds))
          (exact-round (m 'L 'change-seconds)) (exact-round (m 'G 'change-seconds))
          (exact->inexact (two (m 'L 'turns))) (exact->inexact (two (m 'G 'turns))))
  (printf "the implementation, L and G: ~a and ~a lines at the end; ~a and ~a lines touched by the three changes\n"
          (exact-round (m 'L 'lines)) (exact-round (m 'G 'lines)) (exact-round (m 'L 'touched)) (exact-round (m 'G 'touched)))
  (printf "servers that did not start: L ~a of ~a stages, G ~a of ~a\n"
          (for/sum ([i (in-list (of-arm impls 'L))]) (hash-ref (impl-cost i) 'not-started)) (* 4 (length (of-arm impls 'L)))
          (for/sum ([i (in-list (of-arm impls 'G))]) (hash-ref (impl-cost i) 'not-started)) (* 4 (length (of-arm impls 'G))))
  (printf "lineages right on every request: L ~a of ~a, G ~a of ~a\n"
          (count (lambda (i) (= 1 (share-right (list i)))) (of-arm impls 'L)) (length (of-arm impls 'L))
          (count (lambda (i) (= 1 (share-right (list i)))) (of-arm impls 'G)) (length (of-arm impls 'G)))
  (printf "\nverdict, every version   ~a\n" (verdict-text d ci rci))
  (printf "verdict, after a change  ~a\n" (verdict-text d2 ci2 rci2)))

;; misses : (listof Impl) -> void   each scored case some lineage gets wrong, with how many of each
;; arm and the commonest reason
(define (misses impls)
  (for ([u (in-list (units impls))])
    (printf "~a\n" u)
    (define group (filter (lambda (i) (equal? (impl-unit i) u)) impls))
    (for ([c (in-list (held-cases (car group)))])
      (define (wrong-of arm) (filter (lambda (i) (not (outcome-right? (hash-ref (impl-outcomes i) c)))) (of-arm group arm)))
      (define l (wrong-of 'L))
      (define g (wrong-of 'G))
      (unless (and (null? l) (null? g))
        (define slot+version (string-split c "/"))
        (define about
          (let ([found (findf (lambda (x) (equal? (hash-ref x 'id) (cadr slot+version)))
                              (cases u (string->number (substring (car slot+version) 1))))])
            (if found (hash-ref found 'about "") "")))
        (define reasons (map (lambda (i) (caddr (outcome-answer (hash-ref (impl-outcomes i) c)))) (append l g)))
        (define commonest (car (argmax cdr (for/list ([r (in-list (remove-duplicates reasons))]) (cons r (count (lambda (x) (equal? x r)) reasons))))))
        (printf "  L ~a of ~a wrong, G ~a of ~a   ~a  ~a — ~a\n" (length l) (length (of-arm group 'L)) (length g) (length (of-arm group 'G))
                c about commonest)))))

;; ---- command line ---------------------------------------------------------------------------------------
(module+ main
  (define args (vector->list (current-command-line-arguments)))
  (define (option name default)
    (define at (member name args))
    (if (and at (pair? (cdr at))) (cadr at) default))
  (define (usage) (raise-user-error 'definition-first "author SLOT AREA OUT | check SLOT OUT | run OUT | score OUT | report OUT | misses OUT"))
  (when (null? args) (usage))
  (define model (option "--model" "sonnet"))
  (define (read-run out) (for/list ([l (in-list (lineages out))]) (apply read-lineage out l)))
  (case (car args)
    [("author") (author! (cadr args) (caddr args) (path->complete-path (cadddr args)) model)]
    [("check") (check! (cadr args) (path->complete-path (caddr args)) model)]
    [("run")
     (define out (path->complete-path (cadr args)))
     (define wanted-slots (string-split (option "--slots" (string-join (sealed-slots) ",")) ","))
     (define wanted-arms (map string->symbol (string-split (option "--arms" "L,G") ",")))
     (define n (string->number (option "--implementers" "5")))
     (current-resume? (and (member "--resume" args) #t))
     (make-directory* out)
     (void (in-parallel (string->number (option "--parallel" "4"))
                        (for*/list ([i (in-range 1 (add1 n))] [slot (in-list wanted-slots)] [arm (in-list wanted-arms)]) (list slot arm i))
                        (lambda (l) (apply run-lineage! out (append l (list model))))))]
    [("score")
     (define out (path->complete-path (cadr args)))
     (void (in-parallel (string->number (option "--parallel" "4"))
                        (for*/list ([l (in-list (lineages out))] [v (in-list versions)]) (append l (list v)))
                        (lambda (s) (apply score-stage! out s))))
     (for ([l (in-list (lineages out))])
       (define i (apply read-lineage out l))
       (printf "~a right ~a~a\n" (apply lineage-id l) (percent (share-right (list i)))
               (if (zero? (hash-ref (impl-cost i) 'not-started)) "" (format "  (~a stages did not start)" (hash-ref (impl-cost i) 'not-started)))))]
    [("report") (report (read-run (path->complete-path (cadr args))))]
    [("misses") (misses (read-run (path->complete-path (cadr args))))]
    [else (usage)]))

(module+ test
  (require rackunit)
  ;; ---- an answer against what a case expects
  (define expect-200
    (hasheq 'status 200
            'outputs (list (hasheq 'name "bmi" 'type "valueDecimal" 'value 24.2 'tolerance 0.05)
                           (hasheq 'name "class" 'type "valueCode" 'value "normal")
                           (hasheq 'name "bsa" 'type "valueQuantity" 'tolerance 0.005
                                   'value (hasheq 'value 1.91 'unit "m2" 'system "http://unitsofmeasure.org" 'code "m2")))))
  (define (answer . entries) (response 200 (hasheq 'resourceType "Parameters" 'parameter entries)))
  (define bmi (hasheq 'name "bmi" 'valueDecimal 24.22))
  (define class (hasheq 'name "class" 'valueCode "normal"))
  (define bsa (hasheq 'name "bsa" 'valueQuantity (hasheq 'value 1.912 'unit "square metre" 'system "http://unitsofmeasure.org" 'code "m2")))
  (check-false (wrong expect-200 (answer bmi class bsa)))
  (check-false (wrong expect-200 (answer bsa class bmi)))                         ; any order
  (check-regexp-match #rx"output bmi" (wrong expect-200 (answer (hasheq 'name "bmi" 'valueDecimal 24.3) class bsa)))
  (check-regexp-match #rx"output bmi" (wrong expect-200 (answer (hasheq 'name "bmi" 'valueString "24.2") class bsa)))
  (check-regexp-match #rx"output bmi" (wrong expect-200 (answer (hasheq 'name "bmi" 'valueDecimal 24.2 'valueString "x") class bsa)))
  (check-regexp-match #rx"output class" (wrong expect-200 (answer bmi (hasheq 'name "category" 'valueCode "normal") bsa)))
  (check-regexp-match #rx"output bsa" (wrong expect-200 (answer bmi class (hasheq 'name "bsa" 'valueQuantity (hasheq 'value 1.91 'code "m2")))))
  (check-regexp-match #rx"does not declare" (wrong expect-200 (answer bmi class bsa (hasheq 'name "note" 'valueString "x"))))
  (check-regexp-match #rx"output class" (wrong expect-200 (answer bmi bsa)))
  (check-regexp-match #rx"status 400" (wrong expect-200 (response 400 (hasheq 'resourceType "OperationOutcome"))))
  (check-regexp-match #rx"OperationOutcome where a Parameters" (wrong expect-200 (response 200 (hasheq 'resourceType "OperationOutcome"))))
  (check-equal? (wrong expect-200 (response #f #f)) "no answer")
  ;; an integer is exact; a boolean is not a number
  (check-false (wrong (hasheq 'status 200 'outputs (list (hasheq 'name "n" 'type "valueInteger" 'value 3 'tolerance 0)))
                      (answer (hasheq 'name "n" 'valueInteger 3))))
  (check-not-false (wrong (hasheq 'status 200 'outputs (list (hasheq 'name "n" 'type "valueInteger" 'value 3)))
                          (answer (hasheq 'name "n" 'valueInteger 4))))
  (check-not-false (wrong (hasheq 'status 200 'outputs (list (hasheq 'name "low" 'type "valueBoolean" 'value #t)))
                          (answer (hasheq 'name "low" 'valueBoolean #f))))
  ;; a refusal: any 4xx with an OperationOutcome
  (define refused (hasheq 'status "4xx"))
  (check-false (wrong refused (response 400 (hasheq 'resourceType "OperationOutcome" 'issue '()))))
  (check-false (wrong refused (response 422 (hasheq 'resourceType "OperationOutcome"))))
  (check-regexp-match #rx"status 200" (wrong refused (answer bmi)))
  (check-regexp-match #rx"status 500" (wrong refused (response 500 (hasheq 'resourceType "OperationOutcome"))))
  (check-regexp-match #rx"OperationOutcome is expected" (wrong refused (response 400 #f)))
  ;; ---- the author's expectation against the checker's verdict
  (define a-case (hasheq 'id "c01" 'expect expect-200))
  (check-true (agree? a-case (hasheq 'id "c01" 'status 200
                                     'outputs (list (hasheq 'name "bmi" 'type "valueDecimal" 'value 24.19)
                                                    (hasheq 'name "class" 'type "valueCode" 'value "normal")
                                                    (hasheq 'name "bsa" 'type "valueQuantity" 'value (hasheq 'value 1.91 'system "http://unitsofmeasure.org" 'code "m2"))))))
  (check-false (agree? a-case (hasheq 'id "c01" 'status "4xx" 'reason "x")))
  (check-false (agree? a-case (hasheq 'id "c01" 'status "undecided")))
  (check-false (agree? a-case #f))
  (check-true (agree? (hasheq 'id "c02" 'expect refused) (hasheq 'id "c02" 'status "4xx")))
  ;; ---- lines touched, and what a session may not call
  (check-equal? (lines-touched '("a" "b" "c") '("a" "x" "c" "d")) 3)
  (check-equal? (lines-touched '("a" "a") '("a")) 1)
  (check-equal? (lines-touched '() '("a" "b")) 2)
  (check-equal? (non-local-requests '("curl -s http://127.0.0.1:8123/$bmi -d @examples/c01.json"
                                      "curl -s -X POST localhost:8000/$bmi -d '{\"system\":\"http://loinc.org\"}'"
                                      "curl https://example.org/x"
                                      "python3 try.py"))
                '("curl https://example.org/x"))
  ;; ---- a server started, sent a request, stopped; one that never listens
  (when (find-executable-path "python3")
    (define dir (make-temporary-file "definition-first-~a" 'directory))
    (display-to-file #<<PY
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        ok = self.path == "/$double" and body.get("parameter")
        out = ({"resourceType": "Parameters", "parameter": [{"name": "doubled", "valueDecimal": 2 * body["parameter"][0]["valueDecimal"]}]}
               if ok else {"resourceType": "OperationOutcome", "issue": []})
        data = json.dumps(out).encode()
        self.send_response(200 if ok else 400); self.send_header("Content-Type", "application/fhir+json")
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
                     (build-path dir "server.py"))
    (define-values (good bad)
      (call-with-server dir 'G
                        (lambda (port)
                          (values (post port "double" (hasheq 'resourceType "Parameters" 'parameter (list (hasheq 'name "x" 'valueDecimal 2.5))))
                                  (post port "double" (hasheq 'resourceType "Parameters"))))
                        (lambda () (values #f #f))))
    (check-false (wrong (hasheq 'status 200 'outputs (list (hasheq 'name "doubled" 'type "valueDecimal" 'value 5.0 'tolerance 0.05))) good))
    (check-false (wrong (hasheq 'status "4xx") bad))
    (display-to-file "import sys\nsys.exit(3)\n" (build-path dir "server.py") #:exists 'truncate)
    (check-equal? (parameterize ([start-seconds 5]) (call-with-server dir 'G (lambda (port) 'up) (lambda () 'down))) 'down)
    (delete-directory/files dir)))

;; probe : for trying the harness by hand on a directory that holds an L server for `$double`
(module+ probe
  (provide probe)
  (define (probe dir)
    (call-with-server dir 'L
                      (lambda (port)
                        (for ([request (in-list (list (hasheq 'resourceType "Parameters" 'parameter (list (hasheq 'name "x" 'valueDecimal 2.5)))
                                                      (hasheq 'resourceType "Parameters" 'parameter (list (hasheq 'name "x" 'valueString "2.5")))
                                                      (hasheq 'resourceType "Parameters" 'parameter '())))])
                          (define r (post port "double" request))
                          (printf "~a ~a\n" (response-status r) (jsexpr->string (response-body r)))))
                      (lambda () (printf "did not start\n")))))
