#lang racket/base

;;; implementers.rkt — the analysis of an experiment in which independent implementers build one
;;; system each, under one of two arms, and each implementation is held to cases (PROTOCOL.md: S,
;;; D). One definition of it, used by spec-first/ and definition-first/.
;;;
;;; Data definitions.
;;; An Outcome is (outcome sample? right? answer): one implementation on one case — whether the
;;;   case was shown to the implementer (then it is not scored), whether the answer is the expected
;;;   one, and the answer itself (any value compared with equal?, #f when there is none).
;;; An Impl is (impl unit arm outcomes cost): one implementation of a unit (a measure, an
;;;   operation) under an Arm (a symbol); outcomes is a hash case -> Outcome over the same cases
;;;   for every implementation of the unit; cost is a hasheq of reals.

(require racket/list racket/math)

(provide (struct-out outcome) (struct-out impl)
         mean held-cases share-right of-arm units difference agreement
         bootstrap-difference agreement-interval permutation-p resampled cost-ratio cost-ratio-interval)

(struct outcome (sample? right? answer) #:transparent)
(struct impl (unit arm outcomes cost) #:transparent)

(define (mean xs) (if (null? xs) 0 (/ (apply + xs) (length xs))))

;; held-cases : Impl -> (listof string)   the cases an implementer was not shown, in name order
(define (held-cases i)
  (sort (for/list ([(c o) (in-hash (impl-outcomes i))] #:unless (outcome-sample? o)) c) string<?))

;; share-right : (listof Impl) -> real   pooled over implementations and their held-out cases
(define (share-right impls)
  (define rights (for*/list ([i (in-list impls)] [c (in-list (held-cases i))])
                   (if (outcome-right? (hash-ref (impl-outcomes i) c)) 1 0)))
  (mean rights))

;; of-arm : (listof Impl) Arm [unit] -> (listof Impl)
(define (of-arm impls arm [u #f])
  (filter (lambda (i) (and (eq? (impl-arm i) arm) (or (not u) (equal? (impl-unit i) u)))) impls))

;; units : (listof Impl) -> (listof unit)   in first-seen order
(define (units impls) (remove-duplicates (map impl-unit impls)))

;; difference : (listof Impl) Arm Arm -> real   the first arm's share right less the second's
(define (difference impls a b) (- (share-right (of-arm impls a)) (share-right (of-arm impls b))))

;; agreement : (listof Impl) -> real   over the held-out cases of the units these implement, the
;; share on which every implementation of a unit gives the same answer (a failure on a case
;; agrees with nothing)
(define (agreement impls)
  (mean (for*/list ([u (in-list (units impls))]
                    [group (in-value (filter (lambda (i) (equal? (impl-unit i) u)) impls))]
                    [c (in-list (held-cases (car group)))])
          (define answers (map (lambda (i) (outcome-answer (hash-ref (impl-outcomes i) c))) group))
          (if (and (andmap values answers) (= 1 (length (remove-duplicates answers)))) 1 0))))

(define (seeded-rng seed)
  (define rng (make-pseudo-random-generator))
  (parameterize ([current-pseudo-random-generator rng]) (random-seed seed))
  rng)

(define (percentiles vs)
  (define sorted (list->vector (sort vs <)))
  (define k (vector-length sorted))
  (cons (vector-ref sorted (exact-floor (* 0.025 (- k 1)))) (vector-ref sorted (exact-ceiling (* 0.975 (- k 1))))))

;; resampled : (listof Impl) rng [boolean] -> (listof Impl)   within each unit: its held-out cases
;; drawn with replacement (the same draw for every arm: a case is paired), and within each unit
;; and arm its implementations drawn with replacement. An implementation's outcomes become a hash
;; over the drawn cases under fresh names, so a case drawn twice counts twice. #:stratum names
;; the stratum of a case (a version of the unit, say): cases are then drawn within each stratum,
;; as many as it has.
(define (resampled impls rng [resample-impls? #t] #:stratum [stratum (lambda (c) #t)])
  (parameterize ([current-pseudo-random-generator rng])
    (append*
     (for/list ([u (in-list (units impls))])
       (define group (filter (lambda (i) (equal? (impl-unit i) u)) impls))
       (define cases (held-cases (car group)))
       (define drawn
         (append*
          (for/list ([s (in-list (remove-duplicates (map stratum cases)))])
            (define mine (list->vector (filter (lambda (c) (equal? (stratum c) s)) cases)))
            (for/list ([_ (in-range (vector-length mine))]) (vector-ref mine (random (vector-length mine)))))))
       (append*
        (for/list ([arm (in-list (remove-duplicates (map impl-arm group)))])
          (define mine (list->vector (filter (lambda (i) (eq? (impl-arm i) arm)) group)))
          (for/list ([k (in-range (vector-length mine))])
            (define i (vector-ref mine (if resample-impls? (random (vector-length mine)) k)))
            (impl u arm
                  (for/hash ([c (in-list drawn)] [j (in-naturals)])
                    (values (format "~a#~a" c j) (hash-ref (impl-outcomes i) c)))
                  (impl-cost i)))))))))

;; bootstrap-difference : (listof Impl) Arm Arm [natural] -> (cons low high)   the 95% interval of
;; the first arm's share right less the second's
(define (bootstrap-difference impls a b [resamples 4000] #:stratum [stratum (lambda (c) #t)])
  (define rng (seeded-rng 20261122))
  (percentiles (for/list ([_ (in-range resamples)])
                 (exact->inexact (difference (resampled impls rng #:stratum stratum) a b)))))

;; agreement-interval : (listof Impl) Arm Arm [natural] -> (cons low high)   of agreement(a) −
;; agreement(b), the cases resampled (the implementers are the ones there are)
(define (agreement-interval impls a b [resamples 4000])
  (define rng (seeded-rng 20261123))
  (percentiles (for/list ([_ (in-range resamples)])
                 (define r (resampled impls rng #f))
                 (exact->inexact (- (agreement (of-arm r a)) (agreement (of-arm r b)))))))

;; permutation-p : (listof Impl) Arm Arm [natural] -> real   how often arm labels shuffled within
;; each unit give a difference at least as large (two-sided)
(define (permutation-p impls a b [shuffles 20000])
  (define rng (seeded-rng 20261124))
  (define observed (abs (difference impls a b)))
  (define by-unit (for/list ([u (in-list (units impls))]) (filter (lambda (i) (equal? (impl-unit i) u)) impls)))
  (parameterize ([current-pseudo-random-generator rng])
    (/ (for/sum ([_ (in-range shuffles)])
         (define relabelled
           (append* (for/list ([group (in-list by-unit)])
                      (for/list ([i (in-list (shuffle group))] [arm (in-list (map impl-arm group))])
                        (impl (impl-unit i) arm (impl-outcomes i) (impl-cost i))))))
         (if (>= (abs (difference relabelled a b)) observed) 1 0))
       shuffles)))

;; cost-ratio : (listof Impl) Arm Arm symbol -> real | #f   the first arm's mean cost over the
;; second's, for one key of the cost
(define (cost-ratio impls a b key)
  (define (m arm) (mean (map (lambda (i) (hash-ref (impl-cost i) key 0)) (of-arm impls arm))))
  (and (pair? (of-arm impls a)) (pair? (of-arm impls b)) (positive? (m b)) (/ (m a) (m b))))

;; cost-ratio-interval : (listof Impl) Arm Arm symbol [natural] -> (cons low high)   implementations
;; resampled within unit and arm
(define (cost-ratio-interval impls a b key [resamples 4000])
  (define rng (seeded-rng 20261125))
  (define groups
    (for*/list ([u (in-list (units impls))] [arm (in-list (list a b))])
      (list->vector (filter (lambda (i) (equal? (impl-unit i) u)) (of-arm impls arm)))))
  (parameterize ([current-pseudo-random-generator rng])
    (percentiles
     (filter values
             (for/list ([_ (in-range resamples)])
               (define drawn
                 (append* (for/list ([g (in-list groups)])
                            (for/list ([_ (in-range (vector-length g))]) (vector-ref g (random (vector-length g)))))))
               (let ([r (cost-ratio drawn a b key)]) (and r (exact->inexact r))))))))

(module+ test
  (require rackunit)
  (define (made unit arm rights cost)
    (impl unit arm
          (for/hash ([r (in-list rights)] [k (in-naturals)])
            (values (format "c~a" k) (outcome (zero? k) r (if r 'yes 'no))))
          (hasheq 'tokens cost)))
  ;; the first case of each is the implementers' sample and is not scored
  (define impls
    (list (made "u" 'A '(#f #t #t #t #t) 100) (made "u" 'A '(#f #t #t #t #t) 100)
          (made "u" 'B '(#t #f #f #f #f) 300) (made "u" 'B '(#t #f #f #t #f) 300)))
  (check-equal? (held-cases (car impls)) '("c1" "c2" "c3" "c4"))
  (check-equal? (share-right (of-arm impls 'A)) 1)
  (check-equal? (share-right (of-arm impls 'B)) 1/8)
  (check-equal? (difference impls 'A 'B) 7/8)
  (check-equal? (units impls) '("u"))
  ;; A's two agree on every case, B's on all but c3
  (check-equal? (agreement (of-arm impls 'A)) 1)
  (check-equal? (agreement (of-arm impls 'B)) 3/4)
  (let ([ci (bootstrap-difference impls 'A 'B 500)])
    (check-true (<= (car ci) 7/8 (cdr ci)))
    (check-true (> (car ci) 0)))
  (check-true (<= 0 (permutation-p impls 'A 'B 500) 1))
  (check-equal? (cost-ratio impls 'A 'B 'tokens) 1/3)
  (check-equal? (cost-ratio-interval impls 'A 'B 'tokens 200) (cons (/ 1.0 3) (/ 1.0 3)))
  (check-false (cost-ratio impls 'A 'C 'tokens))
  ;; a resample keeps the units, the arms and how many of each there are
  (let ([r (resampled impls (seeded-rng 1))])
    (check-equal? (map impl-arm r) '(A A B B))
    (check-equal? (length (held-cases (car r))) 4))
  ;; drawn within strata: with c1, c2 one stratum and c3, c4 another, two of each are drawn
  (let* ([stratum (lambda (c) (and (member c '("c1" "c2")) #t))]
         [r (resampled impls (seeded-rng 2) #:stratum stratum)]
         [drawn (map (lambda (c) (car (regexp-match #rx"^[^#]*" c))) (held-cases (car r)))])
    (check-equal? (length (filter stratum drawn)) 2)
    (check-equal? (length drawn) 4)))
