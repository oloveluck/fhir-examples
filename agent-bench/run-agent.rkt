#lang racket/base

;;; run-agent.rkt — one benchmark item, one fresh headless Claude Code agent, and what it cost.
;;;
;;; The agent starts in an empty directory of its own (no CLAUDE.md, no repository notes), gets the
;;; item's prompt and the arm's tools, and writes its answer to `answer.json` there. Recorded per item
;;; (record.json beside it): the answer, the agent's last message, tokens, cost, turns, wall time and
;;; every shell command it ran (read from its session transcript), so a run can be audited for reads of
;;; the benchmark's own answers.
;;;
;;; The agent is run through files, not pipes (model.rkt's rule: a `system` with string ports once hung
;;; for 90 minutes after the model exited), with its arguments passed directly — prompts are full of
;;; quotes — and its process group killed past the timeout.

(require racket/contract racket/file racket/list racket/string racket/port json)

;; A Record is a hasheq:
;;   id answer final_message status error seconds turns cost_usd input_tokens output_tokens
;;   session_id commands — the keys the reports read, as the JSON says them
(provide
 (contract-out
  ;; run-item : id prompt workdir model tools -> Record
  [run-item (->* (string? string? path-string? string? (listof string?))
                 (#:prepare (or/c #f (-> any)) #:timeout real? #:max-turns exact-positive-integer?
                  #:env (listof (cons/c string? string?)))
                 hash?)]
  ;; claude-turn : dir text model [session] -> (values reply session cost)   one turn of a conversation
  ;; with no tools (the model only writes text), resumed when a session is given
  [claude-turn (->* (path-string? string? string?) ((or/c #f string?)) (values string? string? real?))]
  ;; audit : Record (listof string) -> (listof string)   the commands that touched a forbidden path
  [audit (-> hash? (listof string?) (listof string?))]
  ;; in-parallel : k items (item -> result) -> (listof result)   k at a time (threads: each waits on a
  ;; process), results in the items' order
  [in-parallel (-> exact-positive-integer? list? (-> any/c any/c) list?)]
  [read-json-file (-> path-string? any/c)]
  [write-json-file (-> path-string? any/c void?)]))

(define disallowed '("Task" "Agent" "WebFetch" "WebSearch" "NotebookEdit"))
;; what the agent's environment must not carry over from this session
(define withheld '("CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD" "PLTADDONDIR" "FHIR_MCP_DAEMON"))

(define (in-parallel k items f)
  (define results (make-vector (length items) #f))
  (define work (make-channel))
  (define workers
    (for/list ([_ (in-range k)])
      (thread (lambda ()
                (let loop ()
                  (define job (channel-get work))
                  (when job
                    (vector-set! results (car job) (f (cdr job)))
                    (loop)))))))
  (for ([x (in-list items)] [i (in-naturals)]) (channel-put work (cons i x)))
  (for ([_ (in-list workers)]) (channel-put work #f))
  (for-each thread-wait workers)
  (vector->list results))

(define (read-json-file f) (call-with-input-file f read-json))
(define (write-json-file f v)
  (call-with-output-file f #:exists 'truncate (lambda (o) (write-json v o))))

(define (run-item id prompt workdir model tools
                  #:prepare [prepare #f] #:timeout [timeout 1200] #:max-turns [max-turns 60] #:env [env-extra '()])
  (define work (path->complete-path workdir))
  (when (directory-exists? work) (delete-directory/files work))
  (make-directory* work)
  (when prepare (prepare))
  (define-values (status seconds out err) (run-claude work prompt model tools timeout max-turns env-extra))
  (define meta (with-handlers ([exn:fail? (lambda (_) (hasheq))]) (string->jsexpr out)))
  (define answer (with-handlers ([exn:fail? (lambda (_) #f)]) (read-json-file (build-path work "answer.json"))))
  (define usage (if (hash? meta) (hash-ref meta 'usage (hasheq)) (hasheq)))
  (define (u k) (hash-ref usage k 0))
  (define session (and (hash? meta) (hash-ref meta 'session_id #f)))
  (define rec
    (hasheq 'id id
            'answer (or answer (json-null))
            'final_message (if (hash? meta) (hash-ref meta 'result (json-null)) (json-null))
            'status status
            'error (if (and (eqv? status 0) answer) (json-null)
                       (let ([e (if (string=? err "") "no answer.json" err)]) (substring e (max 0 (- (string-length e) 500)))))
            'seconds (/ (round (* 10 seconds)) 10.0)
            'turns (if (hash? meta) (hash-ref meta 'num_turns (json-null)) (json-null))
            'cost_usd (if (hash? meta) (hash-ref meta 'total_cost_usd (json-null)) (json-null))
            'input_tokens (+ (u 'input_tokens) (u 'cache_read_input_tokens) (u 'cache_creation_input_tokens))
            'output_tokens (u 'output_tokens)
            'session_id (or session (json-null))
            'commands (session-commands session)))
  (write-json-file (build-path work "record.json") rec)
  rec)

(define (claude-turn work text model [session #f])
  (define-values (status _s out err)
    (claude work text (append (list "-p" "--model" model "--output-format" "json" "--max-turns" "1" "--tools" "")
                              (if session (list "--resume" session) '()))
            600 '()))
  (define meta (with-handlers ([exn:fail? (lambda (_) (error 'claude-turn "no answer (~a): ~a" status err))])
                 (string->jsexpr out)))
  (values (hash-ref meta 'result "") (hash-ref meta 'session_id) (let ([c (hash-ref meta 'total_cost_usd 0)]) (if (real? c) c 0))))

;; run-claude : dir prompt model tools timeout max-turns env -> (values status seconds stdout stderr)
(define (run-claude work prompt model tools timeout max-turns env-extra)
  (claude work prompt (append (list "-p" "--model" model "--output-format" "json"
                                    "--max-turns" (number->string max-turns) "--allowedTools")
                              tools (list "--disallowedTools") disallowed)
          timeout env-extra))

;; claude : dir prompt args timeout env -> (values status seconds stdout stderr)   the CLI in `work`, the
;; prompt on its stdin: an argument is limited to 128 KB (MAX_ARG_STRLEN), and the official protocol's
;; turns carry whole GET responses ("Argument list too long" ended a run)
(define (claude work prompt args timeout env-extra)
  ;; outside the agent's directory: it lists what is there
  (define in-file (make-temporary-file "claude-in-~a"))
  (display-to-file prompt in-file #:exists 'truncate)
  (define out-file (make-temporary-file "claude-out-~a"))
  (define err-file (make-temporary-file "claude-err-~a"))
  (define env (environment-variables-copy (current-environment-variables)))
  (for ([k (in-list withheld)]) (environment-variables-set! env (string->bytes/utf-8 k) #f))
  (for ([kv (in-list env-extra)])
    (environment-variables-set! env (string->bytes/utf-8 (car kv)) (string->bytes/utf-8 (cdr kv))))
  (define start (current-inexact-milliseconds))
  (define proc
    (call-with-output-file out-file #:exists 'truncate
      (lambda (out)
        (call-with-output-file err-file #:exists 'truncate
          (lambda (err)
            (call-with-input-file in-file
              (lambda (in)
                (define-values (p _o _i _e)
                  (parameterize ([subprocess-group-enabled #t] [current-directory work]
                                 [current-environment-variables env])
                    (apply subprocess out in err (find-executable-path "claude") args)))
                p)))))))
  (define done (sync/timeout timeout proc))
  (unless done (subprocess-kill proc #t) (sync proc))
  (define seconds (/ (- (current-inexact-milliseconds) start) 1000.0))
  (begin0 (values (if done (subprocess-status proc) -1) seconds
                  (file->string out-file) (if done (file->string err-file) "timeout"))
    (for-each delete-file (list in-file out-file err-file))))

;; session-commands : session-id -> (listof string)   every Bash command, from the transcript
;; (~/.claude/projects/<the directory, mangled>/<id>.jsonl)
(define (session-commands session)
  (define projects (build-path (find-system-path 'home-dir) ".claude" "projects"))
  (define file
    (and session (directory-exists? projects)
         (for*/first ([d (in-list (directory-list projects #:build? #t))]
                      [f (in-value (build-path d (string-append session ".jsonl")))]
                      #:when (file-exists? f))
           f)))
  (if (not file) '()
      (for*/list ([line (in-list (file->lines file))]
                  [e (in-value (with-handlers ([exn:fail? (lambda (_) #f)]) (string->jsexpr line)))]
                  #:when (hash? e)
                  [c (in-value (hash-ref (hash-ref e 'message (hasheq)) 'content #f))]
                  #:when (list? c)
                  [b (in-list c)]
                  #:when (and (hash? b) (equal? (hash-ref b 'type #f) "tool_use") (equal? (hash-ref b 'name #f) "Bash")))
        (hash-ref (hash-ref b 'input (hasheq)) 'command ""))))

(define (audit rec forbidden)
  (for/list ([c (in-list (hash-ref rec 'commands '()))]
             #:when (for/or ([f (in-list forbidden)]) (string-contains? c f)))
    c))

(module+ test
  (require rackunit)
  (check-equal? (audit (hasheq 'commands '("curl x" "cat /a/refsol.py")) '("refsol")) '("cat /a/refsol.py"))
  (check-equal? (session-commands #f) '())
  (check-equal? (in-parallel 3 '(1 2 3 4 5) (lambda (x) (sleep (* 0.01 (- 6 x))) (* x x))) '(1 4 9 16 25)))
