#lang racket/base

;;; map-reference-r4-test.rkt — matchbox's own maps run as R4, the version they were written for
;;; (value-experiment/PROTOCOL.md, H part 2, third and fourth passes): this engine as it is now,
;;; held to the reference's kept R4 answers. A file of its own: a process holds one FHIR version.
(require rackunit racket/file racket/list racket/runtime-path "map-reference.rkt")

(define-runtime-path kept "answers/map-fresh-r4-reference.jsonl.gz")

(load-version! "4.0.1")
(let ([dir (make-temporary-file "map-fresh-r4-~a" 'directory)])
  (dynamic-wind
   void
   (lambda ()
     (parameterize ([current-fresh-maps? #t])
       (write-map-materials! dir)
       (define ref (read-answers kept))
       (define errors (read-errors kept))
       (define rows (for/list ([p (in-list (all-map-pairs dir))])
                      (list p (hash-ref ref (map-pair-id p) 'missing) (our-map-answer dir p) (hash-ref errors (map-pair-id p) ""))))
       (check-equal? (length rows) 667)
       (check-false (ormap (lambda (r) (eq? (cadr r) 'missing)) rows))
       ;; the write-up's agreement as a floor; every pair of this set has been read, and no
       ;; difference is left that is this engine's or in no class
       (check-true (>= (count agree? rows) 561))
       (check-equal? (count (lambda (r) (and (not (agree? r)) (memq (head-of r) '(ours unread)))) rows) 0)))
   (lambda () (delete-directory/files dir))))
