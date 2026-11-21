#lang racket/base

;;; tools-server.rkt — a MedAgentBench task's four actions as the tools of one process.
;;;
;;;   racket -l- fhir-examples/agent-bench/mab/tools-server [DIR]
;;;
;;; A Model Context Protocol server (../tool-server.rkt) over the task's workspace DIR (the current
;;; directory when none is given), whose data is the benchmark's records:
;;;
;;;   query     the workspace's `query` verb (FHIR search, find, SQL), as fhir-mcp defines it
;;;   describe  the workspace's `describe` verb (a resource, a result, the data's census)
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

(provide mab-tools action-tools)

;; refuse : format-string any ... -> none   what the caller got wrong, answered as the tool's error
(define (refuse fmt . vs) (raise-user-error (apply format fmt vs)))

;; action-tools : dir -> (listof Tool)   post and finish, over the task's directory
(define (action-tools dir)
  (define text (hasheq 'type "string"))
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
           (finish! dir (if (string? answers) (string-trim answers) (jsexpr->string answers)) refuse)))))

;; reading-tools : dir (listof string) -> (listof Tool)   the workspace's verbs of those names,
;; as fhir-mcp defines them, over the workspace in dir (opened here: most of a second)
(define (reading-tools dir names)
  (define open-hub (dynamic-require 'fhir/mcp/workspace 'open-hub))
  (define with-hub (dynamic-require 'fhir/mcp/workspace 'with-hub))
  (define workspace-tools (dynamic-require 'fhir/mcp/verbs 'workspace-tools))
  (define tool->jsexpr (dynamic-require 'fhir/mcp/tools 'tool->jsexpr))
  (define call-tool (dynamic-require 'fhir/mcp/tools 'call-tool))
  (define h (parameterize ([current-directory dir]) (open-hub dir)))
  (for*/list ([t (in-list (workspace-tools h))]
              [j (in-value (tool->jsexpr t))]
              #:when (member (hash-ref j 'name) names))
    (tool (hash-ref j 'name) (hash-ref j 'description) (hash-ref j 'inputSchema)
          (lambda (args)
            (define-values (answered error?)
              (parameterize ([current-directory dir]) (with-hub h (lambda () (call-tool t args)))))
            (if error? (raise-user-error answered) answered)))))

;; mab-tools : dir -> (listof Tool)
(define (mab-tools dir) (append (reading-tools dir '("query" "describe")) (action-tools dir)))

(module+ main
  (define dir (path->complete-path (let ([args (current-command-line-arguments)])
                                     (if (zero? (vector-length args)) (current-directory) (vector-ref args 0)))))
  (serve-tools (mab-tools dir) "mab"))

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
  (check-regexp-match #rx"`answers` is required" (refusal (lambda () (call "finish" (hasheq)))))
  (delete-directory/files dir))
