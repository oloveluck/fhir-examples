#lang racket/base

;;; mab.rkt — the agent's two MedAgentBench actions besides reading (installed beside the agent as the
;;; executable `mab`): a POST, recorded and not sent — as in the benchmark, whose harness answers "POST
;;; request accepted" without executing it — and FINISH.
;;;
;;;   ./mab post <url> payload.json        record a POST of the JSON payload in that file to that url
;;;   ./mab post <url>  < payload.json     (or on stdin)
;;;   ./mab post <url> payload.fsh         the payload written as one FSH Instance (FHIR R4): compiled
;;;                                        (`raco fsh`), its problems said at their lines, then recorded
;;;   ./mab finish '<JSON list>'           the answers, as FINISH([answer1, ...]); ends the task
;;;
;;; posts.jsonl gets one {"url", "payload"} line per POST; answer.json gets {"finish": "<the text>"}.

(require racket/port racket/string racket/file racket/system json)

(provide main post! finish!)

(define usage
  (string-append "usage: ./mab post <url> [payload.json]   (the payload on stdin when no file is given)\n"
                 "       ./mab finish '<JSON list>'          e.g. ./mab finish '[\"S1234567\"]'\n"))

;; json-text? : string -> jsexpr | #f
(define (read-json-text s) (with-handlers ([exn:fail? (lambda (_) #f)]) (string->jsexpr s)))

;; fsh-payload : file fail -> jsexpr   the one resource an FSH file's Instance compiles to (R4), or
;; the compiler's own problems, at their lines
(define (fsh-payload file fail)
  (define out (make-temporary-directory "mab-fsh-~a"))
  (define msgs (open-output-string))
  (define ok? (parameterize ([current-output-port msgs] [current-error-port msgs])
                (system* (find-executable-path "raco") "fsh" "--fhir-version" "4.0.1" (path->string (path->complete-path file))
                         "-o" (path->string out))))
  (define files (if (directory-exists? out) (filter (lambda (f) (regexp-match? #rx"[.]json$" (path->string f))) (directory-list out #:build? #t)) '()))
  (define resources (for/list ([f (in-list files)]) (call-with-input-file f read-json)))
  (delete-directory/files out #:must-exist? #f)
  (cond [(not ok?) (fail "Invalid POST request: the FSH does not compile:\n~a" (string-trim (get-output-string msgs)))]
        [(not (= (length resources) 1)) (fail "Invalid POST request: ~a holds ~a instances; a POST is one resource" file (length resources))]
        ;; a create: the server gives the id (the Instance name is FSH's, not the record's)
        [else (hash-remove (car resources) (quote id))]))

;; record-post! : dir url jsexpr -> string   one {"url", "payload"} line added to dir's posts.jsonl
(define (record-post! here url payload)
  (call-with-output-file (build-path here "posts.jsonl") #:exists 'append
    (lambda (o) (write-string (jsexpr->string (hasheq 'url url 'payload payload)) o) (newline o)))
  "POST request accepted and executed successfully.")

;; post! : dir url (or jsexpr #f) (or string #f) (format-string any ... -> any) -> string
;; a POST recorded in `here`: `payload` the resource as JSON, or `fsh` one FSH Instance (compiled
;; for FHIR R4, the id it would give left out). What is wrong with either goes to `fail`, which
;; does not return.
(define (post! here url payload fsh fail)
  (define resource
    (cond [fsh
           (define file (make-temporary-file "mab-post-~a.fsh"))
           (display-to-file fsh file #:exists 'truncate)
           (begin0 (fsh-payload file (lambda (fmt . vs) (delete-file file) (apply fail fmt vs)))
                   (when (file-exists? file) (delete-file file)))]
          [else payload]))
  (unless (hash? resource) (fail "Invalid POST request: the payload is not a JSON object"))
  (record-post! here url resource))

;; finish! : dir string (format-string any ... -> any) -> string   the answers — a JSON list, as
;; text — written to dir's answer.json as {"finish": text}
(define (finish! here text fail)
  (unless (list? (read-json-text text))
    (fail "FINISH needs a JSON list, e.g. [\"S1234567\"]"))
  (call-with-output-file (build-path here "answer.json") #:exists 'truncate
    (lambda (o) (write-json (hasheq 'finish text) o)))
  "Finished.")

(define (main args)
  (define here (current-directory))
  (define (fail fmt . vs) (apply printf fmt vs) (newline) (exit 1))
  (cond
    [(and (member (length args) '(2 3)) (equal? (car args) "post"))
     (define fsh? (and (= (length args) 3) (regexp-match? #rx"[.]fsh$" (caddr args))))
     (define text (if (= (length args) 3)
                      (with-handlers ([exn:fail? (lambda (e) (fail "Invalid POST request: cannot read ~a" (caddr args)))])
                        (call-with-input-file (caddr args) port->string))
                      (port->string (current-input-port))))
     (define payload (if fsh? (fsh-payload (caddr args) fail) (read-json-text text)))
     (unless (hash? payload) (fail "Invalid POST request: the payload is not a JSON object"))
     (displayln (record-post! here (cadr args) payload))]
    [(and (= (length args) 2) (equal? (car args) "finish"))
     (define text (string-trim (cadr args)))
     (unless (list? (read-json-text text))
       (fail "FINISH needs a JSON list, e.g. ./mab finish '[\"S1234567\"]'"))
     (displayln (finish! here text fail))]
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
    (check-equal? (with-handlers ([number? values]) (main '("finish" "S1"))) 1)
    ;; the same two actions as procedures (the tools of mab/tools-server.rkt)
    (define (refuse fmt . vs) (raise (apply format fmt vs)))
    (check-equal? (post! dir "http://x/fhir/MedicationRequest" (hasheq 'resourceType "MedicationRequest") #f refuse)
                  "POST request accepted and executed successfully.")
    (check-equal? (string->jsexpr (cadr (file->lines "posts.jsonl")))
                  (hasheq 'url "http://x/fhir/MedicationRequest" 'payload (hasheq 'resourceType "MedicationRequest")))
    (check-regexp-match #rx"not a JSON object" (with-handlers ([string? values]) (post! dir "http://x" '(1) #f refuse)))
    (check-equal? (finish! dir "[4.2]" refuse) "Finished.")
    (check-equal? (hash-ref (call-with-input-file "answer.json" read-json) 'finish) "[4.2]")
    (check-regexp-match #rx"needs a JSON list" (with-handlers ([string? values]) (finish! dir "4.2" refuse))))
  (delete-directory/files dir))
