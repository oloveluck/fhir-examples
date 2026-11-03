#lang racket/base

;;; replay-test.rkt — the recorded model runs, checked and scored again with no model (`raco test`).
;;;   results/2026-11-03T2322        the FSH in the prompt: every note conforms in round 1
;;;   results/2026-11-03T2325-brief  only the profiles' urls; the feedback said "value does not match
;;;                                  required pattern" without the pattern: stuck at 1-2 issues
;;;   results/2026-11-03T2336-brief  the same, after the message names the required pattern: every
;;;                                  note conforms in round 2
;;; Every final round of the two converging runs scores every fact right with nothing extra.

(require racket/runtime-path)
(define-runtime-path results "results")

(module+ test
  (require rackunit racket/list "pipeline.rkt")
  (define (final-rounds dir)
    (for/list ([n (in-list (note-names))]) (last (hash-ref (replay-note (build-path results dir) n) 'rounds))))
  (define (perfect? r)
    (for/and ([(k v) (in-hash (hash-ref r 'score))]) (and (= (car v) (cadr v)) (zero? (caddr v)))))

  (for ([dir (in-list '("2026-11-03T2322" "2026-11-03T2336-brief"))])
    (define rs (parameterize ([current-spec (if (regexp-match? #rx"brief" dir) 'brief 'full)]) (final-rounds dir)))
    (for ([r (in-list rs)])
      (check-equal? (hash-ref r 'issues) '() (format "~a/~a conforms" dir (hash-ref r 'note)))
      (check-true (perfect? r) (format "~a/~a scores every fact" dir (hash-ref r 'note)))))

  ;; the run before the diagnostic fix did not converge (the recorded answers stay non-conforming)
  (check-true (for/or ([r (in-list (final-rounds "2026-11-03T2325-brief"))]) (pair? (hash-ref r 'issues)))))
