#lang racket/base

;;; mab.rkt — the agent's two MedAgentBench actions besides reading (installed beside the agent as the
;;; executable `mab`): a POST, recorded and not sent — as in the benchmark, whose harness answers "POST
;;; request accepted" without executing it — and FINISH.
;;;
;;;   ./mab post <url> payload.json        record a POST of the JSON payload in that file to that url
;;;   ./mab post <url>  < payload.json     (or on stdin)
;;;   ./mab finish '<JSON list>'           the answers, as FINISH([answer1, ...]); ends the task
;;;
;;; posts.jsonl gets one {"url", "payload"} line per POST; answer.json gets {"finish": "<the text>"}.

(require racket/port racket/string json)

(provide main)

(define usage
  (string-append "usage: ./mab post <url> [payload.json]   (the payload on stdin when no file is given)\n"
                 "       ./mab finish '<JSON list>'          e.g. ./mab finish '[\"S1234567\"]'\n"))

;; json-text? : string -> jsexpr | #f
(define (read-json-text s) (with-handlers ([exn:fail? (lambda (_) #f)]) (string->jsexpr s)))

(define (main args)
  (define here (current-directory))
  (define (append-line file s)
    (call-with-output-file (build-path here file) #:exists 'append (lambda (o) (write-string s o) (newline o))))
  (define (fail fmt . vs) (apply printf fmt vs) (newline) (exit 1))
  (cond
    [(and (member (length args) '(2 3)) (equal? (car args) "post"))
     (define text (if (= (length args) 3)
                      (with-handlers ([exn:fail? (lambda (e) (fail "Invalid POST request: cannot read ~a" (caddr args)))])
                        (call-with-input-file (caddr args) port->string))
                      (port->string (current-input-port))))
     (define payload (read-json-text text))
     (unless (hash? payload) (fail "Invalid POST request: the payload is not a JSON object"))
     (append-line "posts.jsonl" (jsexpr->string (hasheq 'url (cadr args) 'payload payload)))
     (displayln "POST request accepted and executed successfully.")]
    [(and (= (length args) 2) (equal? (car args) "finish"))
     (define text (string-trim (cadr args)))
     (unless (list? (read-json-text text))
       (fail "FINISH needs a JSON list, e.g. ./mab finish '[\"S1234567\"]'"))
     (call-with-output-file (build-path here "answer.json") #:exists 'truncate
       (lambda (o) (write-json (hasheq 'finish text) o)))
     (displayln "Finished.")]
    [else (display usage) (exit 2)]))

(module+ main (main (vector->list (current-command-line-arguments))))

(module+ test
  (require rackunit racket/file)
  (define dir (make-temporary-directory))
  (parameterize ([current-directory dir] [current-output-port (open-output-nowhere)]
                 [exit-handler (lambda (c) (raise c))])
    (call-with-output-file "p.json" (lambda (o) (write-string "{\"resourceType\": \"Observation\"}" o)))
    (main '("post" "http://x/fhir/Observation" "p.json"))
    (main '("finish" "[\"S1\", 3]"))
    (check-equal? (string->jsexpr (file->string "posts.jsonl"))
                  (hasheq 'url "http://x/fhir/Observation" 'payload (hasheq 'resourceType "Observation")))
    (check-equal? (hash-ref (call-with-input-file "answer.json" read-json) 'finish) "[\"S1\", 3]")
    (check-equal? (with-handlers ([number? values]) (main '("finish" "S1"))) 1))
  (delete-directory/files dir))
