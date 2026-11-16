#lang racket/base

;;; make-examples.rkt — one worked example per kind of question FHIR-AgentBench asks, from its TRAIN
;;; split: the question, its assumption and the query that answers it over the benchmark's schema.
;;;
;;;   racket -l- fhir-examples/agent-bench/fab/make-examples <questions_answers_sql_fhir.csv> > examples.md
;;;
;;; The benchmark's questions are 76 templates filled in, and each template has one way of being
;;; answered: which visit "the last hospital visit" is, how "since 4 months ago" and "this year" are
;;; counted from the assumed current time, what is returned when two records tie. Those are the
;;; benchmark's definitions, and its train split states them as queries. An agent answering a test
;;; question finds the example of its kind and adapts the query.
;;;
;;; Only the train split is read: a test or validation question is never an example.

(require racket/file racket/list racket/string
         (only-in "make-sample.rkt" read-csv))

;; examples : csv-file -> (listof (hash column -> string))   the first train question of each
;; template, in the order the templates first appear
(define (examples csv-file)
  (define rows (read-csv (file->string csv-file)))
  (define header (map string->symbol (car rows)))
  (define train
    (for/list ([r (in-list (cdr rows))]
               #:when (equal? (list-ref r (index-of header 'split)) "train"))
      (for/hasheq ([k (in-list header)] [v (in-list r)]) (values k v))))
  (remove-duplicates train #:key (lambda (q) (hash-ref q 'template))))

;; one-line : string -> string
(define (one-line s) (string-normalize-spaces s))

(module+ main
  (define args (current-command-line-arguments))
  (unless (= (vector-length args) 1)
    (raise-user-error "usage: make-examples <questions_answers_sql_fhir.csv>"))
  (define es (examples (vector-ref args 0)))
  (printf "# Worked examples: one per kind of question (~a)\n\n" (length es))
  (printf "Each: the kind of question (its slots in braces), one question of that kind, what it assumes, and the query that answers it over the schema's tables.\n\n")
  (for ([q (in-list es)])
    (printf "### ~a\nQ: ~a\nAssume: ~a\nSQL: ~a\n\n"
            (one-line (hash-ref q 'template)) (one-line (hash-ref q 'question))
            (let ([a (one-line (hash-ref q 'assumption))]) (if (string=? a "") "(nothing)" a))
            (one-line (hash-ref q 'sql_query)))))

(module+ test
  (require rackunit)
  (define f (make-temporary-file "examples-~a.csv"))
  (display-to-file (string-append "split,question_id,question,sql_query,true_answer,assumption,template\n"
                                  "train,a,Q one?,SELECT 1,[[1]],,T1 {x}\n"
                                  "test,b,Q two?,SELECT 2,[[2]],,T2 {x}\n"
                                  "train,c,Q three?,SELECT 3,[[3]],now,T1 {x}\n"
                                  "train,d,Q four?,SELECT 4,[[4]],now,T3\n")
                   f #:exists 'truncate)
  (check-equal? (map (lambda (q) (hash-ref q 'question_id)) (examples f)) '("a" "d")
                "the first train question of each template; never a test question")
  (delete-file f))
