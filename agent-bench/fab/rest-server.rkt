#lang racket/base

;;; rest-server.rkt — the general route's tools: a FHIR REST server and Python, and nothing else.
;;;
;;;   racket rest-server.rkt WORK_DIR FHIR_BASE [PREPARED_DIR]
;;;   racket rest-server.rkt WORK_DIR -            `python` and `answer` alone (arm `mcp-tools`: the
;;;                                                data is reached through the toolkit's own tools)
;;;
;;; The arm `rest-tools` of run.rkt (value-experiment/PROTOCOL.md, experiment A1). It is the
;;; harness of the tables arm with the other route behind it: the agent's actions are the three
;;; tools of one process (tool-server.rkt), it has no shell, and its session ends when `answer`
;;; has written the answer. What differs is only how the data is reached:
;;;
;;;   get     one GET of the FHIR server, the body as it came (cut at `get-limit` characters)
;;;   python  a Python 3 program run in the question's directory; FHIR_BASE is the server; what
;;;           it prints comes back (cut at `python-limit`); PREPARED, when the arm was prepared,
;;;           is the directory its preparing agent left (notes, a library on the path)
;;;   answer  the answer and the resources it rests on, written to answer.json
;;;
;;; Nothing of the toolkit is loaded: the server reads the data over HTTP as any client does.

(require racket/list racket/string racket/file racket/port json
         (only-in net/http-client http-sendrecv)
         (only-in net/url string->url url-host url-port url-path path/param-path)
         "../tool-server.rkt")

(provide rest-tools get-limit python-limit cut base-request)

;; how much of a body, and of a program's output, a call answers: a page of a search is tens of
;; thousands of characters, and every call of the model re-reads what the calls before returned
(define get-limit 20000)
(define python-limit 20000)
(define python-seconds 120)

;; cut : string natural string -> string   the text, or its first `limit` characters and a line
;; saying how much there was and what to do about it
(define (cut text limit advice)
  (if (<= (string-length text) limit)
      text
      (string-append (substring text 0 limit)
                     (format "\n… cut here: ~a characters of ~a shown. ~a" limit (string-length text) advice))))

;; base-request : string string -> (values host port path)   where a GET of `target` under the
;; server's base goes. `target` is what follows the base (`Observation?patient=…`, with or
;; without a leading slash), or a whole url of the same server (a Bundle's `next` link).
(define (base-request base target)
  (define u (string->url base))
  (define prefix (string-join (map path/param-path (url-path u)) "/"))
  (define rest
    (cond [(regexp-match #rx"^https?://[^/]+(/.*)$" target) => cadr]
          [(regexp-match? #rx"^/" target) (string-append (if (string=? prefix "") "" (string-append "/" prefix)) target)]
          [else (string-append (if (string=? prefix "") "" (string-append "/" prefix)) "/" target)]))
  (values (url-host u) (or (url-port u) 80) (string-replace rest " " "%20")))

;; get-text : string string -> string   the GET's status when it is not 200, and its body
(define (get-text base target)
  (define-values (host port path) (base-request base target))
  (define-values (status _headers in)
    (http-sendrecv host path #:port port #:headers '("Accept: application/fhir+json")))
  (define body (port->string in))
  (close-input-port in)
  (define code (cond [(regexp-match #rx#"^HTTP/[0-9.]+ ([0-9]+)" status) => (lambda (m) (bytes->string/utf-8 (cadr m)))] [else "?"]))
  (string-append (if (equal? code "200") "" (format "HTTP ~a\n" code))
                 (cut body get-limit "Ask for less (_count, _summary=count, a narrower search), or fetch it in `python` and print what you need.")))

;; forbidden : (listof string)   what a program may not name: the benchmark's own files
(define forbidden '("FHIR-AgentBench" "final_dataset" "questions_answers" "valid-150" "test-150" "agent_results"))

;; run-python : dir string string (or/c #f string) -> string   the program's output and errors
(define (run-python work base prepared code)
  (for ([f (in-list forbidden)])
    (when (string-contains? code f) (error 'python "a program may read the FHIR server and its own directory only")))
  (define file (build-path work (format "program-~a.py" (current-milliseconds))))
  (display-to-file code file #:exists 'truncate)
  (define out-file (build-path work "program.out"))
  (define python (or (find-executable-path "python3") (error 'python "python3 is not installed")))
  (define env (environment-variables-copy (current-environment-variables)))
  (when base (environment-variables-set! env #"FHIR_BASE" (string->bytes/utf-8 base)))
  (when prepared
    (environment-variables-set! env #"PREPARED" (string->bytes/utf-8 prepared))
    (environment-variables-set! env #"PYTHONPATH" (string->bytes/utf-8 prepared)))
  (define out (open-output-file out-file #:exists 'truncate))
  (define-values (proc _o _i _e)
    (parameterize ([current-environment-variables env] [current-directory work])
      (subprocess out #f 'stdout python (path->string file))))
  (define finished (sync/timeout python-seconds proc))
  (unless finished (subprocess-kill proc #t))
  (close-output-port out)
  (define text (file->string out-file))
  (string-append
   (cut text python-limit "Print less: the rows or the numbers you need, not whole resources.")
   (cond [(not finished) (format "\n(stopped after ~a seconds)" python-seconds)]
         [(zero? (subprocess-status proc)) (if (string=? text "") "(the program printed nothing)" "")]
         [else (format "\n(exit status ~a)" (subprocess-status proc))])))

;; write-answer! : dir string (listof string) -> string
(define (write-answer! work answer resources)
  (define refs (filter (lambda (r) (and (string? r) (regexp-match? #rx"^[A-Za-z]+/[^/ ]+$" r))) resources))
  (define bad (remove* refs resources))
  (unless (null? bad)
    (error 'answer "each resource is written Type/id (Observation/abc): ~a" (string-join (map (lambda (b) (format "~s" b)) bad) ", ")))
  (call-with-output-file (build-path work "answer.json") #:exists 'truncate
    (lambda (o) (write-json (hasheq 'answer answer 'resources refs) o)))
  "done: the answer is written")

(define (need args key)
  (define v (hash-ref args key #f))
  (unless (and (string? v) (not (string=? (string-trim v) ""))) (error (string->symbol (symbol->string key)) "give `~a`" key))
  v)

;; rest-tools : dir (or/c #f string) (or/c #f string) -> (listof Tool)   with no base, the tools
;; that are the harness's own: `python` (which then reaches no server) and `answer`
(define (rest-tools work base prepared)
  (define (string-property description) (hasheq 'type "string" 'description description))
  (define tools (all-tools work base prepared string-property))
  (if base tools (cdr tools)))

(define (all-tools work base prepared string-property)
  (list
   (tool "get"
         "One GET of the FHIR R4 server: what follows its base url, e.g. `Observation?patient=Patient/<id>&code=<system>|<code>&_sort=-date&_count=5`, `Encounter/<id>`, `metadata`. Answers the body (a resource, or a Bundle with `total`, `entry` and a `next` link when it is a page)."
         (hasheq 'type "object" 'required '("url")
                 'properties (hasheq 'url (string-property "the path and query after the base url, or a `next` link whole")))
         (lambda (args) (get-text (or base (error 'get "there is no server")) (need args 'url))))
   (tool "python"
         (string-append "Run a Python 3 program (standard library only) and get what it prints."
                        (if base
                            " The environment variable FHIR_BASE is the server's base url: fetch with urllib, compute, print only what you need."
                            " It reaches no data: use it to compute over what your other tools returned.")
                        (if prepared " PREPARED is a directory of notes and modules prepared for these questions (it is on the module path): read its README first." ""))
         (hasheq 'type "object" 'required '("code")
                 'properties (hasheq 'code (string-property "the program")))
         (lambda (args) (run-python work base prepared (need args 'code))))
   (tool "answer"
         "Write your answer and the resources it rests on. Call it once, when you have the answer."
         (hasheq 'type "object" 'required '("answer" "resources")
                 'properties (hasheq 'answer (string-property "the answer: a value with its unit, a date-time, a name, a count, yes/no, or none")
                                     'resources (hasheq 'type "array" 'items (hasheq 'type "string")
                                                        'description "the resources the answer rests on, each as Type/id")))
         (lambda (args)
           (define resources (hash-ref args 'resources '()))
           (write-answer! work (need args 'answer) (if (list? resources) resources '()))))))

(module+ main
  (define args (vector->list (current-command-line-arguments)))
  (unless (<= 2 (length args) 3) (raise-user-error 'rest-server "rest-server.rkt WORK_DIR FHIR_BASE|- [PREPARED_DIR]"))
  (serve-tools (rest-tools (first args) (and (not (equal? (second args) "-")) (second args)) (and (= (length args) 3) (third args)))
               "rest"))

(module+ test
  (require rackunit)
  (check-equal? (cut "abc" 5 "x") "abc")
  (check-regexp-match #rx"^ab\n… cut here: 2 characters of 5 shown. Ask for less" (cut "abcde" 2 "Ask for less"))
  (define (request base target) (call-with-values (lambda () (base-request base target)) list))
  (check-equal? (request "http://localhost:8765" "Patient/a") '("localhost" 8765 "/Patient/a"))
  (check-equal? (request "http://localhost:8765/" "/Patient?name=a b") '("localhost" 8765 "/Patient?name=a%20b"))
  (check-equal? (request "http://h:1/fhir" "Observation?_count=1") '("h" 1 "/fhir/Observation?_count=1"))
  (check-equal? (request "http://h:1/fhir" "http://h:1/fhir/Observation?_offset=10") '("h" 1 "/fhir/Observation?_offset=10"))
  ;; the tools over a scratch directory: a program's output, its failure, the answer file
  (define work (make-temporary-file "rest-server-~a" 'directory))
  (define tools (rest-tools work "http://localhost:1" #f))
  (define (call name . kvs) ((tool-run (findf (lambda (t) (equal? (tool-name t) name)) tools)) (apply hasheq kvs)))
  (check-equal? (map tool-name tools) '("get" "python" "answer"))
  ;; without a server: the harness's own two tools, and a program is told it reaches no data
  (let ([own (rest-tools work #f #f)])
    (check-equal? (map tool-name own) '("python" "answer"))
    (check-regexp-match #rx"It reaches no data" (tool-description (car own)))
    (when (find-executable-path "python3")
      (check-equal? ((tool-run (car own)) (hasheq 'code "import os\nprint(os.environ.get('FHIR_BASE'))")) "None\n")))
  (when (find-executable-path "python3")
    (check-equal? (call "python" 'code "import os\nprint(os.environ['FHIR_BASE'])") "http://localhost:1\n")
    (check-regexp-match #rx"ZeroDivisionError.*\n[(]exit status 1[)]$" (call "python" 'code "print(1/0)"))
    (check-equal? (call "python" 'code "x = 1") "(the program printed nothing)")
    (check-exn #rx"its own directory only" (lambda () (call "python" 'code "open('/x/final_dataset/a.csv')"))))
  (check-exn #rx"give `code`" (lambda () (call "python")))
  (check-exn #rx"written Type/id" (lambda () (call "answer" 'answer "7" 'resources '("Observation/a" "the first one"))))
  (check-equal? (call "answer" 'answer "7 mg/dL" 'resources '("Observation/a" "Encounter/b")) "done: the answer is written")
  (check-equal? (call-with-input-file (build-path work "answer.json") read-json)
                (hasheq 'answer "7 mg/dL" 'resources '("Observation/a" "Encounter/b")))
  (delete-directory/files work))
