#lang racket/base

;;; query-checks.rkt — what a question's query should hold, read from the benchmark's TRAIN split,
;;; and the notes that say where a query does not.
;;;
;;;   racket -l- fhir-examples/agent-bench/fab/query-checks <questions_answers_sql_fhir.csv> <examples-dir>
;;;
;;; writes <examples-dir>/checks.json beside what make-examples wrote. `./answer` (answer.rkt)
;;; reads it, with the question, and prints a note for each of three slips an agent makes about
;;; once in fifty questions:
;;;   - a phrase of the question — a time ("today", "since 3 months ago", "this hospital stay") or
;;;     an averaging unit ("daily", "monthly") — whose condition the query lacks. The phrases and
;;;     the condition each is written as are the train split's own (`val_dict`);
;;;   - a name in the query (a drug, a label, a specimen) that the question does not give, and a
;;;     name the question does give — a value of the column the query compares names with — that
;;;     the query leaves out ("or urine" is the label `OR Urine`);
;;;   - a question that asks whether something is so ("Has …", "can you tell me if …") answered by
;;;     a query that selects a value: every such train query selects a comparison (`COUNT(*)>0`).
;;; A note is advice: the query still runs and the answer is still written. Two are decisive and
;;; begin `hold:` in place of `note:` — the question's averaging unit said only by other kinds
;;; than the one given, and a value selected where the question asks whether: over the scored
;;; runs no answer written under the first was right. `./answer` writes such an answer only
;;; when the same query is given a second time.
;;;
;;; Held to the train and validation splits' own queries: neither is said of any of them (the
;;; test below, when FAB_REPO is set). A third check was written and taken out: the conditions
;;; every train query of a kind has. A question of a kind the train split lacks (14 of the test
;;; split's kinds) is answered from the nearest kind, whose fixed conditions are not its own.
;;;
;;; A Checks is (hasheq 'phrases (listof Phrase) 'whether (listof n) 'when boolean 'ties (listof n)
;;;                     'times (listof TimeForms) 'one boolean):
;;; `one` says that every query of the train split selects one thing (`one-selected?`);
;;; `times` each kind of time phrase with the forms its words take (`time-forms`: what a reader of
;;; a question is shown the conditions of, `said-times`);
;;; `ties` the kinds whose examples return every row of the first or last time (`same-time-kinds`); `when` says
;;; that in the train split a query selects a time exactly where its question asks for one
;;; (`when-regular?`); `whether` the kinds whose
;;; train queries all select a comparison
;;; A Phrase is (hasheq 'form <pregexp source> 'conditions (listof Shape) 'example <sql> 'kinds (listof n))
;;; A Shape is a condition as text with its literals `?` and its columns `C`.

(require racket/file racket/list racket/string json
         (only-in "make-examples.rkt" train-questions kinds read-python))

(provide phrase-book phrase-notes name-literals name-notes column-names question-names unnamed-notes whole-name-notes
         query-shape make-checks query-notes comparison? asks-whether whether-kinds hold?
         time-select says-when opens-when? when-regular? same-time? same-time-kinds first-pick
         time-forms said-times selected one-selected?)

;; ---- text ----------------------------------------------------------------------------------------
(define (norm s) (string-downcase (string-trim (regexp-replace* #px"\\s+" s " "))))

;; ---- phrases ----------------------------------------------------------------------------------------
;; query-shape : string -> string   a query, or a condition, as it is compared: lower case, dates
;; and numbers `?`, a column `C`, no space beside a comma or a parenthesis
(define (query-shape sql)
  (define dated (regexp-replace* #px"\\b[0-9]+(\\.[0-9]+)?\\b" (regexp-replace* #px"'[0-9]{4}[-0-9: ]*'" (norm sql) "?") "?"))
  (regexp-replace* #px"\\s*([,()])\\s*" (regexp-replace* #px"\\b[a-z_]+\\.[a-z_]+\\b" dated "C") "\\1"))

;; condition-shapes : string -> (listof Shape)   a phrase's SQL (`AND a AND b`, `GROUP BY …`) as its conditions
(define (condition-shapes sql)
  (for/list ([c (in-list (regexp-split #px"\\bAND\\b" (regexp-replace #px"^\\s*AND\\b" sql "")))]
             #:unless (string=? (string-trim c) ""))
    (query-shape c)))

;; phrase-form : string -> string   the words of a phrase as a pattern: its numbers any numbers,
;; "month ago" also "months ago", a visit also a stay, an encounter or an admission, "current"
;; also "this"; a phrase about a visit without the words before its adjective
(define (phrase-form nlq)
  (define words (norm nlq))
  (define visit? (regexp-match? #px"(hospital|icu) visit$" words))
  (define core (if visit? (regexp-replace #px"^on the " words "") words))
  (define quoted (regexp-replace* #px"[0-9]+" (regexp-quote core) "[0-9]+"))
  (define plural (regexp-replace* #px"(day|month|year|hour) ago" quoted "\\1s? ago"))
  (define visits
    (if visit?
        (regexp-replace #px"^current" (regexp-replace #px"visit$" (regexp-replace #px"icu" plural "(?:icu|intensive care unit)") "(?:visit|stay|encounter|admission)") "(?:current|this)")
        plural))
  (string-append "\\b" visits
                 (if (regexp-match? #px"\\]\\+$" visits) "(?![/0-9-])(?! (?:day|month|year|hour)s? ago)" "")
                 "\\b"))

;; phrase-book : (listof Question) -> (listof Phrase)   every phrase the train split's questions
;; state a condition for: the time filters of a whole question and the averaging units; with the
;; kinds of question (their numbers, as make-examples numbers them) that say it
(define (phrase-book train)
  (define number (for/hash ([k (in-list (kinds train))] [i (in-naturals 1)]) (values (car k) i)))
  (define book (make-hash))   ; form -> (list example conditions kinds)
  (for ([q (in-list train)])
    (define v (read-python (hash-ref q 'val_dict)))
    (define kind (hash-ref number (hash-ref q 'template #f) #f))
    (define slots
      (append (for/list ([(k t) (in-hash (hash-ref v "time_placeholder" (hash)))] #:when (string-prefix? k "time_filter_global")) t)
              (for/list ([(k t) (in-hash (hash-ref v "op_placeholder" (hash)))] #:when (equal? k "unit_average")) t)))
    (for ([t (in-list slots)]
          #:when (and (hash? t) (non-empty-string? (hash-ref t "nlq" "")) (non-empty-string? (hash-ref t "sql" ""))))
      (define shapes (condition-shapes (hash-ref t "sql")))
      (when (pair? shapes)
        (hash-update! book (phrase-form (hash-ref t "nlq"))
                      (lambda (e) (list (car e) (remove-duplicates (cons (car shapes) (cadr e)))
                                        (if kind (remove-duplicates (cons kind (caddr e))) (caddr e))))
                      (list (string-trim (regexp-replace #px"^\\s*AND\\b" (hash-ref t "sql") "")) '() '())))))
  (for/list ([form (in-list (sort (hash-keys book) string<?))])
    (define e (hash-ref book form))
    (hasheq 'form form 'conditions (sort (cadr e) string<?) 'example (car e) 'kinds (sort (caddr e) <))))

;; phrase-notes : string string (listof Phrase) -> (listof (list words example kinds))   the phrases of
;; the question whose condition the query does not hold; of two phrases one inside the other
;; ("since 08/2136", "since 08") the longer is the question's
(define (phrase-notes question sql book)
  (define text (norm question))
  (define shape (query-shape sql))
  (define found
    (for*/list ([p (in-list book)] [m (in-value (regexp-match (pregexp (hash-ref p 'form)) text))] #:when m)
      (cons (car m) p)))
  (remove-duplicates
   (for/list ([f (in-list found)]
              #:unless (for/or ([g (in-list found)]) (and (not (equal? (car g) (car f))) (string-contains? (car g) (car f))))
              #:unless (for/or ([g (in-list found)])
                         (and (equal? (car g) (car f))
                              (for/or ([c (in-list (hash-ref (cdr g) 'conditions))]) (string-contains? shape c)))))
     (list (car f) (hash-ref (cdr f) 'example) (hash-ref (cdr f) 'kinds '())))
   #:key car))

;; ---- the kinds of time phrase a question says ----------------------------------------------------------
;; A TimeForms is (hasheq 'type string 'forms (listof <pregexp source>)): a kind of time phrase as
;; the benchmark names it ("rel-day-this", "abs-year-in", "exact-first"), and each form the train
;; split's questions word it in

;; time-slots : Question -> (listof (cons type words))   the time phrases a question holds
(define (time-slots q)
  (for/list ([(_ t) (in-hash (hash-ref (read-python (hash-ref q 'val_dict)) "time_placeholder" (hash)))]
             #:when (and (hash? t) (not (member (hash-ref t "type" "null") '("null" "")))
                         (non-empty-string? (hash-ref t "nlq" ""))))
    (cons (hash-ref t "type") (hash-ref t "nlq"))))

;; time-forms : (listof Question) -> (listof TimeForms)   in the order the kinds first appear
(define (time-forms train)
  (define-values (order forms)
    (for*/fold ([order '()] [forms (hash)]) ([q (in-list train)] [s (in-list (time-slots q))])
      (define form (phrase-form (cdr s)))
      (values (if (hash-has-key? forms (car s)) order (cons (car s) order))
              (hash-update forms (car s) (lambda (l) (if (member form l) l (cons form l))) '()))))
  (for/list ([type (in-list (reverse order))])
    (hasheq 'type type 'forms (sort (hash-ref forms type) string<?))))

;; said-times : string (listof TimeForms) -> (listof type)   the kinds of time phrase a question's
;; words hold. "Previous" is read as "last" ("in the previous month" is the phrase "last month").
;; It errs on the side of more: a word that only looks like a phrase ("the first", "last") counts.
(define (said-times question times)
  (define text (regexp-replace* #px"\\bprevious\\b" (norm question) "last"))
  (for/list ([t (in-list times)]
             #:when (for/or ([f (in-list (hash-ref t 'forms))]) (regexp-match? (pregexp f) text)))
    (hash-ref t 'type)))

;; ---- names ------------------------------------------------------------------------------------------
;; name-literals : string -> (listof string)   the names a query compares a column with (`= 'x'`,
;; `IN ( 'x', 'y' )`): not a time, a date or a number, and not what a dictionary row links to
(define (name-literals sql)
  (remove-duplicates
   (for*/list ([m (in-list (regexp-match* #px"\\b([a-z_]+\\.[a-z_]+)\\s*(?:=|IN)\\s*(\\(\\s*'[^']*'(?:\\s*,\\s*'[^']*')*\\s*\\)|'[^']*')" sql #:match-select values))]
               #:unless (regexp-match? #px"linksto$|time" (cadr m))
               [name (in-list (regexp-match* #px"'([^']*)'" (caddr m) #:match-select cadr))]
               #:unless (regexp-match? #px"^[-0-9: ./%]*$" name))
     name)))

;; column-names : string -> (listof (cons column (listof name)))   the names of a query by the
;; column each is compared with
(define (column-names sql)
  (define pairs
    (for*/list ([m (in-list (regexp-match* #px"\\b([a-z_]+\\.[a-z_]+)\\s*(?:=|IN)\\s*(\\(\\s*'[^']*'(?:\\s*,\\s*'[^']*')*\\s*\\)|'[^']*')" sql #:match-select values))]
                #:unless (regexp-match? #px"linksto$|time" (cadr m))
                [name (in-list (regexp-match* #px"'([^']*)'" (caddr m) #:match-select cadr))]
                #:unless (regexp-match? #px"^[-0-9: ./%]*$" name))
      (cons (cadr m) name)))
  (for/list ([col (in-list (remove-duplicates (map car pairs)))])
    (cons col (remove-duplicates (for/list ([p (in-list pairs)] #:when (equal? (car p) col)) (cdr p))))))

;; name-notes : string string (listof string) -> (listof string)   the names of the query that
;; neither the question (with what it assumes) gives nor every example of its kind has (a kind's
;; own constant: `admission_location = 'EMERGENCY ROOM'`)
(define (name-notes sql question examples)
  (define text (norm question))
  (define theirs (map norm examples))
  (for/list ([n (in-list (name-literals sql))]
             #:unless (string-contains? text (norm n))
             #:unless (and (pair? theirs)
                           (for/and ([e (in-list theirs)]) (string-contains? e (string-append "'" (norm n) "'")))))
    n))

;; question-names : string (listof string) -> (listof string)   the values (names as a column
;; spells them) that the question contains as whole words, a value inside a longer one left out;
;; a single short word (`IV`, `Void`) is not looked for: it is too often just a word
(define (question-names question values)
  (define text (norm question))
  (define (word-at? i n)
    (and (or (zero? i) (not (char-alphabetic? (string-ref text (sub1 i)))) ) (not (and (> i 0) (char-numeric? (string-ref text (sub1 i)))))
         (let ([j (+ i n)]) (or (= j (string-length text)) (not (or (char-alphabetic? (string-ref text j)) (char-numeric? (string-ref text j))))))))
  (define hits
    (for*/list ([v (in-list (remove-duplicates values))]
                [n (in-value (norm v))]
                #:when (or (>= (string-length n) 6) (string-contains? n " "))
                [at (in-value (for/first ([m (in-list (regexp-match-positions* (regexp-quote n) text))] #:when (word-at? (car m) (string-length n))) m))]
                #:when at)
      (list (car at) (cdr at) v)))
  (for/list ([h (in-list hits)]
             #:unless (for/or ([g (in-list hits)])
                        (and (not (and (= (car g) (car h)) (= (cadr g) (cadr h))))
                             (<= (car g) (car h)) (<= (cadr h) (cadr g)))))
    (caddr h)))

;; unnamed-notes : string string (column -> (listof string)) -> (listof (list column words value))
;; for each column the query compares names with: a value of that column the question contains
;; and the query does not name (nor names a part of: 'TF Residual' for "tf residual output")
(define (unnamed-notes sql question values-of)
  (for*/list ([cn (in-list (column-names sql))]
              [mine (in-value (map norm (cdr cn)))]
              [v (in-list (question-names question (values-of (car cn))))]
              #:unless (member (norm v) mine)
              #:unless (for/or ([m (in-list mine)]) (and (non-empty-string? m) (string-contains? (norm v) m))))
    (list (car cn) (norm v) v)))

;; whole-name-notes : string string (column -> (listof string)) -> (listof (list column words value others))
;; for each column the query compares names with: a value of that column the question contains
;; whole and the query names, beside names of the same column the question does not say (`others`).
;; The question meant that one name: "or urine" is the output `OR Urine`, not urine outputs
(define (whole-name-notes sql question values-of)
  (define text (norm question))
  (for*/list ([cn (in-list (column-names sql))]
              [mine (in-value (cdr cn))]
              [v (in-list (question-names question (values-of (car cn))))]
              #:when (member (norm v) (map norm mine))
              [others (in-value (for/list ([m (in-list mine)]
                                           #:unless (equal? (norm m) (norm v))
                                           #:unless (string-contains? text (norm m)))
                                  m))]
              #:when (pair? others))
    (list (car cn) (norm v) v others)))

;; ---- what is asked for ------------------------------------------------------------------------------
;; comparison? : string -> boolean   a query whose select list is a comparison: its 1/0 is yes/no
(define (comparison? sql)
  (define q (regexp-replace* #px"\\s+" sql " "))
  (define outer (regexp-replace* #px"\\([^()]*\\)" (regexp-replace* #px"\\([^()]*\\)" (regexp-replace* #px"\\([^()]*\\)" (regexp-replace* #px"\\([^()]*\\)" q "G") "G") "G") "G"))
  (define select-list (car (string-split (string-append outer " ") " FROM ")))
  (regexp-match? #px"^SELECT .*(>|<|=)" select-list))

;; asks-whether : string -> (or string #f)   the words by which a question asks whether something
;; is so: it opens with has/have/had/did/was/were, or asks "if"/"whether" inside a sentence ("can
;; you tell me if …"). A sentence that begins with "if" states a condition ("… ? if multiple
;; weights are measured daily, take the maximum."), and a question that ends on a choice asks
;; which ("… if patient 1 is male or female?")
(define (asks-whether question)
  (define q (norm question))
  (cond [(regexp-match #px"^(?:has|have|had|did|was|were)\\b" q) => car]
        [(regexp-match? #px"\\b\\w+ or \\w+\\s*[?.]*$" q) #f]
        [(regexp-match #px"[^.?!] ((?:if|whether))\\b" q) => cadr]
        [else #f]))

;; whether-kinds : (listof Question) -> (listof n)   the kinds (as make-examples numbers them)
;; whose train queries all select a comparison
(define (whether-kinds train)
  (for/list ([k (in-list (kinds train))] [i (in-naturals 1)]
             #:when (andmap (lambda (q) (comparison? (hash-ref q 'sql_query))) (cdr k)))
    i))

;; time-select : string -> (or string #f)   the time column a query selects, when that is all it
;; selects (`SELECT admissions.dischtime FROM …`): the schema's times are its columns named …time
(define (time-select sql)
  (cond [(regexp-match #px"^SELECT (?:DISTINCT )?([a-z_]+[.][a-z_]*time) FROM " (string-trim (regexp-replace* #px"\\s+" sql " "))) => cadr]
        [else #f]))

;; says-when : string -> (or string #f)   the word by which a question asks for a time
(define (says-when question)
  (cond [(regexp-match #px"\\b(when|times?|dates?)\\b" (norm question)) => cadr]
        [else #f]))

;; opens-when? : string -> boolean   a question that opens with "when"
(define (opens-when? question) (regexp-match? #px"^when\\b" (norm question)))

;; when-regular? : (listof Question) -> boolean   in the train split, every query that selects a
;; time answers a question that says when, time or date, and every question that opens with
;; "when" is answered by a query that selects a time
(define (when-regular? train)
  (and (for/and ([q (in-list train)] #:when (time-select (hash-ref q 'sql_query))) (and (says-when (hash-ref q 'question)) #t))
       (for/and ([q (in-list train)] #:when (opens-when? (hash-ref q 'question))) (and (time-select (hash-ref q 'sql_query)) #t))))

;; same-time? : string -> boolean   a query that returns what every row of the first or last time
;; says: `SELECT DISTINCT t.a FROM … AND t.charttime = ( SELECT DISTINCT t.charttime FROM … ORDER BY t.charttime DESC LIMIT 1 )`
(define (same-time? sql)
  (regexp-match? #px"^ ?SELECT DISTINCT [a-z_]+[.][a-z_]+ FROM .*= \\( ?SELECT DISTINCT [a-z_]+[.][a-z_]+ FROM .* ORDER BY [a-z_]+[.][a-z_]+ (?:ASC|DESC) LIMIT 1 ?\\)" (regexp-replace* #px"\\s+" sql " ")))

;; same-time-kinds : (listof Question) -> (listof n)   the kinds whose train queries are all of that form
(define (same-time-kinds train)
  (for/list ([k (in-list (kinds train))] [i (in-naturals 1)]
             #:when (andmap (lambda (q) (same-time? (hash-ref q 'sql_query))) (cdr k)))
    i))

;; first-pick : string -> (or (list selected rest order direction) #f)   a query that selects one
;; column of the row that is first or last by another: `SELECT a FROM … ORDER BY b DESC LIMIT 1`,
;; the ORDER BY its own (not a sub-select's)
(define (first-pick sql)
  (define m (regexp-match #px"^SELECT (?:DISTINCT )?([a-z_]+[.][a-z_]+) FROM (.*) ORDER BY ([a-z_]+[.][a-z_]+) (ASC|DESC) LIMIT 1$"
                          (string-trim (regexp-replace* #px"\\s+" sql " "))))
  (and m
       (let ([rest (caddr m)])
         (= (length (regexp-match* #rx"[(]" rest)) (length (regexp-match* #rx"[)]" rest))))
       (cdr m)))

;; selected : string -> (listof string)   what a query selects: the expressions of its SELECT list
;; (commas inside parentheses are an expression's own)
(define (selected sql)
  (define s (string-trim (regexp-replace* #px"\\s+" sql " ")))
  (define m (regexp-match-positions #px"^(?i:SELECT) (?:(?i:DISTINCT) )?" s))
  (define n (string-length s))
  (define (from? i) (and (<= (+ i 6) n) (string-ci=? (substring s i (+ i 6)) " FROM ")))
  (if (not m) '()
      (let loop ([i (cdar m)] [depth 0] [start (cdar m)] [acc '()])
        (define (done) (reverse (cons (string-trim (substring s start i)) acc)))
        (cond
          [(>= i n) (done)]
          [(char=? (string-ref s i) #\() (loop (add1 i) (add1 depth) start acc)]
          [(char=? (string-ref s i) #\)) (loop (add1 i) (sub1 depth) start acc)]
          [(and (zero? depth) (char=? (string-ref s i) #\,)) (loop (add1 i) depth (add1 i) (cons (string-trim (substring s start i)) acc))]
          [(and (zero? depth) (from? i)) (done)]
          [else (loop (add1 i) depth start acc)]))))

;; one-selected? : (listof Question) -> boolean   every train query selects one thing (2,098 of
;; 2,098: what a question asks for is one thing, and the day, the visit or the name a row belongs
;; to is not part of it)
(define (one-selected? train)
  (and (pair? train) (for/and ([q (in-list train)]) (= 1 (length (selected (hash-ref q 'sql_query)))))))

;; hold? : string -> boolean   a note that keeps the answer from being written the first time
(define (hold? note) (string-prefix? note "hold: "))

;; ---- the checks, made and applied ---------------------------------------------------------------------
;; make-checks : (listof Question) -> Checks
(define (make-checks train)
  (hasheq 'phrases (phrase-book train) 'whether (whether-kinds train) 'when (when-regular? train)
          'ties (same-time-kinds train) 'times (time-forms train) 'one (one-selected? train)))

;; query-notes : string (or string #f) Checks string string (listof string) [(column -> (listof string))]
;;               -> (listof string)
;; what to say of a query: `question` the question, `assumption` what it says to assume (a name
;; may be given there: "Search for 'Daily Weight' to find weight"; a phrase is the question's
;; alone), `examples` the queries of its kind's examples, `values-of` a column's distinct values
(define (query-notes sql kind checks question assumption examples [values-of (lambda (column) '())])
  (define whole (whole-name-notes sql question values-of))
  (append
   (for/list ([p (in-list (phrase-notes question sql (hash-ref checks 'phrases '())))])
     (define kinds (caddr p))
     ;; a phrase only a few kinds of question say, and the kind given is not one: the kind is the slip
     (define other-kind? (and kind (string->number kind) (pair? kinds) (<= (length kinds) 6) (not (member (string->number kind) kinds))))
     (string-append
      (format "~a: the question says \"~a\". A query of this schema writes that as `~a` (with its own column and time), and yours has no such condition."
              (if other-kind? "hold" "note") (car p) (cadr p))
      (if other-kind?
          (format " Kind ~a's questions do not say \"~a\"; the kinds whose questions do: ~a (`./kind ~a`). If yours is one of those, copy its example instead."
                  kind (car p) (string-join (map number->string kinds) ", ") (car kinds))
          "")))
   ;; a value where the question asks whether
   (let ([words (asks-whether question)] [whether (hash-ref checks 'whether '())])
     (if (and words (pair? whether) (not (comparison? sql)))
         (list (format "hold: the question asks whether something is so (\"~a …\"), and every query of this schema that answers such a question selects a comparison: `SELECT COUNT(*)>0 FROM …`, or one value `>`/`<` another (kinds ~a~a). Yours selects a value. Keep its conditions and select the comparison."
                       words (string-join (map number->string (take whether (min 4 (length whether)))) ", ")
                       (if (> (length whether) 4) ", …" "")))
         '()))
   ;; a time where the question asks for none, and none where it opens with "when"
   (let ([column (time-select sql)])
     (cond
       [(not (eq? (hash-ref checks 'when #f) #t)) '()]
       [(and column (not (says-when question)))
        (list (format "hold: the query selects a time (`~a`), and every query of this schema that selects one answers a question that says \"when\", \"time\" or \"date\". Yours says none of them: it asks what, which or how much. Keep the conditions and select what it asks for, by the schema's column for it."
                      column))]
       [(and (opens-when? question) (not column))
        (list "hold: the question opens with \"when\", and every query of this schema that answers such a question selects one time column and nothing else (`SELECT labevents.charttime FROM …`). Keep the conditions and select the time.")]
       [else '()]))
   ;; more than one thing selected
   (let ([things (selected sql)])
     (if (and (eq? (hash-ref checks 'one #f) #t) (> (length things) 1))
         (list (format "hold: the query selects ~a things (~a), and every query of this schema selects one: what the question asks for. The day, month or year a value belongs to, a visit's number or a name beside it is not part of the answer. Keep the conditions, the grouping and the order, and select that one thing."
                       (length things) (string-join (map (lambda (t) (format "`~a`" t)) things) ", ")))
         '()))
   (for/list ([w (in-list whole)])
     (format "note: the question's words \"~a\" are the name '~a' in `~a`, whole: a question gives a name in lower case inside its sentence, however much it reads like ordinary words. Name it alone: your query also names ~a, which the question does not say."
             (cadr w) (caddr w) (car w) (string-join (map (lambda (o) (format "'~a'" o)) (cadddr w)) ", ")))
   (for/list ([n (in-list (name-notes sql (string-append question " " assumption) examples))]
              #:unless (member n (append-map cadddr whole)))
     (format "note: your query names '~a', which the question does not." n))
   (for/list ([u (in-list (unnamed-notes sql question values-of))])
     (format "note: the question says \"~a\", which is '~a' in `~a`, and your query does not name it." (cadr u) (caddr u) (car u)))))

(module+ main
  (define args (current-command-line-arguments))
  (unless (= (vector-length args) 2)
    (raise-user-error "usage: query-checks <questions_answers_sql_fhir.csv> <examples-dir>"))
  (define checks (make-checks (train-questions (vector-ref args 0))))
  (call-with-output-file (build-path (vector-ref args 1) "checks.json") #:exists 'truncate
    (lambda (o) (write-json checks o)))
  (printf "~a phrases\n" (length (hash-ref checks 'phrases))))

(module+ test
  (require rackunit racket/set (only-in "make-sample.rkt" read-csv))
  (define q1 "SELECT transfers.careunit FROM transfers WHERE transfers.hadm_id IN ( SELECT admissions.hadm_id FROM admissions WHERE admissions.subject_id = 10004235 AND admissions.dischtime IS NULL ) AND transfers.careunit IS NOT NULL ORDER BY transfers.intime DESC LIMIT 1")
  ;; phrases
  (define (vd . slots) (format "{'op_placeholder': {~a}, 'time_placeholder': {~a}}"
                               (string-join (for/list ([s slots] #:when (eq? (car s) 'op)) (cadr s)) ", ")
                               (string-join (for/list ([s slots] #:when (eq? (car s) 'time)) (cadr s)) ", ")))
  (define (slot key nlq sql) (format "'~a': {'nlq': '~a', 'sql': \"~a\", 'type': 't'}" key nlq sql))
  (define train
    (list (hasheq 'template "T1" 'question "q" 'assumption "" 'sql_query "SELECT 1" 'val_dict (vd (list 'time (slot "time_filter_global1" "today" "AND datetime(chartevents.charttime,'start of day') = datetime('2133-12-31 00:00:00','start of day','-0 day')"))
                                (list 'time (slot "time_filter_exact1" "first" "ORDER BY chartevents.charttime ASC LIMIT 1"))))
          (hasheq 'template "T2" 'question "q" 'assumption "" 'sql_query "SELECT 1" 'val_dict (vd (list 'time (slot "time_filter_global1" "since 2 month ago" "AND datetime(labevents.charttime) >= datetime('2110-12-31 00:00:00','-2 month') AND strftime('%Y-%m-%d',labevents.charttime) <= '2110-12-31 23:59:00'"))
                                (list 'op (slot "unit_average" "monthly" "GROUP BY strftime('%Y-%m',chartevents.charttime)"))))
          (hasheq 'template "T1" 'question "q" 'assumption "" 'sql_query "SELECT 1" 'val_dict (vd (list 'time (slot "time_filter_global1" "on the current hospital visit" "AND admissions.dischtime IS NULL"))))
          (hasheq 'template "T1" 'question "q" 'assumption "" 'sql_query "SELECT 1" 'val_dict (vd (list 'time (slot "time_filter_global1" "since 2140" "AND strftime('%Y',labevents.charttime) >= '2140'"))))))
  (define book (phrase-book train))
  (check-equal? (length book) 5 "the exact-time slot is not a phrase of the whole question")
  (define (said question sql) (map car (phrase-notes question sql book)))
  (check-equal? (said "Today, when was the first time that patient 1 had the minimum spo2?"
                      "SELECT chartevents.charttime FROM chartevents WHERE chartevents.stay_id IN ( SELECT 1 ) ORDER BY chartevents.valuenum ASC LIMIT 1")
                '("today"))
  (check-equal? (said "When was the first spo2 of patient 1 today?"
                      "SELECT c.charttime FROM chartevents WHERE chartevents.stay_id IN ( SELECT 1 ) AND datetime( labevents.charttime, 'start of day' ) = datetime('2140-01-02 00:00:00','start of day','-0 day') ORDER BY chartevents.charttime ASC LIMIT 1")
                '() "another column, another time, other spacing")
  (check-equal? (said "Has amlodipine been prescribed for patient 1 in this hospital encounter?"
                      "SELECT COUNT(*)>0 FROM prescriptions WHERE prescriptions.hadm_id IN ( SELECT admissions.hadm_id FROM admissions WHERE admissions.subject_id = 1 )")
                '("this hospital encounter"))
  (check-equal? (said "Has amlodipine been prescribed for patient 1 during their current hospital stay?"
                      "SELECT COUNT(*)>0 FROM prescriptions WHERE prescriptions.hadm_id IN ( SELECT admissions.hadm_id FROM admissions WHERE admissions.subject_id = 1 AND admissions.dischtime IS NULL )")
                '())
  (check-equal? (said "What was the monthly weight of patient 1 since 3 months ago?" "SELECT MAX(chartevents.valuenum) FROM chartevents WHERE chartevents.stay_id IN ( SELECT 1 )")
                '("monthly" "since 3 months ago"))
  (check-equal? (said "What was the weight of patient 1 since 3 months ago?" "SELECT MAX(c.v) FROM c WHERE strftime('%Y',labevents.charttime) >= '2140'")
                '("since 3 months ago") "not the year form: \"since 3\" is inside the longer phrase")
  (check-equal? (said "What was the weight of patient 1 since 2141?" "SELECT MAX(c.v) FROM c WHERE strftime('%Y',labevents.charttime) >= '2141'") '())
  ;; what a query selects
  (check-equal? (selected "SELECT MAX(c.v) FROM c WHERE c.x IN ( SELECT a, b FROM d )") '("MAX(c.v)"))
  (check-equal? (selected "select distinct strftime('%Y', c.t),  MAX(c.v) from c group by strftime('%Y', c.t)") '("strftime('%Y', c.t)" "MAX(c.v)"))
  (check-equal? (selected "SELECT ( SELECT a.v FROM a WHERE x = 1 ) - ( SELECT a.v FROM a WHERE x = 2 )") '("( SELECT a.v FROM a WHERE x = 1 ) - ( SELECT a.v FROM a WHERE x = 2 )"))
  (check-equal? (selected "SELECT COUNT(*)>0 FROM p") '("COUNT(*)>0"))
  (check-true (one-selected? (list (hasheq 'sql_query "SELECT a.b FROM a") (hasheq 'sql_query "SELECT COUNT( DISTINCT a.b ) FROM a"))))
  (check-false (one-selected? (list (hasheq 'sql_query "SELECT a.b FROM a") (hasheq 'sql_query "SELECT a.b, a.c FROM a"))))
  (let ([notes (lambda (sql one) (filter (lambda (n) (regexp-match? #rx"selects [0-9]+ things" n))
                                         (query-notes sql #f (hasheq 'one one) "What was the yearly maximum output of patient 1?" "" '())))])
    (check-equal? (length (notes "SELECT strftime('%Y',o.t), MAX(o.v) FROM o GROUP BY strftime('%Y',o.t)" #t)) 1)
    (check-true (hold? (car (notes "SELECT strftime('%Y',o.t), MAX(o.v) FROM o GROUP BY strftime('%Y',o.t)" #t))))
    (check-equal? (notes "SELECT MAX(o.v) FROM o GROUP BY strftime('%Y',o.t)" #t) '())
    (check-equal? (notes "SELECT strftime('%Y',o.t), MAX(o.v) FROM o" #f) '() "said only where the train split is regular"))
  ;; the kinds of time phrase a question says
  (define (typed key nlq type) (format "'~a': {'nlq': '~a', 'sql': \"AND x\", 'type': '~a'}" key nlq type))
  (define timed
    (list (hasheq 'val_dict (vd (list 'time (typed "time_filter_global1" "last month" "rel-month-last")) (list 'time (typed "time_filter_exact1" "first" "exact-first"))))
          (hasheq 'val_dict (vd (list 'time (typed "time_filter_global1" "since 2 month ago" "rel-month-since"))))
          (hasheq 'val_dict (vd (list 'time (typed "time_filter_global1" "since 14 day ago" "rel-day-since")) (list 'time (typed "time_filter_exact1" "null" "null"))))
          (hasheq 'val_dict (vd (list 'time (typed "time_filter_global1" "on the last hospital visit" "rel-hosp-last"))))
          (hasheq 'val_dict "{}")))
  (define times (time-forms timed))
  (check-equal? (list->set (map (lambda (t) (hash-ref t 'type)) times))
                (set "rel-month-last" "exact-first" "rel-month-since" "rel-day-since" "rel-hosp-last") "a slot of no kind is none")
  (check-equal? (list->set (said-times "When was patient 1 first prescribed heparin in the previous month?" times)) (set "rel-month-last" "exact-first"))
  (check-equal? (said-times "What was the weight of patient 1 since 3 months ago?" times) '("rel-month-since"))
  (check-equal? (said-times "What did patient 1 weigh during their last hospital stay?" times) '("rel-hosp-last"))
  (check-equal? (said-times "What is the gender of patient 1?" times) '())
  ;; names
  (define q2 "SELECT o.charttime FROM outputevents WHERE outputevents.itemid IN ( SELECT d_items.itemid FROM d_items WHERE d_items.label IN ('Foley','OR Urine') AND d_items.linksto = 'outputevents' ) AND strftime('%Y-%m-%d',outputevents.charttime) >= '2119-02-26' AND outputevents.charttime = '2119-02-26 10:00:00'")
  (check-equal? (name-literals q2) '("Foley" "OR Urine"))
  (check-equal? (name-notes q2 "When did patient 1 last have or urine output since 02/26/2119?" '()) '("Foley"))
  (check-equal? (name-notes q2 "When did patient 1 last have or urine output?" '("SELECT 1 FROM d_items WHERE d_items.label = 'Foley'" "SELECT 1 FROM d_items WHERE d_items.label = 'Void'")) '("Foley")
                "a name one example has is that example's, not the kind's")
  (check-equal? (column-names q2) '(("d_items.label" "Foley" "OR Urine")))
  (define labels '("OR Urine" "Urine" "Foley" "Void" "TF Residual" "TF Residual Output" "Admission Type"))
  (check-equal? (question-names "When did patient 1 last have or urine output since 02/26/2119?" labels) '("OR Urine") "the longer name; not `Void`-like short words")
  (check-equal? (question-names "the total tf residual output of patient 1" labels) '("TF Residual Output"))
  (define (label-values col) (if (equal? col "d_items.label") labels '()))
  (check-equal? (unnamed-notes "SELECT 1 FROM d_items WHERE d_items.label IN ('Foley')" "When did patient 1 last have or urine output?" label-values)
                '(("d_items.label" "or urine" "OR Urine")))
  (check-equal? (whole-name-notes "SELECT 1 FROM d_items WHERE d_items.label IN ('Foley','OR Urine','PACU Urine')" "When did patient 1 last have or urine output?" label-values)
                '(("d_items.label" "or urine" "OR Urine" ("Foley" "PACU Urine"))))
  (check-equal? (whole-name-notes "SELECT 1 FROM d_items WHERE d_items.label = 'OR Urine'" "When did patient 1 last have or urine output?" label-values) '()
                "named alone")
  (check-equal? (whole-name-notes "SELECT 1 FROM d_items WHERE d_items.label IN ('OR Urine','Foley')" "the or urine and foley output of patient 1" label-values) '()
                "the question says both")
  (check-equal? (unnamed-notes "SELECT 1 FROM d_items WHERE d_items.label = 'TF Residual'" "the total tf residual output of patient 1" label-values) '()
                "the query names a part of it")
  (check-equal? (unnamed-notes "SELECT admissions.admission_type FROM admissions WHERE admissions.subject_id = 1" "What was the admission type of patient 1?" label-values) '()
                "a query that names nothing in that column is not asked about it")
  (check-equal? (name-notes "SELECT 1 FROM admissions WHERE admissions.admission_location = 'EMERGENCY ROOM' AND d_items.label = 'Daily Weight'"
                            "Has patient 1 been to the er? Search for 'Daily Weight' to find weight."
                            '("SELECT COUNT(*)>0 FROM admissions WHERE admissions.admission_location = 'EMERGENCY ROOM'"))
                '() "a name every example of the kind has, a name the assumption gives")
  ;; all of it
  (define checks (hasheq 'phrases book))
  (check-equal? (length (query-notes "SELECT transfers.careunit FROM transfers WHERE transfers.hadm_id IN ( SELECT 1 ) AND transfers.careunit = 'Ward 9'" "7" checks "Which unit was patient 1 in today?" "" '())) 2)
  (check-equal? (query-notes q1 "7" checks "Which care unit did patient 1 last enter on the current hospital visit?" "Search for 'Daily Weight' today." '()) '()
                "a phrase in what is assumed is not the question's")
  (check-regexp-match #rx"Kind 1's questions do not say \"monthly\"; the kinds whose questions do: 2 "
                      (car (query-notes "SELECT MAX(c.v) FROM c WHERE c.a = 1" "1" checks "What was the monthly weight of patient 1?" "" '())))
  (check-false (regexp-match? #rx"Kind" (car (query-notes "SELECT MAX(c.v) FROM c WHERE c.a = 1" "2" checks "What was the monthly weight of patient 1?" "" '())))
               "the kind given is one that says it")
  ;; the first or last row, and every row of the first or last time
  (check-equal? (first-pick "SELECT m.test_name FROM m WHERE m.hadm_id IN ( SELECT a.hadm_id FROM a WHERE a.s = 1 ) ORDER BY m.charttime DESC LIMIT 1")
                '("m.test_name" "m WHERE m.hadm_id IN ( SELECT a.hadm_id FROM a WHERE a.s = 1 )" "m.charttime" "DESC"))
  (check-false (first-pick "SELECT m.test_name FROM m WHERE m.hadm_id IN ( SELECT a.hadm_id FROM a WHERE a.s = 1 ORDER BY a.admittime DESC LIMIT 1 )")
               "the ORDER BY is a sub-select's")
  (check-false (first-pick "SELECT COUNT(*) FROM m ORDER BY m.charttime DESC LIMIT 1"))
  (check-true (same-time? "SELECT DISTINCT p.drug FROM p WHERE p.hadm_id IN ( SELECT 1 ) AND p.starttime = ( SELECT DISTINCT p.starttime FROM p WHERE p.hadm_id IN ( SELECT 1 ) ORDER BY p.starttime ASC LIMIT 1 )"))
  (check-false (same-time? "SELECT p.drug FROM p ORDER BY p.starttime ASC LIMIT 1"))
  (check-false (same-time? "SELECT ( SELECT c.v FROM c WHERE c.t = ( SELECT DISTINCT c.t FROM c ORDER BY c.t DESC LIMIT 1 ) ) - ( SELECT 1 )")
               "a difference of two such values is another kind of answer")
  (check-equal? (same-time-kinds (list (hasheq 'template "a" 'val_dict "{}" 'question "q" 'sql_query "SELECT p.drug FROM p ORDER BY p.starttime ASC LIMIT 1")
                                       (hasheq 'template "b" 'val_dict "{}" 'question "q" 'sql_query "SELECT DISTINCT p.drug FROM p WHERE p.starttime = ( SELECT DISTINCT p.starttime FROM p ORDER BY p.starttime ASC LIMIT 1 )")))
                '(2))
  ;; when
  (check-equal? (time-select "SELECT microbiologyevents.charttime FROM microbiologyevents WHERE a = 1 ORDER BY microbiologyevents.charttime DESC LIMIT 1") "microbiologyevents.charttime")
  (check-equal? (time-select "SELECT  DISTINCT admissions.dischtime\n FROM admissions") "admissions.dischtime")
  (check-false (time-select "SELECT microbiologyevents.test_name FROM microbiologyevents WHERE microbiologyevents.charttime = ( SELECT m.charttime FROM m )"))
  (check-false (time-select "SELECT strftime('%Y-%m',chartevents.charttime), MAX(chartevents.valuenum) FROM chartevents"))
  (check-equal? (says-when "What time was patient 1 discharged?") "time")
  (check-false (says-when "What microbiology tests did patient 1 have last in 12/this year?"))
  (check-true (opens-when? " When did patient 1 leave?"))
  (let ([regular (hash-set (hasheq 'phrases '()) 'when #t)]
        [times "SELECT microbiologyevents.charttime FROM microbiologyevents WHERE a = 1 ORDER BY microbiologyevents.charttime DESC LIMIT 1"])
    (define what (query-notes times "6" regular "What microbiology tests did patient 1 have last in 12/this year?" "" '()))
    (check-equal? (length what) 1)
    (check-true (hold? (car what)))
    (check-regexp-match #rx"selects a time \\(`microbiologyevents.charttime`\\)" (car what))
    (check-equal? (query-notes times "6" regular "When was the last microbiology test of patient 1?" "" '()) '())
    (check-equal? (query-notes times "6" (hasheq 'phrases '()) "What tests did patient 1 have?" "" '()) '() "no such regularity read from the train split: nothing said")
    (check-regexp-match #rx"opens with \"when\"" (car (query-notes "SELECT COUNT(*) FROM admissions WHERE a = 1" "29" regular "When was patient 1 admitted?" "" '())))
    (check-true (when-regular? (list (hasheq 'question "When did patient 1 leave?" 'sql_query "SELECT admissions.dischtime FROM admissions")
                                     (hasheq 'question "How many visits?" 'sql_query "SELECT COUNT(*) FROM admissions"))))
    (check-false (when-regular? (list (hasheq 'question "What did patient 1 have?" 'sql_query "SELECT admissions.dischtime FROM admissions")))))
  ;; whether
  (check-equal? (asks-whether "Has patient 1 been prescribed aspirin?") "has")
  (check-equal? (asks-whether "Can you tell me if the or urine event has occurred to patient 1 since 10/04/2119?") "if")
  (check-false (asks-whether "Can you tell me if patient 1 is male or female?") "a choice asks which")
  (check-false (asks-whether "What is the daily weight of patient 1? If multiple weights are measured daily, take the maximum.") "a condition")
  (check-false (asks-whether "What was the last weight of patient 1?"))
  (check-true (comparison? "SELECT COUNT(*)>0 FROM t WHERE t.a = 1"))
  (check-true (comparison? "SELECT ( SELECT t.v FROM t LIMIT 1 ) > ( SELECT t.v FROM t LIMIT 1 )"))
  (check-false (comparison? "SELECT SUM(t.v) FROM t WHERE t.a >= 1"))
  (define yes-no (hash-set checks 'whether '(2 4 5 9 11)))
  (define whether-note (query-notes "SELECT SUM(o.value) FROM o WHERE o.a = 1" "3" yes-no "Can you tell me if the void event has occurred to patient 1?" "" '()))
  (check-equal? (length whether-note) 1)
  (check-true (hold? (car whether-note)))
  (check-regexp-match #rx"asks whether something is so \\(\"if …\"\\).*kinds 2, 4, 5, 9, …" (car whether-note))
  (check-equal? (query-notes "SELECT COUNT(*)>0 FROM o WHERE o.a = 1" "3" yes-no "Can you tell me if the void event has occurred to patient 1?" "" '()) '())
  (check-equal? (query-notes "SELECT SUM(o.value) FROM o WHERE o.a = 1" "3" checks "Has patient 1 had any void output?" "" '()) '()
                "checks made before the kinds were recorded say nothing")
  (check-true (hold? (car (query-notes "SELECT MAX(c.v) FROM c WHERE c.a = 1" "1" checks "What was the monthly weight of patient 1?" "" '())))
              "an averaging unit only other kinds say holds the answer")
  (check-false (hold? (car (query-notes "SELECT MAX(c.v) FROM c WHERE c.a = 1" "2" checks "What was the monthly weight of patient 1?" "" '()))))
  ;; the benchmark's own queries are never noted (train: by construction for the fixed conditions; validation: not)
  (define repo (getenv "FAB_REPO"))
  (when (and repo (file-exists? (build-path repo "final_dataset" "questions_answers_sql_fhir.csv")))
    (define csv (build-path repo "final_dataset" "questions_answers_sql_fhir.csv"))
    (define tr (train-questions csv))
    (define real (make-checks tr))
    (define ks (kinds tr))
    (define rows (read-csv (file->string csv)))
    (define header (map string->symbol (car rows)))
    (define all (for/list ([r (in-list (cdr rows))] #:when (= (length r) (length header))) (for/hasheq ([k (in-list header)] [v (in-list r)]) (values k v))))
    ;; the kinds of time phrase a question holds are among those its words are read as: every
    ;; validation question (a reader shown only those conditions has each one it needs)
    (let* ([valid (filter (lambda (q) (equal? (hash-ref q 'split) "valid")) all)]
           [found (for/list ([q (in-list valid)]) (said-times (hash-ref q 'question) (hash-ref real 'times)))]
           [whole (for/sum ([q (in-list valid)] [f (in-list found)])
                    (if (andmap (lambda (s) (member (car s) f)) (time-slots q)) 1 0))])
      (printf "every kind of time phrase of a validation question is found in its words: ~a of ~a; kinds found a question: ~a of ~a\n"
              whole (length valid) (exact->inexact (/ (round (* 10 (/ (apply + (map length found)) (length valid)))) 10))
              (length (hash-ref real 'times)))
      (check-equal? whole (length valid)))
    ;; a column's values from the relational database, when FAB_REFERENCE names it
    (define reference (getenv "FAB_REFERENCE"))
    (define values-of
      (cond
        [(and reference (file-exists? reference))
         (define c ((dynamic-require 'db 'sqlite3-connect) #:database reference #:mode 'read-only))
         (define seen (make-hash))
         (lambda (column)
           (hash-ref! seen column
                      (lambda ()
                        (define parts (string-split column "."))
                        (with-handlers ([exn:fail? (lambda (_) '())])
                          (filter string? ((dynamic-require 'db 'query-list) c (format "SELECT DISTINCT ~a FROM ~a" (cadr parts) (car parts))))))))]
        [else (lambda (column) '())]))
    (define noted
      (for*/list ([q (in-list all)] #:when (member (hash-ref q 'split) '("train" "valid"))
                  [i (in-value (index-where ks (lambda (k) (equal? (car k) (hash-ref q 'template)))))]
                  [n (in-list (query-notes (hash-ref q 'sql_query) (and i (number->string (add1 i))) real
                                           (hash-ref q 'question) (hash-ref q 'assumption)
                                           (if i (map (lambda (e) (hash-ref e 'sql_query)) (cdr (list-ref ks i))) '())
                                           values-of))])
        (list (hash-ref q 'split) (substring (hash-ref q 'question_id) 0 8) n)))
    (for ([n (in-list (take noted (min 12 (length noted))))]) (eprintf "~s\n" n))
    (check-true (<= (length noted) 5) (format "~a notes on the train and validation splits' own queries" (length noted)))
    (printf "~a notes on ~a train and validation queries\n" (length noted) (count (lambda (q) (member (hash-ref q 'split) '("train" "valid"))) all))))
