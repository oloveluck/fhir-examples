#lang racket/base

;;; model.rkt — asking a model, from any example: a shell command reads the prompt on stdin and writes
;;; its answer on stdout (`claude -p` by default in the examples).
;;;
;;; ask : command prompt-file answer-file err-file timeout -> (values exit-code seconds timed-out?)
;;;   through files, not pipes (nothing to pump, so nothing can wedge); past `timeout` seconds the
;;;   command's whole process group is killed
;;; extract-block : answer language -> string   the last ```<language> block, else the last ``` block,
;;;   else the whole answer

(require racket/list)

(provide ask extract-block)

(define (ask cmd prompt-file answer-file err-file timeout)
  (define start (current-inexact-milliseconds))
  (define proc
    (call-with-input-file prompt-file
      (lambda (in)
        (call-with-output-file answer-file #:exists 'truncate
          (lambda (out)
            (call-with-output-file err-file #:exists 'truncate
              (lambda (err)
                (define-values (p _o _i _e)
                  (parameterize ([subprocess-group-enabled #t])
                    (subprocess out in err "/bin/sh" "-c" cmd)))
                p)))))))
  (define done (sync/timeout timeout proc))
  (unless done (subprocess-kill proc #t) (sync proc))
  (values (subprocess-status proc) (round (/ (- (current-inexact-milliseconds) start) 1000.0)) (not done)))

(define (extract-block a language)
  (define fenced (regexp-match* (pregexp (string-append "```" language "[^\n]*\n(.*?)```")) a #:match-select cadr))
  (define any (regexp-match* #px"```[^\n]*\n(.*?)```" a #:match-select cadr))
  (cond [(pair? fenced) (last fenced)] [(pair? any) (last any)] [else a]))

(module+ test
  (require rackunit racket/file)
  (check-equal? (extract-block "x\n```fsh\nProfile: A\n```\ny" "fsh") "Profile: A\n")
  (check-equal? (extract-block "```json\n{}\n```" "json") "{}\n")
  (check-equal? (extract-block "```\nB\n```" "fsh") "B\n")
  ;; a command that echoes its prompt
  (define dir (make-temporary-directory))
  (define (f n) (build-path dir n))
  (call-with-output-file (f "p") (lambda (o) (write-string "hello" o)))
  (define-values (code secs timed-out?) (ask "cat" (f "p") (f "a") (f "e") 10))
  (check-equal? (list code timed-out?) '(0 #f))
  (check-equal? (call-with-input-file (f "a") (lambda (i) (read-line i))) "hello"))
