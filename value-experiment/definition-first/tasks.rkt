#lang racket/base

;;; tasks.rkt — the material of experiment D (PROTOCOL.md, "the definition as the implementation"):
;;; the operations an independent agent wrote (tasks/<slot>/v1 … v4: OperationDefinition.json,
;;; STATEMENT.md, CHANGE.md, cases.json; dropped.json names the cases a second agent decided
;;; otherwise), the contract, an implementer's prompt for each arm and version, and its directory.
;;;
;;; Data definitions.
;;; A Slot is a string: the directory of an operation under tasks/ ("trial", "a", "b", "c").
;;; A Version is 1 | 2 | 3 | 4: the operation as first published, then after each change.
;;; An Arm is 'L (declared in the capability language) | 'G (by hand, in Python).
;;; A Case is a jsexpr: {id, about, change, request, expect}; expect is {status: 200, outputs:
;;;   [{name, type, value, tolerance?}…]} or {status: "4xx"}.

(require racket/file racket/list racket/string racket/runtime-path racket/port racket/system json)

(provide slots sealed-slots trial-slot versions arms
         definition operation-code statement change-text all-cases cases sample-case? held-cases-of sample-cases-of
         contract-text task-prompt prepare-stage! start-command implementation-files given-names
         tasks-root guide-text)

(define-runtime-path tasks-root "tasks")
(define-runtime-path try-script "try.py")

