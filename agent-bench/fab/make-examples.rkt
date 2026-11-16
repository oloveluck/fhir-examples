#lang racket/base

;;; make-examples.rkt — how FHIR-AgentBench's questions are answered over its schema, from its TRAIN
;;; split: the kinds of question, worked examples of each, and how each time phrase is written.
;;;
;;;   racket -l- fhir-examples/agent-bench/fab/make-examples <questions_answers_sql_fhir.csv> <out-dir>
;;;
;;; writes <out-dir>/kinds.md      the kinds of question, numbered (a kind's slots in braces)
;;;        <out-dir>/<n>.md        kind n: a question or two of that kind, what each assumes, its query
;;;        <out-dir>/phrases.md    each kind of time phrase ("today", "since 2 month ago", "on the
;;;                                current hospital visit") with the condition it is written as
;;;
;;; The benchmark's questions are 76 templates filled in, and each template has one way of being
;;; answered: which visit "the last hospital visit" is, how "since 4 months ago" and "this year" are
;;; counted from the assumed current time, what is returned when two records tie. Those are the
;;; benchmark's definitions, and its train split states them: as queries, and (in `val_dict`) as the
;;; condition each phrase of a question stands for. An agent answering a test question reads the
;;; example of its kind and writes its query the same way.
;;;
;;; Only the train split is read: a test or validation question is never an example.

(require racket/file racket/list racket/string racket/match
         (only-in "make-sample.rkt" read-csv))

(provide train-questions kinds phrases read-python)

;; A Question is a (hash column -> string), a row of the benchmark's CSV.

;; train-questions : csv-file -> (listof Question)
(define (train-questions csv-file)
  (define rows (read-csv (file->string csv-file)))
  (define header (map string->symbol (car rows)))
  (for/list ([r (in-list (cdr rows))]
             #:when (and (= (length r) (length header))
                         (equal? (list-ref r (index-of header 'split)) "train")))
    (for/hasheq ([k (in-list header)] [v (in-list r)]) (values k v))))

;; ---- a Python literal, read --------------------------------------------------------------------
;; The CSV's `val_dict` column is a Python dict as `repr` prints it.
;; A PyValue is one of: string | number | #t | #f | 'none | (listof PyValue) | (hash string -> PyValue)

;; read-python : string -> PyValue
(define (read-python s)
  (define n (string-length s))
  (define (skip i) (if (and (< i n) (memv (string-ref s i) '(#\space #\newline #\tab #\return))) (skip (add1 i)) i))
  ;; value : index -> (values PyValue index)
  (define (value i0)
    (define i (skip i0))
    (define c (string-ref s i))
    (cond
      [(memv c '(#\' #\")) (quoted i c)]
      [(char=? c #\{) (items (add1 i) #\} (lambda (j) (let*-values ([(k j) (value j)] [(v j) (value (add1 (skip j)))]) (values (cons k v) j)))
                             (lambda (ps) (for/hash ([p (in-list ps)]) (values (car p) (cdr p)))))]
      [(memv c '(#\[ #\()) (items (add1 i) (if (char=? c #\[) #\] #\)) value values)]
      [else
       (define j (let loop ([j i]) (if (and (< j n) (not (memv (string-ref s j) '(#\, #\} #\] #\) #\: #\space)))) (loop (add1 j)) j)))
       (define word (substring s i j))
       (values (match word ["None" 'none] ["True" #t] ["False" #f] [_ (or (string->number word) (error 'read-python "~s at ~a" word i))]) j)]))
  ;; items : index closer (index -> (values X index)) ((listof X) -> PyValue) -> (values PyValue index)
  (define (items i0 close one made)
    (let loop ([i (skip i0)] [acc '()])
      (cond
        [(char=? (string-ref s i) close) (values (made (reverse acc)) (add1 i))]
        [(char=? (string-ref s i) #\,) (loop (skip (add1 i)) acc)]
        [else (let-values ([(x j) (one i)]) (loop (skip j) (cons x acc)))])))
  ;; quoted : index quote-char -> (values string index)
  (define (quoted i q)
    (let loop ([j (add1 i)] [acc '()])
      (define c (string-ref s j))
      (cond
        [(char=? c q) (values (list->string (reverse acc)) (add1 j))]
        [(char=? c #\\) (loop (+ j 2) (cons (match (string-ref s (add1 j)) [#\n #\newline] [#\t #\tab] [e e]) acc))]
        [else (loop (add1 j) (cons c acc))])))
  (let-values ([(v _) (value 0)]) v))

;; ---- kinds -------------------------------------------------------------------------------------
;; time-types : Question -> (listof string)   the kinds of time phrase a question holds
(define (time-types q)
  (define slots (hash-ref (read-python (hash-ref q 'val_dict)) "time_placeholder" (hash)))
  (sort (for/list ([(_ t) (in-hash slots)]) (hash-ref t "type" "")) string<?))

;; kinds : (listof Question) -> (listof (cons template (listof Question)))   each template in the
;; order the templates first appear, with its first question and, when there is one, the first
;; whose time phrases are of other kinds
(define (kinds train)
  (for/list ([t (in-list (remove-duplicates (map (lambda (q) (hash-ref q 'template)) train)))])
    (define qs (filter (lambda (q) (equal? (hash-ref q 'template) t)) train))
    (define first-types (time-types (car qs)))
    (define other (findf (lambda (q) (not (equal? (time-types q) first-types))) (cdr qs)))
    (cons t (if other (list (car qs) other) (list (car qs))))))

;; ---- phrases -------------------------------------------------------------------------------------
;; A Phrase is (list type words condition current-time): a kind of time phrase, as one train
;; question words it, the condition its query writes for it, and the time that question assumes

;; phrases : (listof Question) -> (listof Phrase)   one per kind, in the order the kinds first appear
(define (phrases train)
  (define seen (make-hash))
  (for*/list ([q (in-list train)]
              [(_ t) (in-hash (hash-ref (read-python (hash-ref q 'val_dict)) "time_placeholder" (hash)))]
              #:when (let ([type (hash-ref t "type" "null")])
                       (and (not (equal? type "null")) (non-empty-string? (hash-ref t "sql" ""))
                            (not (hash-ref seen type #f)) (hash-set! seen type #t) #t)))
    (list (hash-ref t "type") (hash-ref t "nlq") (hash-ref t "sql")
          (match (regexp-match #px"current time is ([0-9: -]+)" (hash-ref q 'assumption))
            [(list _ at) (string-trim at)]
            [_ #f]))))

;; ---- written -------------------------------------------------------------------------------------
(define (one-line s) (string-normalize-spaces s))

;; kinds-text : (listof kind) -> string
(define (kinds-text ks)
  (string-join (for/list ([k (in-list ks)] [i (in-naturals 1)]) (format "~a. ~a" i (one-line (car k)))) "\n"))

;; kind-text : kind -> string
(define (kind-text k)
  (string-append
   (format "Kind: ~a\n" (one-line (car k)))
   (string-append*
    (for/list ([q (in-list (cdr k))])
      (format "\nQ: ~a\nAssume: ~a\nSQL: ~a\n"
              (one-line (hash-ref q 'question))
              (let ([a (one-line (hash-ref q 'assumption))]) (if (string=? a "") "(nothing)" a))
              (one-line (hash-ref q 'sql_query)))))))

;; phrases-text : (listof Phrase) -> string
(define (phrases-text ps)
  (string-join
   (for/list ([p (in-list ps)])
     (match-define (list _ words condition at) p)
     (format "- \"~a\"~a: `~a`" words (if (and at (regexp-match? (regexp-quote (substring at 0 10)) condition)) (format " (the current time ~a)" at) "") (one-line condition)))
   "\n"))

(module+ main
  (define args (current-command-line-arguments))
  (unless (= (vector-length args) 2)
    (raise-user-error "usage: make-examples <questions_answers_sql_fhir.csv> <out-dir>"))
  (define train (train-questions (vector-ref args 0)))
  (define out (vector-ref args 1))
  (make-directory* out)
  (define ks (kinds train))
  (display-to-file (kinds-text ks) (build-path out "kinds.md") #:exists 'truncate)
  (for ([k (in-list ks)] [i (in-naturals 1)])
    (display-to-file (kind-text k) (build-path out (format "~a.md" i)) #:exists 'truncate))
  (define ps (phrases train))
  (display-to-file (phrases-text ps) (build-path out "phrases.md") #:exists 'truncate)
  (printf "~a kinds of question, ~a kinds of time phrase, from ~a train questions\n" (length ks) (length ps) (length train)))

(module+ test
  (require rackunit)
  (check-equal? (read-python "{'a': {'nlq': 'today', 'sql': \"AND x = 'y'\", 'col': ['t.c'], 'n': 23.0, 'k': None}, 'b': {}}")
                (hash "a" (hash "nlq" "today" "sql" "AND x = 'y'" "col" '("t.c") "n" 23.0 "k" 'none) "b" (hash)))
  (check-equal? (read-python "{'s': 'it\\'s', 't': (1, 2), 'ok': True}") (hash "s" "it's" "t" '(1 2) "ok" #t))
  (define f (make-temporary-file "examples-~a.csv"))
  (define (vd type nlq sql) (format "\"{'time_placeholder': {'time_filter_global1': {'nlq': '~a', 'sql': \"\"~a\"\", 'type': '~a'}}}\"" nlq sql type))
  (display-to-file (string-append "split,question_id,question,sql_query,true_answer,assumption,template,val_dict\n"
                                  "train,a,Q one?,SELECT 1,[[1]],Assume the current time is 2133-12-31 23:59:00.,T1 {x}," (vd "rel-day-this" "today" "AND d(c) = d('2133-12-31 00:00:00')") "\n"
                                  "test,b,Q two?,SELECT 2,[[2]],,T2 {x}," (vd "abs-year-in" "in 2140" "AND y(c) = '2140'") "\n"
                                  "train,c,Q three?,SELECT 3,[[3]],now,T1 {x}," (vd "rel-day-this" "today" "AND d(c) = d('2134-12-31 00:00:00')") "\n"
                                  "train,d,Q four?,SELECT 4,[[4]],now,T1 {x}," (vd "abs-year-in" "in 2142" "AND y(c) = '2142'") "\n"
                                  "train,e,Q five?,SELECT 5,[[5]],,T3,{}\n")
                   f #:exists 'truncate)
  (define train (train-questions f))
  (check-equal? (map (lambda (q) (hash-ref q 'question_id)) train) '("a" "c" "d" "e") "never a test question")
  (check-equal? (for/list ([k (in-list (kinds train))]) (cons (car k) (map (lambda (q) (hash-ref q 'question_id)) (cdr k))))
                '(("T1 {x}" "a" "d") ("T3" "e"))
                "a kind's first question, and the first whose time phrases are of another kind")
  (check-equal? (phrases train)
                '(("rel-day-this" "today" "AND d(c) = d('2133-12-31 00:00:00')" "2133-12-31 23:59:00")
                  ("abs-year-in" "in 2142" "AND y(c) = '2142'" #f)))
  (check-regexp-match #rx"\"today\" \\(the current time 2133-12-31 23:59:00\\): `AND d" (phrases-text (phrases train)))
  (delete-file f))
