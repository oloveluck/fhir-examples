#lang racket/base

;;; grade.rkt — MedAgentBench runs graded by the benchmark's own reference solution.
;;;
;;;   racket -l- fhir-examples/agent-bench/mab/grade RUN_DIR [GRADE_BASE]   (default MAB_HAPI)
;;;
;;; refsol's graders read a session history — the agent's `POST <url>\n<json>` messages, each followed
;;; by "POST request accepted" — and the FINISH text, and query the benchmark's FHIR server for the
;;; reference values (always HAPI, the benchmark's own). An agent run's history is rebuilt from its
;;; posts.jsonl; an official run kept its own (history.json). A POST's url is moved from the arm's
;;; server base to the grading base. The graders are Python (refsol_bridge.py, MAB_REFSOL_DIR).
;;; Writes RUN_DIR/grades.json (one row per task: correct, posts, cost, tokens, time) and prints the
;;; score overall and per task kind.

(require racket/file racket/list racket/string racket/port racket/system racket/runtime-path racket/path json
         "../run-agent.rkt" "tasks.rkt")

(define-runtime-path bridge "refsol_bridge.py")

;; history-of : task-dir arm-base grade-base -> (values history result)
(define (history-of dir arm-base grade-base)
  (define (moved url) (if (and (positive? (string-length arm-base)) (string-prefix? url arm-base))
                          (string-append grade-base (substring url (string-length arm-base)))
                          url))
  (define answer (let ([f (build-path dir "answer.json")]) (and (file-exists? f) (read-json-file f))))
  (define result (and (hash? answer) (let ([r (hash-ref answer 'finish (json-null))]) (and (string? r) r))))
  (define official (build-path dir "history.json"))
  (cond
    [(file-exists? official)
     (values (for/list ([m (in-list (read-json-file official))])
               (define c (hash-ref m 'content))
               (if (and (equal? (hash-ref m 'role) "agent") (string-prefix? (string-trim c) "POST"))
                   (hash-set m 'content (string-replace c arm-base grade-base #:all? #f))
                   m))
             result)]
    [else
     (define posts-file (build-path dir "posts.jsonl"))
     (define posts (if (file-exists? posts-file)
                       (for/list ([l (in-list (file->lines posts-file))] #:unless (string=? (string-trim l) ""))
                         (string->jsexpr l))
                       '()))
     (values (append*
              (for/list ([p (in-list posts)])
                (list (hasheq 'role "agent" 'content (format "POST ~a\n~a" (moved (hash-ref p 'url)) (jsexpr->string (hash-ref p 'payload))))
                      (hasheq 'role "user" 'content "POST request accepted and executed successfully."))))
             result)]))

;; refsol-grades : grade-base (listof item) -> hash   id -> boolean, through the bridge
(define (refsol-grades grade-base items)
  (define request (jsexpr->string (hasheq 'refsol_dir (env-path "MAB_REFSOL_DIR") 'grade_base grade-base 'items items)))
  (define out (with-output-to-string
                (lambda ()
                  (parameterize ([current-input-port (open-input-string request)]
                                 [current-error-port (open-output-nowhere)])
                    (unless (system* (find-executable-path "python3") (path->string bridge))
                      (error 'grade "the refsol bridge failed"))))))
  (string->jsexpr out))

(define (grade run-dir grade-base)
  (define run (read-json-file (build-path run-dir "run.json")))
  (define arm-base (hash-ref run 'base ""))
  (define tasks (for/hash ([t (in-list (mab-tasks))]) (values (hash-ref t 'id) t)))
  (define dirs (for/list ([d (in-list (directory-list run-dir #:build? #t))]
                          #:when (and (directory-exists? d) (hash-has-key? tasks (path->string (file-name-from-path d)))))
                 d))
  (define items
    (for/list ([d (in-list dirs)])
      (define id (path->string (file-name-from-path d)))
      (define-values (history result) (history-of d arm-base grade-base))
      (hasheq 'id id 'task (hash-ref tasks id) 'history history 'result (or result (json-null)))))
  (define verdicts (refsol-grades grade-base items))
  (define rows
    (for/list ([d (in-list dirs)] [item (in-list items)])
      (define id (hash-ref item 'id))
      (define rec (let ([f (build-path d "record.json")]) (if (file-exists? f) (read-json-file f) (hasheq))))
      (define answer (let ([f (build-path d "answer.json")]) (if (file-exists? f) (read-json-file f) (hasheq))))
      (hasheq 'id id 'correct (hash-ref verdicts (string->symbol id) #f)
              'finish (hash-ref item 'result)
              'posts (for/sum ([m (in-list (hash-ref item 'history))])
                       (if (and (equal? (hash-ref m 'role) "agent") (string-prefix? (string-trim (hash-ref m 'content)) "POST")) 1 0))
              'seconds (hash-ref rec 'seconds (json-null))
              'cost_usd (hash-ref rec 'cost_usd (hash-ref answer 'cost_usd (json-null)))
              'input_tokens (hash-ref rec 'input_tokens (json-null))
              'output_tokens (hash-ref rec 'output_tokens (json-null))
              'turns (hash-ref rec 'turns (json-null)))))
  (write-json-file (build-path run-dir "grades.json") rows)
  (define (score rs) (format "~a/~a" (count (lambda (r) (hash-ref r 'correct)) rs) (length rs)))
  (printf "~a: ~a correct (~a%)\n" (file-name-from-path run-dir) (score rows)
          (/ (round (* 1000 (/ (count (lambda (r) (hash-ref r 'correct)) rows) (max 1 (length rows))))) 10.0))
  (define kinds (sort (remove-duplicates (map (lambda (r) (car (string-split (hash-ref r 'id) "_"))) rows))
                      < #:key (lambda (k) (string->number (substring k 4)))))
  (for ([k (in-list kinds)])
    (printf "  ~a ~a\n" k (score (filter (lambda (r) (string-prefix? (hash-ref r 'id) (string-append k "_"))) rows)))))

(module+ main
  (define args (current-command-line-arguments))
  (unless (<= 1 (vector-length args) 2)
    (raise-user-error "usage: racket -l- fhir-examples/agent-bench/mab/grade RUN_DIR [GRADE_BASE]"))
  (grade (path->complete-path (vector-ref args 0))
         (if (= (vector-length args) 2) (vector-ref args 1) (or (getenv "MAB_HAPI") "http://localhost:8080/fhir/"))))
