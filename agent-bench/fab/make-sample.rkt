#lang racket/base

;;; make-sample.rkt — a fixed sample of FHIR-AgentBench questions: N from a split, spread over the
;;; question templates (round-robin over the templates in a seeded order, each template's questions in
;;; a seeded order), so a sample of 150 covers the kinds of question the split has. The test split is
;;; for reporting only; iterate on `valid`.
;;;
;;;   racket -l- fhir-examples/agent-bench/fab/make-sample <questions_answers_sql_fhir.csv> <split> <N> <seed> > sample.json

(require racket/list racket/string racket/file json)

(provide read-csv)

;; read-csv : string -> (listof (listof string))   RFC 4180: quoted fields hold commas, quotes ("")
;; and line breaks
(define (read-csv text)
  (define n (string-length text))
  (let loop ([i 0] [field '()] [row '()] [rows '()] [quoted? #f])
    (define (end-field) (cons (list->string (reverse field)) row))
    (cond
      [(= i n) (reverse (if (and (null? field) (null? row)) rows (cons (reverse (end-field)) rows)))]
      [else
       (define c (string-ref text i))
       (cond
         [quoted? (cond [(and (char=? c #\") (< (add1 i) n) (char=? (string-ref text (add1 i)) #\"))
                         (loop (+ i 2) (cons #\" field) row rows #t)]
                        [(char=? c #\") (loop (add1 i) field row rows #f)]
                        [else (loop (add1 i) (cons c field) row rows #t)])]
         [(char=? c #\") (loop (add1 i) field row rows #t)]
         [(char=? c #\,) (loop (add1 i) '() (end-field) rows #f)]
         [(char=? c #\return) (loop (add1 i) field row rows #f)]
         [(char=? c #\newline) (loop (add1 i) '() '() (cons (reverse (end-field)) rows) #f)]
         [else (loop (add1 i) (cons c field) row rows #f)])])))

;; seeded-shuffle : list prng -> list   Fisher–Yates with the given generator
(define (seeded-shuffle xs rng)
  (define v (list->vector xs))
  (for ([i (in-range (sub1 (vector-length v)) 0 -1)])
    (define j (random (add1 i) rng))
    (define t (vector-ref v i)) (vector-set! v i (vector-ref v j)) (vector-set! v j t))
  (vector->list v))

(define (sample csv-file split n seed)
  (define rows (read-csv (file->string csv-file)))
  (define header (map string->symbol (car rows)))
  (define records (for/list ([r (in-list (cdr rows))] #:when (= (length r) (length header)))
                    (for/hasheq ([k (in-list header)] [v (in-list r)]) (values k v))))
  (define chosen (filter (lambda (r) (and (equal? (hash-ref r 'split) split) (equal? (hash-ref r 'mappable_to_fhir) "True"))) records))
  (define rng (vector->pseudo-random-generator (vector 1 2 3 4 5 6)))
  (parameterize ([current-pseudo-random-generator rng]) (random-seed seed))
  (define by (for/fold ([h (hash)]) ([r (in-list chosen)]) (hash-update h (hash-ref r 'template) (lambda (l) (cons r l)) '())))
  (define templates (seeded-shuffle (sort (hash-keys by) string<?) rng))
  (define queues (for/hash ([t (in-list templates)]) (values t (seeded-shuffle (reverse (hash-ref by t)) rng))))
  (let loop ([queues queues] [out '()])
    (cond
      [(or (>= (length out) n) (andmap null? (hash-values queues))) (reverse out)]
      [else
       (define-values (qs o)
         (for/fold ([qs queues] [o out]) ([t (in-list templates)])
           (define q (hash-ref qs t))
           (if (and (pair? q) (< (length o) n)) (values (hash-set qs t (cdr q)) (cons (car q) o)) (values qs o))))
       (loop qs o)])))

(module+ main
  (define args (current-command-line-arguments))
  (unless (= (vector-length args) 4)
    (raise-user-error "usage: make-sample <questions_answers_sql_fhir.csv> <split> <N> <seed>"))
  (define picked (sample (vector-ref args 0) (vector-ref args 1)
                         (string->number (vector-ref args 2)) (string->number (vector-ref args 3))))
  (write-json (for/list ([r (in-list picked)])
                (for/hasheq ([k '(question_id question assumption patient_fhir_id template)]) (values k (hash-ref r k))))))

(module+ test
  (require rackunit)
  (check-equal? (read-csv "a,b\n\"x, \"\"y\"\"\",2\n\"line\nbreak\",3\n")
                '(("a" "b") ("x, \"y\"" "2") ("line\nbreak" "3"))))
