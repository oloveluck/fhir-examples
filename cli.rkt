#lang racket/base

;;; cli.rkt — `raco spec-bench`: FHIR prose -> FSH, scored against the published IG (bench.rkt).
;;;
;;;   raco spec-bench list <ig-dir>                                   profiles that can be taken out
;;;   raco spec-bench make <ig-dir> <published-package> <Profile> <task-dir>
;;;   raco spec-bench score <task-dir> (--oracle | --empty | <candidate.fsh>)
;;;   raco spec-bench run <task-dir> --model '<shell command>' [--rounds n] [--timeout seconds]
;;; The model command reads the prompt on stdin and answers on stdout (e.g. `claude -p`).

(require racket/list racket/match
         (only-in racket/file file->string)
         spec-driven/bench)

(define usage-text
  (string-append "usage: raco spec-bench list <ig-dir>\n"
                 "       raco spec-bench make <ig-dir> <published-package> <Profile> <task-dir>\n"
                 "       raco spec-bench score <task-dir> (--oracle | --empty | <candidate.fsh>)\n"
                 "       raco spec-bench run <task-dir> --model '<shell command>' [--rounds n] [--timeout seconds]\n"))
(define (usage [code 2] [msg #f])
  (when msg (eprintf "spec-bench: ~a\n" msg))
  ((if (zero? code) printf eprintf) usage-text)
  (exit code))

(define (show-score s)
  (define (frac k) (let ([v (hash-ref s k)]) (format "~a/~a" (car v) (cadr v))))
  (define head (format "~a~a" (hash-ref s 'task) (if (hash-ref s 'round #f) (format " round ~a" (hash-ref s 'round)) "")))
  (define timing (if (hash-ref s 'seconds #f) (format " [~as]" (hash-ref s 'seconds)) ""))
  (cond
    [(and (hash-has-key? s 'answered) (not (hash-ref s 'answered)))
     (printf "~a~a: no answer (~a)\n" head timing
             (if (hash-ref s 'timed_out #f) "timed out" (format "exit ~a" (hash-ref s 'exit_code #f))))]
    [else
     (printf "~a~a: check errors ~a (~a in the candidate); profile ~a; fidelity ~a facets, ~a extra elements; accepts ~a published examples; ~a of its examples conform to the published profile\n"
             head timing (hash-ref s 'check_errors) (hash-ref s 'candidate_diagnostics)
             (if (hash-ref s 'profile_compiled) "compiled" "MISSING")
             (frac 'fidelity) (hash-ref s 'extra_constrained_elements) (frac 'accepts_published_examples)
             (frac 'examples_conform_to_published))]))

(module+ main
  (define args (vector->list (current-command-line-arguments)))
  (when (ormap (lambda (a) (member a '("-h" "--help"))) args) (usage 0))
  (match args
    [(list "list" ig)
     (for ([t (in-list (list-tasks ig))]) (printf "~a\t~a\t~a examples\n" (first t) (second t) (third t)))]
    [(list "make" ig published profile out)
     (printf "~a\n" (make-task! ig (published-package published) profile out))]
    [(list "score" dir which)
     (define t (call-with-input-file (build-path dir "task.rktd") read))
     (define fsh (cond [(equal? which "--oracle") (hash-ref t 'oracle)]
                       [(equal? which "--empty") ""]
                       [(file-exists? which) (file->string which)]
                       [else (usage 2 (format "no such file: ~a" which))]))
     (define s (score-task dir fsh))
     (show-score s)
     (for ([r (in-list (hash-ref s 'rejections))]) (printf "  rejected: ~a\n" r))
     (unless (string=? (hash-ref s 'diagnostics_text) "") (display (hash-ref s 'diagnostics_text)))]
    [(list "run" dir "--model" cmd more ...)
     (define (opt name default)
       (let ([m (member name more)])
         (cond [(not m) default]
               [(and (pair? (cdr m)) (string->number (cadr m))) => values]
               [else (usage 2 (format "~a needs a number" name))])))
     (for ([s (in-list (run-task! dir cmd #:rounds (opt "--rounds" 3) #:timeout (opt "--timeout" 1200)))])
       (show-score s))]
    [_ (usage)]))
