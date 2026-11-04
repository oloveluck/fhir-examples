#lang racket/base

;;; verify-test.rkt — the recorded results (results/*.json) as floors: each IG whose packages are
;;; already in packages/ is generated and verified again, and no tally may fail more, nor the
;;; server leave more requirements unmet, than the record. IGs not fetched are skipped (the test
;;; never touches the network: `racket ig-servers/main.rkt` fetches them).

(require racket/list racket/file racket/runtime-path json
         "fetch.rkt" "verify.rkt" (only-in "main.rkt" igs))

(define-runtime-path results "results")

(define (fetched-file name version)
  (let ([f (build-path (packages-dir) (format "~a-~a.tgz" name version))]) (and (file-exists? f) f)))

(module+ test
  (require rackunit)
  (for ([ig (in-list igs)])
    (define tgz (fetched-file (first ig) (second ig)))
    (define recorded-file (build-path results (format "~a-~a.json" (first ig) (second ig))))
    (cond
      [(not (and tgz (file-exists? recorded-file)))
       (printf "  ~a ~a: not fetched, skipped\n" (first ig) (second ig))]
      [else
       (define recorded (call-with-input-file recorded-file read-json))
       (define now (report->jsexpr (verify-ig tgz #:capability (third ig))))
       (check-true (<= (length (hash-ref now 'gaps)) (length (hash-ref recorded 'gaps))) (format "~a: unmet" (first ig)))
       (for ([k (in-list '(profiles accepted readBack search includes rejected))])
         (define (failed h) (hash-ref (hash-ref h k) 'failed))
         (define (checked h) (hash-ref (hash-ref h k) 'checked))
         (check-true (<= (failed now) (failed recorded)) (format "~a: ~a failures" (first ig) k))
         (check-true (>= (checked now) (checked recorded)) (format "~a: ~a checks" (first ig) k)))
       (printf "  ~a ~a: no regression\n" (first ig) (second ig))])))
