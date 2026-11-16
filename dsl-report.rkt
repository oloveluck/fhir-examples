#lang racket/base

;;; dsl-report.rkt — the spec bench's two formats side by side: a DSL (FSH) against the
;;; representation it compiles to (FHIR JSON), on the same tasks, scored by the same oracle.
;;;
;;;   racket dsl-report.rkt [--prompt design|requirements] <task-dir>…
;;;
;;; Every run of the prompt kind in each task's results.jsonl counts (a task run three times per
;;; format is three runs): a run's last round is its score, its rounds' tokens are summed. First
;;; the totals per format, then each task's mean fidelity per format, then the missed facets by
;;; kind (from the last rounds' `missed_facets`).

(require racket/list racket/string racket/file json)

;; A Run is a hasheq: format task rounds clean fidelity accepts conforms missed in out think chars
;; runs-of : dir kind -> (listof Run)
(define (runs-of dir kind)
  (define f (build-path dir "results.jsonl"))
  (define lines (if (file-exists? f) (map string->jsexpr (file->lines f)) '()))
  (define mine (filter (lambda (s) (equal? (hash-ref s 'prompt "design") kind)) lines))
  (for/list ([rounds (in-list (group-by (lambda (s) (hash-ref s 'run)) mine))])
    (define final (last rounds))
    (define (n k) (for/sum ([s (in-list rounds)]) (let ([v (hash-ref s k 0)]) (if (real? v) v 0))))
    (define (pair k) (let ([v (hash-ref final k #f)]) (if (list? v) v '(0 0))))
    (hasheq 'format (hash-ref final 'format "fsh") 'task (hash-ref final 'task) 'rounds (length rounds)
            'answered (hash-ref final 'answered #f)
            'clean (and (hash-ref final 'answered #f) (eqv? 0 (hash-ref final 'candidate_diagnostics #f)))
            'fidelity (pair 'fidelity) 'accepts (pair 'accepts_published_examples)
            'conforms (pair 'examples_conform_to_published)
            'missed (let ([m (hash-ref final 'missed_facets '())]) (if (list? m) m '()))
            'in (n 'input_tokens) 'out (n 'output_tokens) 'think (n 'thinking_tokens)
            'chars (hash-ref final 'answer_chars 0))))

(define (frac p) (if (zero? (cadr p)) 1 (/ (car p) (cadr p))))
(define (pct x) (format "~a%" (/ (round (* 1000 x)) 10.0)))
(define (k x) (format "~ak" (/ (round (/ x 100)) 10.0)))
(define (mean xs) (if (null? xs) 0 (/ (apply + xs) (length xs))))
(define formats '(("fsh" . "FSH (the DSL)") ("json" . "FHIR JSON (the representation)")))

(module+ main
  (define args (vector->list (current-command-line-arguments)))
  (define kind (cond [(member "--prompt" args) => cadr] [else "design"]))
  (define dirs (let loop ([as args]) (cond [(null? as) '()] [(equal? (car as) "--prompt") (loop (cddr as))] [else (cons (car as) (loop (cdr as)))])))
  (define runs (append* (for/list ([d (in-list dirs)]) (runs-of d kind))))
  (define (of fmt) (filter (lambda (r) (equal? (hash-ref r 'format) fmt)) runs))
  (printf "Prompt: ~a. ~a runs over ~a tasks.\n\n" kind (length runs) (length (remove-duplicates (map (lambda (r) (hash-ref r 'task)) runs))))
  (printf "| format | runs | clean at the end | facets right | mean fidelity | published examples accepted | own examples conforming | rounds / run | answer tokens / run | thinking tokens / run | input tokens / run |\n|---|---|---|---|---|---|---|---|---|---|---|\n")
  (for ([f (in-list formats)])
    (define rs (of (car f)))
    (define (sum g) (for/sum ([r (in-list rs)]) (g r)))
    (define (pairsum key) (list (sum (lambda (r) (car (hash-ref r key)))) (sum (lambda (r) (cadr (hash-ref r key))))))
    (define n (max 1 (length rs)))
    (printf "| ~a | ~a | ~a | ~a/~a (~a) | ~a | ~a/~a | ~a/~a | ~a | ~a | ~a | ~a |\n" (cdr f) (length rs)
            (count (lambda (r) (hash-ref r 'clean)) rs)
            (car (pairsum 'fidelity)) (cadr (pairsum 'fidelity)) (pct (frac (pairsum 'fidelity)))
            (pct (mean (map (lambda (r) (frac (hash-ref r 'fidelity))) rs)))
            (car (pairsum 'accepts)) (cadr (pairsum 'accepts)) (car (pairsum 'conforms)) (cadr (pairsum 'conforms))
            (/ (round (* 100 (/ (sum (lambda (r) (hash-ref r 'rounds))) n))) 100.0)
            (k (/ (sum (lambda (r) (- (hash-ref r 'out) (hash-ref r 'think)))) n))
            (k (/ (sum (lambda (r) (hash-ref r 'think))) n))
            (k (/ (sum (lambda (r) (hash-ref r 'in))) n))))
  (newline)
  (printf "| task | FSH: mean fidelity (runs) | JSON: mean fidelity (runs) |\n|---|---|---|\n")
  (define tasks (sort (remove-duplicates (map (lambda (r) (hash-ref r 'task)) runs)) string<?))
  (define-values (fsh-wins json-wins)
    (for/fold ([a 0] [b 0]) ([t (in-list tasks)])
      (define (m fmt) (let ([rs (filter (lambda (r) (equal? (hash-ref r 'task) t)) (of fmt))]) (cons (mean (map (lambda (r) (frac (hash-ref r 'fidelity))) rs)) (length rs))))
      (define x (m "fsh")) (define y (m "json"))
      (printf "| ~a | ~a (~a) | ~a (~a) |\n" t (pct (car x)) (cdr x) (pct (car y)) (cdr y))
      (values (if (> (car x) (car y)) (add1 a) a) (if (< (car x) (car y)) (add1 b) b))))
  (printf "\nFSH's mean fidelity is higher on ~a tasks, JSON's on ~a, equal on ~a.\n\n" fsh-wins json-wins (- (length tasks) fsh-wins json-wins))
  (printf "Missed facets by kind (all runs):\n\n| format | ~a |\n|---|~a\n"
          (string-join '("min" "max" "mustSupport" "type" "binding" "fixed/pattern" "slicing" "sliceName") " | ")
          (string-append* (for/list ([_ (in-range 8)]) "---|")))
  (for ([f (in-list formats)])
    (define kinds (for*/list ([r (in-list (of (car f)))] [m (in-list (hash-ref r 'missed))])
                    (let ([kd (cadr m)]) (if (regexp-match? #rx"^(fixed|pattern)" kd) "fixed/pattern" kd))))
    (printf "| ~a | ~a |\n" (cdr f)
            (string-join (for/list ([kd '("min" "max" "mustSupport" "type" "binding" "fixed/pattern" "slicing" "sliceName")])
                           (number->string (count (lambda (x) (equal? x kd)) kinds)))
                         " | "))))
