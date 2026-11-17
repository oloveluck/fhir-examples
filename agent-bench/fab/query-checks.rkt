#lang racket/base

;;; query-checks.rkt — what a question's query should hold, read from the benchmark's TRAIN split,
;;; and the notes that say where a query does not.
;;;
;;;   racket -l- fhir-examples/agent-bench/fab/query-checks <questions_answers_sql_fhir.csv> <examples-dir>
;;;
;;; writes <examples-dir>/checks.json beside what make-examples wrote. `./answer` (answer.rkt)
;;; reads it, with the question, and prints a note for each of two slips an agent makes about
;;; once in fifty questions:
;;;   - a phrase of the question — a time ("today", "since 3 months ago", "this hospital stay") or
;;;     an averaging unit ("daily", "monthly") — whose condition the query lacks. The phrases and
;;;     the condition each is written as are the train split's own (`val_dict`);
;;;   - a name in the query (a drug, a label, a specimen) that the question does not give, and a
;;;     name the question does give — a value of the column the query compares names with — that
;;;     the query leaves out ("or urine" is the label `OR Urine`).
;;; A note is advice: the query still runs and the answer is still written.
;;;
;;; Held to the train and validation splits' own queries: neither is said of any of them (the
;;; test below, when FAB_REPO is set). A third check was written and taken out: the conditions
;;; every train query of a kind has. A question of a kind the train split lacks (14 of the test
;;; split's kinds) is answered from the nearest kind, whose fixed conditions are not its own.
;;;
;;; A Checks is (hasheq 'phrases (listof Phrase))
;;; A Phrase is (hasheq 'form <pregexp source> 'conditions (listof Shape) 'example <sql> 'kinds (listof n))
;;; A Shape is a condition as text with its literals `?` and its columns `C`.

(require racket/file racket/list racket/string json
         (only-in "make-examples.rkt" train-questions kinds read-python))

(provide phrase-book phrase-notes name-literals name-notes column-names question-names unnamed-notes
         query-shape make-checks query-notes)

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

;; ---- the checks, made and applied ---------------------------------------------------------------------
;; make-checks : (listof Question) -> Checks
(define (make-checks train) (hasheq 'phrases (phrase-book train)))

;; query-notes : string (or string #f) Checks string string (listof string) [(column -> (listof string))]
;;               -> (listof string)
;; what to say of a query: `question` the question, `assumption` what it says to assume (a name
;; may be given there: "Search for 'Daily Weight' to find weight"; a phrase is the question's
;; alone), `examples` the queries of its kind's examples, `values-of` a column's distinct values
(define (query-notes sql kind checks question assumption examples [values-of (lambda (column) '())])
  (append
   (for/list ([p (in-list (phrase-notes question sql (hash-ref checks 'phrases '())))])
     (define kinds (caddr p))
     (string-append
      (format "note: the question says \"~a\". A query of this schema writes that as `~a` (with its own column and time), and yours has no such condition." (car p) (cadr p))
      ;; a phrase only a few kinds of question say, and the kind given is not one: the kind is the slip
      (if (and kind (string->number kind) (pair? kinds) (<= (length kinds) 6) (not (member (string->number kind) kinds)))
          (format " Kind ~a's questions do not say \"~a\"; the kinds whose questions do: ~a (`cat examples/~a.md`). If yours is one of those, copy its example instead."
                  kind (car p) (string-join (map number->string kinds) ", ") (car kinds))
          "")))
   (for/list ([n (in-list (name-notes sql (string-append question " " assumption) examples))])
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
  (require rackunit (only-in "make-sample.rkt" read-csv))
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
