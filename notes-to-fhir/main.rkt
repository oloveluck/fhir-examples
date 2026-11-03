#lang racket/base

;;; main.rkt — clinic notes in, conforming FHIR out, and the data put to work.
;;;
;;;   racket notes-to-fhir/main.rkt [--model 'claude -p'] [--rounds 3] [--timeout 600] [--brief] [note …]
;;;       each note through the model, checked against the FSH profiles, issues fed back; every
;;;       round recorded under notes-to-fhir/results/<date>/. The prompt carries the FSH source;
;;;       --brief gives only the profiles' names and urls, so the model learns the rest from the checks
;;;   racket notes-to-fhir/main.rkt --replay notes-to-fhir/results/<date>
;;;       the recorded answers checked and scored again, no model
;;;
;;; Then the extracted data is used: the screening rule from ../screening (a CQL library) runs over
;;; each patient's validated resources.

(require racket/list racket/string racket/file racket/runtime-path racket/date json
         "pipeline.rkt"
         (only-in "../screening/screening.cql" [evaluate screen])
         (only-in cql/value render))

(define-runtime-path here ".")

(define (args) (vector->list (current-command-line-arguments)))
(define (opt name default) (let ([m (member name (args))]) (if (and m (pair? (cdr m))) (cadr m) default)))
(define (positional)
  (let loop ([as (args)])
    (cond [(null? as) '()]
          [(equal? (car as) "--brief") (loop (cdr as))]                       ; a flag
          [(regexp-match? #rx"^--" (car as)) (loop (if (pair? (cdr as)) (cddr as) '()))]
          [else (cons (car as) (loop (cdr as)))])))

(define (frac v) (format "~a/~a~a" (first v) (second v) (if (positive? (third v)) (format " +~a" (third v)) "")))

(define (report results)
  (define (row . cells) (printf "~a\n" (string-join (for/list ([c (in-list cells)] [w (in-list '(9 7 20 8 9 9 11))]) (pad c w)) " ")))
  (newline)
  (row "note" "rounds" "issues per round" "patient" "readings" "problems" "medications")
  (for ([r (in-list results)])
    (define rounds (hash-ref r 'rounds))
    (define s (hash-ref (last rounds) 'score))
    (row (hash-ref r 'note) (number->string (length rounds))
         (string-join (for/list ([x (in-list rounds)]) (number->string (length (hash-ref x 'issues)))) " -> ")
         (frac (hash-ref s 'patient)) (frac (hash-ref s 'bloodPressures))
         (frac (hash-ref s 'problems)) (frac (hash-ref s 'medications))))
  (printf "(right/expected, +extra; issues are what the profiles rejected in each round)\n"))

;; the screening rule over each conforming extraction
(define (screening results)
  (printf "\nscreening rule (../screening/screening.cql) over the extracted data:\n")
  (for ([r (in-list results)])
    (define last-round (last (hash-ref r 'rounds)))
    (define b (hash-ref last-round 'bundle))
    (cond
      [(pair? (hash-ref last-round 'issues))
       (printf "  ~a: not run — the extraction does not conform\n" (hash-ref r 'note))]
      [else
       (define resources (for/list ([e (in-list (hash-ref b 'entry))]) (hash-ref e 'resource)))
       (define facts (screen resources #:parameters (hash "Panel Codes" (list "85354-9"))))
       (printf "  ~a: highest systolic ~a, hypertensive: ~a\n" (hash-ref r 'note)
               (render (hash-ref facts "Highest Systolic")) (if (eq? (hash-ref facts "Hypertensive") #t) "yes" "no"))])))

(define (pad s n) (string-append s (make-string (max 0 (- n (string-length s))) #\space)))

(module+ main
  (define notes (let ([ps (positional)]) (if (null? ps) (note-names) ps)))
  (define results
    (cond
      [(opt "--replay" #f)
       => (lambda (dir) (current-spec (if (regexp-match? #rx"-brief" dir) 'brief 'full)) (for/list ([n (in-list notes)] #:when (directory-exists? (build-path dir n))) (replay-note dir n)))]
      [else
       (define stamp (parameterize ([date-display-format 'iso-8601]) (date->string (current-date) #t)))
       (define dir (build-path here "results" (string-append (string-replace (substring stamp 0 16) ":" "")
                                                              (if (member "--brief" (args)) "-brief" ""))))
       (define cmd (opt "--model" "claude -p"))
       (printf "model: ~a; recording to ~a\n" cmd dir)
       (for/list ([n (in-list notes)])
         (printf "  ~a …\n" n) (flush-output)
         (current-spec (if (member "--brief" (args)) 'brief 'full))
         (run-note n #:model cmd #:rounds (string->number (opt "--rounds" "3"))
                   #:timeout (string->number (opt "--timeout" "600")) #:record dir))]))
  (report results)
  (screening results))