(define versions '(1 2 3 4))
(define arms '(L G))
(define trial-slot "trial")

;; slots : -> (listof Slot)   the operations there are, the trial first
(define (slots)
  (define found (if (directory-exists? tasks-root)
                    (sort (for/list ([d (in-list (directory-list tasks-root))]
                                     #:when (file-exists? (build-path tasks-root d "v1" "OperationDefinition.json")))
                            (path->string d))
                          string<?)
                    '()))
  (append (filter (lambda (s) (equal? s trial-slot)) found) (remove trial-slot found)))
(define (sealed-slots) (remove trial-slot (slots)))

(define (version-dir slot v) (build-path tasks-root slot (format "v~a" v)))
(define (read-json-file f) (call-with-input-file f read-json))

;; definition : Slot Version -> jsexpr   the OperationDefinition
(define (definition slot v) (read-json-file (build-path (version-dir slot v) "OperationDefinition.json")))
(define (operation-code slot v) (hash-ref (definition slot v) 'code))
(define (statement slot v) (file->string (build-path (version-dir slot v) "STATEMENT.md")))
;; change-text : Slot Version -> string   what changed since the version before (versions 2 to 4)
(define (change-text slot v) (file->string (build-path (version-dir slot v) "CHANGE.md")))

;; all-cases : Slot Version -> (listof Case)   as the author wrote them, in id order
(define (all-cases slot v)
  (sort (read-json-file (build-path (version-dir slot v) "cases.json")) string<?
        #:key (lambda (c) (hash-ref c 'id))))

;; cases : Slot Version -> (listof Case)   without those the second agent decided otherwise
(define (cases slot v)
  (define f (build-path (version-dir slot v) "dropped.json"))
  (define dropped (if (file-exists? f) (map (lambda (d) (hash-ref d 'id)) (read-json-file f)) '()))
  (filter (lambda (c) (not (member (hash-ref c 'id) dropped))) (all-cases slot v)))

;; sample-case? : natural -> boolean   every fifth case, in id order, is an implementer's example
(define (sample-case? index) (zero? (modulo index 5)))
(define (sample-cases-of slot v) (for/list ([c (in-list (cases slot v))] [k (in-naturals)] #:when (sample-case? k)) c))
(define (held-cases-of slot v) (for/list ([c (in-list (cases slot v))] [k (in-naturals)] #:unless (sample-case? k)) c))

;; ---- the contract ------------------------------------------------------------------------------------
;; Its first paragraph is the protocol's, word for word; the details say how each of its terms is
;; read. The author of the tasks, the agent that checks them and both arms are given this text.
(define contract-text #<<TEXT
# The contract

The operation is called by `POST /$<code>` with a FHIR Parameters resource as JSON. A request that
conforms is answered 200 with a Parameters resource holding exactly the outputs the definition
declares, each of its declared type, with the values the statement gives. A request that does not
conform is answered with a 4xx status and an OperationOutcome; it does not conform when a required
input is missing, an input is given more times than its maximum, an input's value is of another
type than declared, a code is outside a binding the definition requires, or a value breaks a rule
the statement states. Not tested, because FHIR leaves them to the server: an integer where a
decimal is declared (and the reverse for a whole number), an input the definition does not name,
GET.

## Details

- `<code>` is the definition's `code`. The definition is OperationDefinition.json; the statement
  is STATEMENT.md.
- A request's body is `{"resourceType": "Parameters", "parameter": [{"name": "...", "value<Type>": ...}, ...]}`,
  sent with `Content-Type: application/fhir+json`. Every test request is well-formed JSON of that
  shape.
- An input's value is of its declared type when its key is `value` and the type's name with a
  capital letter: `valueDecimal` for decimal, `valueInteger` for integer, `valueBoolean`,
  `valueCode`, `valueString`, `valueDate`, `valueQuantity`. Under any other key it is of another
  type (`valueString` where a decimal is declared). The JSON value under a key is always one that
  FHIR writes that type as.
- An answer to a conforming request: status 200 and
  `{"resourceType": "Parameters", "parameter": [...]}` with one entry for each output value, its
  key naming the output's declared type. An optional output is there when the statement says so.
  A number is right within half a unit of the last decimal place the statement rounds it to; a
  string, a code and a boolean exactly; a Quantity by its `value`, `system` and `code`.
- An answer to a request that does not conform: a status from 400 to 499 and
  `{"resourceType": "OperationOutcome", "issue": [...]}`. What the issues say is not compared.

TEXT
  )

;; ---- an implementer's directory and prompt -----------------------------------------------------------
;; start-command : Arm -> (listof string)   how the arm's server is started; "{port}" is the port
(define (start-command arm)
  (case arm
    [(L) '("raco" "fhir-server" "serve" "server.capability.rkt" "--port" "{port}")]
    [(G) '("python3" "server.py" "{port}")]))

;; guide-text : -> string   the capability language's guide, as the toolkit ships it
(define (guide-text)
  (define out (open-output-string))
  (unless (parameterize ([current-output-port out] [current-error-port (open-output-nowhere)])
            (system* (find-executable-path "raco") "fhir" "guide" "capability"))
    (error 'guide-text "raco fhir guide capability failed"))
  (get-output-string out))

;; given-names : what a stage's directory is given, and what a run leaves there that is not the
;; implementation
(define given-names
  '("OperationDefinition.json" "STATEMENT.md" "CONTRACT.md" "CHANGE.md" "GUIDE.md" "try.py" "start.json"
    "examples" "previous" "record.json" "answer.json" "AUDIT" "compiled" "__pycache__" "server.log" "score.json"))
(define (given? name)
  (or (member name given-names) (regexp-match? #rx"[.](db|db-wal|db-shm|log|pyc)$" name) (regexp-match? #rx"^[.]" name)))

;; implementation-files : dir -> (listof path)   the files an implementer wrote, relative, in order
(define (implementation-files dir)
  (define (under d rel)
    (append*
     (for/list ([n (in-list (sort (map path->string (directory-list d)) string<?))] #:unless (given? n))
       (define p (build-path d n))
       (define r (if rel (build-path rel n) (string->path n)))
       (cond [(directory-exists? p) (under p r)] [(file-exists? p) (list r)] [else '()]))))
  (if (directory-exists? dir) (under dir #f) '()))

;; prepare-stage! : Slot Arm Version dir (or/c #f dir) -> void   an implementer's directory for a
;; version: the definition, the statement, the contract, the examples (requests alone), the
;; script that tries them; for a version after the first, what the stage before left and what
;; changed
(define (prepare-stage! slot arm v dir before)
  (make-directory* dir)
  (when before
    (for ([f (in-list (implementation-files before))])
      (make-directory* (let-values ([(parent _n _d) (split-path (build-path dir f))]) parent))
      (copy-file (build-path before f) (build-path dir f) #t)))
  (define (put name text) (display-to-file text (build-path dir name) #:exists 'truncate))
  (define (json-text j) (with-output-to-string (lambda () (write-json j))))
  (copy-file (build-path (version-dir slot v) "OperationDefinition.json") (build-path dir "OperationDefinition.json") #t)
  (put "STATEMENT.md" (statement slot v))
  (put "CONTRACT.md" contract-text)
  (when (> v 1)
    (make-directory* (build-path dir "previous"))
    (copy-file (build-path (version-dir slot (sub1 v)) "OperationDefinition.json")
               (build-path dir "previous" "OperationDefinition.json") #t)
    (display-to-file (statement slot (sub1 v)) (build-path dir "previous" "STATEMENT.md") #:exists 'truncate)
    (put "CHANGE.md" (change-text slot v)))
  (when (eq? arm 'L) (put "GUIDE.md" (guide-text)))
  (copy-file try-script (build-path dir "try.py") #t)
  (put "start.json" (json-text (hasheq 'command (start-command arm) 'code (operation-code slot v))))
  (make-directory* (build-path dir "examples"))
  (for ([c (in-list (sample-cases-of slot v))])
    (display-to-file (json-text (hash-ref c 'request))
                     (build-path dir "examples" (format "~a.json" (hash-ref c 'id))) #:exists 'truncate)))

;; task-prompt : Arm Version -> string   the same for both arms but for the sentences naming the
;; route, and the same for every operation
(define (task-prompt arm v)
  (define route
    (case arm
      [(L) (string-append
            "The server is written in this toolkit's capability language, as the file server.capability.rkt. "
            "GUIDE.md is the language's guide; `raco fhir-server check server.capability.rkt` says whether the file compiles. "
            "It is started with `raco fhir-server serve server.capability.rkt --port <port>`.")]
      [(G) (string-append
            "The server is written in Python 3 with the standard library only, as the file server.py (and any other files you like). "
            "It is started with `python3 server.py <port>`.")]))
  (define files
    (string-append
     "- OperationDefinition.json: the operation's published definition\n"
     "- STATEMENT.md: what the operation computes, and the rules its inputs must meet\n"
     "- CONTRACT.md: how the operation is called and what a server answers. Read it first.\n"
     (if (> v 1)
         "- CHANGE.md: what changed in the definition; previous/ holds the definition and the statement before the change\n"
         "")
     (if (eq? arm 'L) "- GUIDE.md: the capability language\n" "")
     "- examples/: a few requests, without their expected answers\n"
     "- try.py: `python3 try.py` starts the server, sends it the examples and prints what it answers\n\n"))
  (string-append
   (if (= v 1)
       "You are implementing a FHIR operation as a small HTTP server.\n\n"
       "This directory holds a small HTTP server that implements a FHIR operation, written some time ago. The operation's definition has changed, and you are bringing the server up to it.\n\n")
   route "\n\n"
   "In this directory:\n" files
   (if (= v 1)
       "Write the server. "
       "Change the server so that it implements the new definition and statement. ")
   "It will be sent many other requests than the examples, some that conform to the definition and some that do not, "
   "and judged by whether it answers each as the contract says"
   (if (= v 1) "." " under the new definition.")
   "\n\nUse only this directory. Read nothing outside it, not the source of any installed software either: what you are given "
   "is the documentation there is. No network beyond your own server on 127.0.0.1, no packages to install. "
   "When the server answers the examples as it should, end with one short line."))

(module+ test
  (require rackunit)
  ;; the two arms' prompts differ in the sentences naming the route and the guide's line alone
  (define (without-route p)
    (regexp-replaces p '((#rx"The server is written in [^\n]*\n" "") (#rx"- GUIDE.md[^\n]*\n" ""))))
  (for ([v (in-list versions)])
    (check-equal? (without-route (task-prompt 'L v)) (without-route (task-prompt 'G v))))
  (check-regexp-match #rx"CHANGE.md" (task-prompt 'G 2))
  (check-false (regexp-match? #rx"CHANGE.md" (task-prompt 'G 1)))
  (check-equal? (map sample-case? '(0 1 4 5 10)) '(#t #f #f #t #t))
  ;; an implementer's files are what it wrote, not what it was given or what a run leaves
  (define dir (make-temporary-file "definition-first-~a" 'directory))
  (for ([n (in-list '("server.py" "OperationDefinition.json" "try.py" "server.log" "fhir.db" ".hidden"))])
    (display-to-file "x" (build-path dir n)))
  (make-directory* (build-path dir "lib")) (display-to-file "y" (build-path dir "lib" "rules.py"))
  (make-directory* (build-path dir "compiled")) (display-to-file "z" (build-path dir "compiled" "a.zo"))
  (make-directory* (build-path dir "examples")) (display-to-file "{}" (build-path dir "examples" "c01.json"))
  (check-equal? (map path->string (implementation-files dir)) '("lib/rules.py" "server.py"))
  (delete-directory/files dir)
  ;; the tasks, where there are some: every version has its definition, statement and cases, a
  ;; fifth of them examples
  (for* ([s (in-list (slots))] [v (in-list versions)])
    (check-true (string? (operation-code s v)))
    (check-true (> (string-length (statement s v)) 200))
    (when (> v 1) (check-true (> (string-length (change-text s v)) 20)))
    (define cs (cases s v))
    (check-true (>= (length cs) 20) (format "~a v~a has ~a cases" s v (length cs)))
    (check-equal? (+ (length (sample-cases-of s v)) (length (held-cases-of s v))) (length cs))
    (for ([c (in-list cs)])
      (check-equal? (hash-ref (hash-ref c 'request) 'resourceType) "Parameters")
      (check-not-false (member (hash-ref (hash-ref c 'expect) 'status) '(200 "4xx"))))))
