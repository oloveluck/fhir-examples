#lang racket/base

;;; tools-server.rkt — a MedAgentBench task's actions as the tools of one process.
;;;
;;;   racket -l- fhir-examples/agent-bench/mab/tools-server [DIR]
;;;
;;; A Model Context Protocol server (../tool-server.rkt) over the task's workspace DIR (the current
;;; directory when none is given), whose data is the benchmark's records. Three tools:
;;;
;;;   query     the workspace's `query` verb, for the three languages a task reads with (FHIR
;;;             search, find, SQL over earlier results)
;;;   post      {url, payload | fsh}   a POST, recorded and not sent (mab.rkt's `post!`): the
;;;             resource as a JSON object, or as one FSH Instance, compiled
;;;   finish    {answers}              FINISH([…]): the answers written (mab.rkt's `finish!`)
;;;
;;; The `workspace` arm does the same from a shell: `raco fhir-mcp call …` and `./mab post|finish`.
;;; There every call of the model carries the shell tool's definition and the runtime's own
;;; system prompt, a payload has to be written to a file first (two more calls), and when the
;;; answers are given the agent is asked once more, only to say it is done. Here a session ends
;;; when `finish` answers "Finished." (stop-when-finished.sh, a hook of the agent runtime).

(require racket/list racket/promise racket/string json
         "../tool-server.rkt"
         (only-in "mab.rkt" post! finish!))

(provide mab-tools action-tools reading-tools)

;; refuse : format-string any ... -> none   what the caller got wrong, answered as the tool's error
(define (refuse fmt . vs) (raise-user-error (apply format fmt vs)))

;; action-tools : dir -> (listof Tool)   post and finish, over the task's directory
(define (action-tools dir)
  (define text (hasheq 'type "string"))
  (define held (box #f))   ; the answers last held back, as text
  (list
   (tool "post"
         "A POST, recorded and not sent: `url` and the resource — as a JSON object (`payload`), or as one FSH Instance (`fsh`, FHIR R4), which is compiled and its problems said at their lines."
         (hasheq 'type "object" 'required '("url")
                 'properties (hasheq 'url text 'payload (hasheq 'type "object") 'fsh text))
         (lambda (args)
           (define url (hash-ref args 'url #f))
           (unless (and (string? url) (non-empty-string? (string-trim url))) (refuse "`url` is required"))
           (define fsh (let ([f (hash-ref args 'fsh #f)]) (and (string? f) (non-empty-string? (string-trim f)) f)))
           (define payload (let ([p (hash-ref args 'payload #f)])
                             ;; a client may send the object as its JSON text
                             (if (string? p) (with-handlers ([exn:fail? (lambda (_) p)]) (string->jsexpr p)) p)))
           (unless (or fsh payload) (refuse "Invalid POST request: give the resource as `payload` (a JSON object) or as `fsh`"))
           (post! dir url payload fsh refuse)))
   (tool "finish"
         "FINISH([answer1, answer2, …]): ends the task."
         (hasheq 'type "object" 'required '("answers")
                 'properties (hasheq 'answers (hasheq 'type "array"
                                                      'description "The list FINISH takes, as JSON: each answer a bare value — a measurement its number alone (`[123]`, not \"123 mg/dL\"), an identifier a string (`[\"S1234567\"]`) — with no unit, date or sentence. `[]` when the task asks for no answer.")))
         (lambda (args)
           (define answers (hash-ref args 'answers (lambda () (refuse "`answers` is required: a list, e.g. [\"S1234567\"]"))))
           (define text (if (string? answers) (string-trim answers) (jsexpr->string answers)))
           ;; a number written as a string is held once: the benchmark compares values, and "3.8"
           ;; is not 3.8; an identifier made of digits is given again and recorded
           (define quoted (quoted-numbers (if (string? answers) (with-handlers ([exn:fail? (lambda (_) '())]) (string->jsexpr text)) answers)))
           (when (and (pair? quoted) (not (equal? (unbox held) text)))
             (set-box! held text)
             (refuse "Not finished: ~a a number written as a string. Give a number as a number (~a, not \"~a\"). If it is an identifier, give the same answers once more and they are recorded."
                     (if (= (length quoted) 1) (format "\"~a\" is" (car quoted)) (format "~a are each" (string-join (map (lambda (q) (format "\"~a\"" q)) quoted) ", ")))
                     (string-trim (car quoted)) (car quoted)))
           (finish! dir text refuse)))))

;; quoted-numbers : jsexpr -> (listof string)   the strings of a list of answers that read as numbers
(define (quoted-numbers answers)
  (if (list? answers)
      (for/list ([a (in-list answers)] #:when (and (string? a) (regexp-match? #px"^\\s*-?[0-9]+([.][0-9]+)?\\s*$" a))) a)
      '()))

;; A Reader is ((hash symbol -> jsexpr) -> string): the workspace's `query` verb over the opened
;; workspace; it raises exn:fail:user with what the verb said was wrong.

;; open-reader : dir -> Reader   the toolkit loaded and the workspace opened (most of a second)
(define (open-reader dir)
  (define open-hub (dynamic-require 'fhir/mcp/workspace 'open-hub))
  (define with-hub (dynamic-require 'fhir/mcp/workspace 'with-hub))
  (define workspace-tools (dynamic-require 'fhir/mcp/verbs 'workspace-tools))
  (define tool->jsexpr (dynamic-require 'fhir/mcp/tools 'tool->jsexpr))
  (define call-tool (dynamic-require 'fhir/mcp/tools 'call-tool))
  (define h (parameterize ([current-directory dir]) (open-hub dir)))
  (define query (findf (lambda (t) (equal? (hash-ref (tool->jsexpr t) 'name) "query")) (workspace-tools h)))
  (lambda (args)
    (define-values (answered error?)
      (parameterize ([current-directory dir]) (with-hub h (lambda () (call-tool query args)))))
    (if error? (raise-user-error answered) answered)))

;; reading-languages : the languages of the workspace's `query` verb this arm offers. The verb
;; has seven; a task here reads the records, and every word of a definition is in every call.
(define reading-languages '("search" "find" "sql"))

;; reading-tools : (promise-of Reader) -> (listof Tool)   `query`, the workspace's verb of that
;; name, defined here in the words fhir-mcp defines it with — so the server can say its tools
;; before the toolkit is loaded (0.2 s where loading it first took 0.7, which the agent's first
;; call of the model waited for)
(define (reading-tools reader)
  (list
   (tool "query"
         "Read the records. language: search (a FHIR search, `Type?name=value…`: a page of rows saying what each resource holds, `total` every match; `_sort=-date`, `_count`, `_offset`, `_summary=count`; `code:text=words`), find (words: where they occur — codes by name, identifiers, names — and the search for each), sql (one SELECT over earlier results by name: r1, r2 …)."
         (hasheq 'type "object" 'required '("language" "text")
                 'properties (hasheq 'language (hasheq 'type "string" 'enum reading-languages)
                                     'text (hasheq 'type "string" 'description "the search, the words or the SQL statement")))
         (lambda (args)
           (unless (member (hash-ref args 'language #f) reading-languages)
             (refuse "`language` is one of: ~a" (string-join reading-languages ", ")))
           ((force reader) args)))))

;; mab-tools : dir (promise-of Reader) -> (listof Tool)
(define (mab-tools dir reader) (append (reading-tools reader) (action-tools dir)))

(module+ main
  (define dir (path->complete-path (let ([args (current-command-line-arguments)])
                                     (if (zero? (vector-length args)) (current-directory) (vector-ref args 0)))))
  ;; opened while the client is still starting and the model reading: the first `query` waits for it
  (define reader (delay/thread (open-reader dir)))
  (serve-tools (mab-tools dir reader) "mab"))

(module+ test
  (require rackunit racket/file)
  (define dir (make-temporary-file "mab-tools-~a" 'directory))
  (define tools (action-tools dir))
  (define (call name args) ((tool-run (findf (lambda (t) (equal? (tool-name t) name)) tools)) args))
  (define (refusal thunk) (with-handlers ([exn:fail:user? exn-message]) (thunk) #f))
  ;; a POST as an object, and as the object's text
  (check-equal? (call "post" (hasheq 'url "http://x/fhir/Observation" 'payload (hasheq 'resourceType "Observation" 'status "final")))
                "POST request accepted and executed successfully.")
  (check-equal? (call "post" (hasheq 'url "http://x/fhir/ServiceRequest" 'payload "{\"resourceType\": \"ServiceRequest\"}"))
                "POST request accepted and executed successfully.")
  (check-equal? (map string->jsexpr (file->lines (build-path dir "posts.jsonl")))
                (list (hasheq 'url "http://x/fhir/Observation" 'payload (hasheq 'resourceType "Observation" 'status "final"))
                      (hasheq 'url "http://x/fhir/ServiceRequest" 'payload (hasheq 'resourceType "ServiceRequest"))))
  (check-regexp-match #rx"`url` is required" (refusal (lambda () (call "post" (hasheq 'payload (hasheq))))))
  (check-regexp-match #rx"give the resource as `payload`" (refusal (lambda () (call "post" (hasheq 'url "http://x")))))
  (check-regexp-match #rx"not a JSON object" (refusal (lambda () (call "post" (hasheq 'url "http://x" 'payload "not json")))))
  ;; FINISH: the list as JSON text, as the benchmark's grader loads it
  (check-equal? (call "finish" (hasheq 'answers (list "S1234567" 4.2 -1))) "Finished.")
  (check-equal? (string->jsexpr (hash-ref (call-with-input-file (build-path dir "answer.json") read-json) 'finish)) (list "S1234567" 4.2 -1))
  (check-equal? (call "finish" (hasheq 'answers "[\"S1\"]")) "Finished.")
  (check-equal? (hash-ref (call-with-input-file (build-path dir "answer.json") read-json) 'finish) "[\"S1\"]")
  (check-regexp-match #rx"needs a JSON list" (refusal (lambda () (call "finish" (hasheq 'answers "S1")))))
  ;; a number as a string is held once, and recorded when given again
  (check-regexp-match #rx"\"3.8\" is a number written as a string. Give a number as a number [(]3.8, not \"3.8\"[)]"
                      (refusal (lambda () (call "finish" (hasheq 'answers (list "3.8"))))))
  (check-equal? (hash-ref (call-with-input-file (build-path dir "answer.json") read-json) 'finish) "[\"S1\"]" "nothing recorded while held")
  (check-equal? (call "finish" (hasheq 'answers (list 3.8))) "Finished.")
  (check-regexp-match #rx"written as a string" (refusal (lambda () (call "finish" (hasheq 'answers (list "1234567"))))))
  (check-equal? (call "finish" (hasheq 'answers (list "1234567"))) "Finished.")
  (check-equal? (hash-ref (call-with-input-file (build-path dir "answer.json") read-json) 'finish) "[\"1234567\"]")
  (check-equal? (quoted-numbers (list "S1" "-4" " 2.50 " 7 "1e3" "")) '("-4" " 2.50 "))
  (check-regexp-match #rx"`answers` is required" (refusal (lambda () (call "finish" (hasheq)))))
  ;; `query`: defined before the toolkit is loaded, asked of the reader only when called
  (let* ([asked '()]
         [reader (delay (lambda (args) (set! asked (cons args asked)) "rows"))]
         [query (car (reading-tools reader))])
    (check-equal? (tool-name query) "query")
    (check-equal? (hash-ref (hash-ref (hash-ref (tool-schema query) 'properties) 'language) 'enum) '("search" "find" "sql"))
    (check-false (promise-forced? reader) "defining the tool opens nothing")
    (check-equal? ((tool-run query) (hasheq 'language "search" 'text "Patient?identifier=S1")) "rows")
    (check-equal? asked (list (hasheq 'language "search" 'text "Patient?identifier=S1")))
    (check-regexp-match #rx"`language` is one of: search, find, sql"
                        (refusal (lambda () ((tool-run query) (hasheq 'language "cql" 'text "1")))))
    (check-equal? (map tool-name (mab-tools dir reader)) '("query" "post" "finish")))
  (delete-directory/files dir))
