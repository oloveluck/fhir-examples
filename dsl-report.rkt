#lang racket/base

;;; dsl-report.rkt — the spec bench's two formats side by side: a DSL (FSH) against the
;;; representation it compiles to (FHIR JSON), on the same tasks, scored by the same oracle.
;;;
;;;   racket dsl-report.rkt <task-dir>…
;;;
;;; For each task and format, the latest run (results.jsonl): its last round's score and what the run
;;; cost — rounds, input and output tokens summed over its rounds, the last answer's characters.
;;; Then the totals, and the tasks where one format did better than the other.

(require racket/list racket/string racket/file json)

;; A Run is a hash: format task rounds clean fidelity accepts conforms in out chars
(define (runs-of dir)
  (define f (build-path dir "results.jsonl"))
  (define lines (if (file-exists? f) (map string->jsexpr (file->lines f)) '()))
  (for/list ([fmt (in-list '("fsh" "json"))])
    (define mine (filter (lambda (s) (equal? (hash-ref s 'format "fsh") fmt)) lines))
    (define latest (and (pair? mine) (hash-ref (last mine) 'run)))
    (define rounds (filter (lambda (s) (equal? (hash-ref s 'run) latest)) mine))
    (and (pair? rounds)
         (let* ([final (last rounds)]
                [n (lambda (k) (for/sum ([s rounds]) (let ([v (hash-ref s k 0)]) (if (real? v) v 0))))]
                [pair (lambda (k) (let ([v (hash-ref final k #f)]) (if (list? v) v '(0 0))))])
           (hasheq 'format fmt 'task (hash-ref final 'task) 'rounds (length rounds)
                   'answered (hash-ref final 'answered #f)
                   'clean (and (hash-ref final 'answered #f) (eqv? 0 (hash-ref final 'candidate_diagnostics #f)))
                   'compiled (hash-ref final 'profile_compiled #f)
                   'fidelity (pair 'fidelity) 'accepts (pair 'accepts_published_examples)
                   'conforms (pair 'examples_conform_to_published)
                   'in (n 'input_tokens) 'out (n 'output_tokens) 'chars (hash-ref final 'answer_chars 0))))))

(define (frac p) (if (zero? (cadr p)) 1 (/ (car p) (cadr p))))
(define (pct x) (format "~a%" (round (* 100 x))))
(define (k x) (format "~ak" (/ (round (/ x 100)) 10.0)))

(module+ main
  (define dirs (vector->list (current-command-line-arguments)))
  (define pairs (for/list ([d dirs]) (runs-of d)))
  (define done (filter (lambda (p) (and (first p) (second p))) pairs))
  (printf "| task | fsh: rounds · clean · fidelity · accepts · conforms · out / in tokens | json: same |\n|---|---|---|\n")
  (for ([p done])
    (define (cell r) (format "~a · ~a · ~a · ~a/~a · ~a/~a · ~a / ~a" (hash-ref r 'rounds) (if (hash-ref r 'clean) "yes" "no")
                             (pct (frac (hash-ref r 'fidelity))) (car (hash-ref r 'accepts)) (cadr (hash-ref r 'accepts))
                             (car (hash-ref r 'conforms)) (cadr (hash-ref r 'conforms)) (k (hash-ref r 'out)) (k (hash-ref r 'in))))
    (printf "| ~a | ~a | ~a |\n" (hash-ref (first p) 'task) (cell (first p)) (cell (second p))))
  (newline)
  (printf "~a tasks with both formats run\n\n" (length done))
  (printf "| format | clean at the end | mean fidelity | published examples accepted | own examples conforming | rounds | output tokens | input tokens | answer characters |\n|---|---|---|---|---|---|---|---|---|\n")
  (for ([i '(0 1)] [name '("FSH (the DSL)" "FHIR JSON (the representation)")])
    (define rs (map (lambda (p) (list-ref p i)) done))
    (define (sum f) (for/sum ([r rs]) (f r)))
    (define (pairsum key) (list (sum (lambda (r) (car (hash-ref r key)))) (sum (lambda (r) (cadr (hash-ref r key))))))
    (printf "| ~a | ~a/~a | ~a | ~a/~a | ~a/~a | ~a | ~a | ~a | ~a |\n" name
            (count (lambda (r) (hash-ref r 'clean)) rs) (length rs)
            (pct (/ (sum (lambda (r) (frac (hash-ref r 'fidelity)))) (max 1 (length rs))))
            (car (pairsum 'accepts)) (cadr (pairsum 'accepts)) (car (pairsum 'conforms)) (cadr (pairsum 'conforms))
            (/ (round (* 10 (/ (sum (lambda (r) (hash-ref r 'rounds))) (max 1 (length rs))))) 10.0)
            (k (sum (lambda (r) (hash-ref r 'out)))) (k (sum (lambda (r) (hash-ref r 'in))))
            (k (sum (lambda (r) (hash-ref r 'chars))))))
  (newline)
  (define (better key) (for/list ([p done] #:when (> (frac (hash-ref (first p) key)) (frac (hash-ref (second p) key)))) (hash-ref (first p) 'task)))
  (define (worse key) (for/list ([p done] #:when (< (frac (hash-ref (first p) key)) (frac (hash-ref (second p) key)))) (hash-ref (first p) 'task)))
  (for ([key '(fidelity accepts conforms)])
    (printf "- ~a: FSH better on ~a tasks, JSON better on ~a, the same on ~a\n" key (length (better key)) (length (worse key))
            (- (length done) (length (better key)) (length (worse key))))))
