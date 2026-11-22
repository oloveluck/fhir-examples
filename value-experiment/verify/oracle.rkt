#lang racket/base

;;; oracle.rkt — a measure's specification, executed: the measure's CQL (cql's vendored
;;; ecqm-content-qicore-2024) run by cql's engine over one patient's records, answering the four
;;; populations. Experiment V's arm O gives a checker this and nothing of the CQL's text.
;;;
;;;   (oracle measure resources) -> (hash population boolean) | string   the answers, or why not
;;;   (oracle-main measure)   the command a checker runs: `racket oracle.rkt [DIR]`
;;;
;;; The evaluation is the one cql's own measure test makes (tests/qicore-measure-harness.rkt): the
;;; library and what it includes from the corpus, the corpus's value sets, the Measurement Period
;;; as whole days at UTC, every resource of the directory taken as the patient's.

(require racket/file racket/list racket/string json
         (only-in cql/parser/parse parse-cql parse-cql-expr)
         (only-in cql/compile compile-expr)
         (only-in cql/interp eval-elm make-ienv)
         (only-in cql/error cql-error? cql-error-string)
         (only-in cql/value current-evaluation-offset)
         cql/run
         (only-in fhir/result/result ok? ok-value)
         (only-in "../spec-first/materials.rkt" populations))

(provide oracle oracle-main answers-line)

(define root (build-path (collection-path "cql") "tests" "vendor" "qicore-2024"))

;; the corpus's libraries, each parsed once
(define resolver
  (caching-resolver
   (lambda (name _version)
     (define f (build-path root "elm-corpus" "ecqm-content-qicore-2024" (format "~a.cql" name)))
     (and (file-exists? f) (let ([r (parse-cql (file->string f))]) (and (ok? r) (ok-value r)))))))

;; the corpus's value sets, read once
(define terminology (let ([t #f]) (lambda () (or t (begin (set! t (valuesets->terminology (read-json-files (build-path root "valueset")))) t)))))

;; measure-resource : measure -> jsexpr   the Measure, read once a measure
(define measure-resource
  (let ([seen (make-hash)])
    (lambda (m)
      (hash-ref! seen m (lambda () (call-with-input-file (build-path root "measure" (string-append m ".json")) read-json))))))

;; period : date date -> Interval<DateTime>   [start 00:00:00.000, end 23:59:59.999] at UTC
(define (period start end)
  (parameterize ([current-evaluation-offset 0])
    (eval-elm (ok-value (compile-expr (ok-value (parse-cql-expr (format "Interval[@~aT00:00:00.000Z, @~aT23:59:59.999Z]" start end)))))
              (make-ienv))))

;; oracle : measure (listof jsexpr) [date date] -> (hash population boolean) | string
(define (oracle m resources [start "2025-01-01"] [end "2025-12-31"])
  (with-handlers ([cql-error? cql-error-string] [exn:fail? exn-message])
    (define counts
      (measure-populations
       (measure-resource m)
       (load-runtime-library (resolver (string->symbol m) #f) #:resolver resolver
                             #:data (resources->data resources #:patient-context? #f)
                             #:valuesets (terminology) #:offset 0
                             #:parameters (hash "Measurement Period" (period start end)))))
    (for/hash ([p (in-list populations)]) (values p (positive? (hash-ref counts p 0))))))

;; answers-line : string (hash population boolean | string) -> string   one patient's answers, as
;; the implementers' own script prints an implementation's
(define (answers-line name answer)
  (if (string? answer)
      (format "~a ERROR ~a" name (car (string-split answer "\n")))
      (format "~a ~a" name (string-join (for/list ([p (in-list populations)]) (format "~a=~a" p (if (hash-ref answer p) "yes" "no"))) " "))))

;; patient-directories : dir -> (listof (cons name dir))   the patients of a directory: its
;; subdirectories, or itself when it holds a patient's files
(define (patient-directories dir)
  (define subs (sort (for/list ([d (in-list (directory-list dir))] #:when (directory-exists? (build-path dir d))) (path->string d)) string<?))
  (if (null? subs)
      (list (cons (let-values ([(_b name _d) (split-path (path->complete-path dir))]) (path->string name)) dir))
      (for/list ([s (in-list subs)]) (cons s (build-path dir s)))))

;; patient-resources : dir -> (listof jsexpr)   the JSON files of a patient's directory
(define (patient-resources dir)
  (for/list ([f (in-list (sort (map path->string (directory-list dir)) string<?))] #:when (regexp-match? #rx"[.]json$" f))
    (call-with-input-file (build-path dir f) read-json)))

;; oracle-main : measure -> void   `racket oracle.rkt [DIR]`: the specification's answers for each
;; patient of DIR (default sample/), one line a patient
(define (oracle-main m)
  (define args (vector->list (current-command-line-arguments)))
  (define dir (if (pair? args) (car args) "sample"))
  (cond [(not (directory-exists? dir)) (eprintf "oracle: no directory ~a\n" dir) (exit 2)]
        [else
         (for ([p (in-list (patient-directories dir))])
           (define answer (with-handlers ([exn:fail? (lambda (e) (format "the patient's files do not read: ~a" (exn-message e)))])
                            (oracle m (patient-resources (cdr p)))))
           (displayln (answers-line (car p) answer)))]))

(module+ test
  (require rackunit (only-in "../spec-first/materials.rkt" measures case-ids sample-case? case-resources case-expected))
  (check-equal? (answers-line "p1" (hash "initial-population" #t "denominator" #t "denominator-exclusion" #f "numerator" #f))
                "p1 initial-population=yes denominator=yes denominator-exclusion=no numerator=no")
  (check-equal? (answers-line "p2" "no birth date\nmore") "p2 ERROR no birth date")
  ;; over the patients as the implementers and checkers are given them (names removed, no expected
  ;; report among the files), the specification executed is right on all but two of the authors'
  ;; 190 cases, and on all but one of the 151 that are scored
  (define results
    (for*/list ([m (in-list measures)] [c (in-list (case-ids m))])
      (list (sample-case? m c) (equal? (oracle m (map cdr (case-resources m c))) (case-expected m c)))))
  (check-equal? (length results) 190)
  (check-equal? (count cadr results) 188)
  (check-equal? (count cadr (filter (lambda (r) (not (car r))) results)) 150)
  ;; a directory of patients, or one patient's directory
  (define dir (make-temporary-file "oracle-~a" 'directory))
  (make-directory* (build-path dir "a")) (make-directory* (build-path dir "b"))
  (display-to-file "{\"resourceType\":\"Patient\"}" (build-path dir "a" "p.json"))
  (check-equal? (map car (patient-directories dir)) '("a" "b"))
  (check-equal? (length (patient-directories (build-path dir "a"))) 1)
  (check-equal? (patient-resources (build-path dir "a")) (list (hasheq 'resourceType "Patient")))
  (delete-directory/files dir))
