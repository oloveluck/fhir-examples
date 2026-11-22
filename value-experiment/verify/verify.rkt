#lang racket/base

;;; verify.rkt — experiment V of value-experiment/PROTOCOL.md: S's forty implementations, each
;;; checked and corrected by an agent that has its description alone (R), the authors' expected
;;; answers for the sample patients (T), or the specification executed as an oracle (O), and held
;;; to the authors' held-out cases before and after.
;;;
;;;   racket verify.rkt run OUT [--arms R,T,O] [--only id,id] [--parallel 6] [--model M] [--resume]
;;;   racket verify.rkt score OUT     every implementation, as it started and as each session left it,
;;;                                   run over every case of its measure (spec-first's scorer)
;;;   racket verify.rkt report OUT    the comparison the protocol states
;;;   racket verify.rkt changes OUT   each held-out answer a session fixed or broke
;;;   racket verify.rkt broken OUT    the answers a session broke, by what broke them
;;;   racket verify.rkt keep OUT FILE the scored run as one file, which report, changes and broken
;;;                                   read in place of OUT
;;;
;;; Data definitions.
;;; A Start is a string: the id of one of S's implementations, "<measure's short name>-<N|S>-<i>";
;;;   its measure and its origin (N: written from the narrative; S: from the CQL) are read from it.
;;; An Arm is 'R | 'T | 'O.
;;; A Rights is (hash case boolean): an implementation's held-out cases, right or not.
;;; A Check is (review start measure origin before after cost belief): a start, its Rights before,
;;;   (hash Arm Rights) after each arm's session, (hash Arm (hasheq symbol real)) each session's
;;;   cost, (hash Arm (or/c boolean 'none)) what each session wrote it believes.

(require racket/file racket/list racket/string racket/math racket/runtime-path json
         "../spec-first/materials.rkt"
         (only-in "../spec-first/spec-first.rkt" score-one!)
         (only-in "oracle.rkt" oracle)
         (only-in "../analysis.rkt" verdict-of interval)
         (only-in "../../agent-bench/run-agent.rkt" run-item in-parallel audit current-resume? read-json-file write-json-file))

(provide (struct-out review) arms start-measure start-origin check-prompt
         share-after share-before fixed broken difference bootstrap-difference sign-flip-p keep! kept)

(struct review (start measure origin before after cost belief) #:transparent)

(define arms '(R T O))
(define-runtime-path implementations "../spec-first/implementations")

;; ---- the starting implementations --------------------------------------------------------------------
;; starts : -> (listof Start)   in name order
(define (starts)
  (sort (for/list ([d (in-list (directory-list implementations))]
                   #:when (file-exists? (build-path implementations d "measure.py")))
          (path->string d))
        string<?))

;; start-measure : Start -> measure
(define (start-measure s)
  (define short (car (string-split s "-")))
  (or (findf (lambda (m) (equal? (short-name m) short)) measures)
      (raise-user-error 'verify "no measure is called ~a" short)))
;; start-origin : Start -> 'N | 'S
(define (start-origin s) (string->symbol (cadr (string-split s "-"))))

;; ---- a checker's directory and prompt ----------------------------------------------------------------
;; arm-sentence : Arm -> string   what the arm adds, as its file is listed
(define (arm-sentence arm)
  (case arm
    [(R) ""]
    [(T) "- expected.json: the measure authors' expected four answers for each patient of sample/\n"]
    [(O) (string-append
          "- oracle.rkt: `racket oracle.rkt` runs the measure's published specification over each patient of sample/ and prints "
          "its four answers; `racket oracle.rkt DIR` does so for the patients of another directory\n")]))

;; check-prompt : measure Origin Arm -> string   the same for every arm but for the line that
;; names what the arm adds
(define (check-prompt m origin arm)
  (string-append
   "This directory holds an implementation of a clinical quality measure as one Python function, measure.py, "
   "written by someone else. Check it, and correct every error you find in it.\n\n"
   (format "The measure: ~a. " (measure-title m))
   (case origin
     [(N) "It is described in MEASURE.md: the measure's published description and the criteria of each population, in English."]
     [(S) (format "It is specified in Clinical Quality Language (CQL): spec/~a.cql and the libraries it includes, all in spec/. MEASURE.md says which of its definitions is which population." m)])
   "\n\nIn this directory:\n"
   "- measure.py: the implementation to check\n"
   (case origin
     [(N) "- MEASURE.md: the measure, in English\n"]
     [(S) "- MEASURE.md and spec/: the measure, in CQL\n"])
   "- CONTRACT.md: the function's contract\n"
   "- terminology.md and valuesets.json: the value sets and codes of the measure, by name\n"
   "- sample/: the records of a few test patients (FHIR R4 JSON, a directory a patient)\n"
   "- try.py: `python3 try.py` runs measure.py over sample/ and prints what it answers for each patient; "
   "`python3 try.py --cases DIR` does so for the patients of another directory\n"
   (arm-sentence arm)
   "\nYou may write further patients (a directory each, of FHIR JSON files like the sample's) to test with. "
   "measure.py will be run on other patients than the sample's, and judged by whether each of the four answers is what "
   "the measure's authors expect for each patient.\n\n"
   "Use only this directory and Python 3's standard library. Read nothing outside it, not the source of any installed "
   "software either: what you are given is what there is. No network, no packages.\n\n"
   "When you are done, write the file verdict.json: {\"correct\": true} if you believe measure.py now gives the expected "
   "answers for every patient, {\"correct\": false} if you believe errors remain. Then end with one short line."))

;; prepare-check! : Start Arm dir -> void   the implementer's own material, the implementation, and
;; what the arm adds
(define (prepare-check! s arm dir)
  (define m (start-measure s))
  (prepare-task! m (start-origin s) dir)
  (copy-file (build-path implementations s "measure.py") (build-path dir "measure.py") #t)
  (case arm
    [(T) (write-json-file (build-path dir "expected.json")
                          (for/hasheq ([c (in-list (case-ids m))] #:when (sample-case? m c))
                            (values (string->symbol c)
                                    (for/hasheq ([(p v) (in-hash (case-expected m c))]) (values (string->symbol p) v)))))]
    [(O) (display-to-file
          (string-append
           "#lang racket/base\n"
           ";; The measure's published specification, executed.\n"
           ";;   racket oracle.rkt          its four answers for each patient of sample/\n"
           ";;   racket oracle.rkt DIR      for each patient of DIR (a directory a patient, of FHIR JSON files)\n"
           "(require (lib \"fhir-examples/value-experiment/verify/oracle.rkt\"))\n"
           (format "(oracle-main ~s)\n" m))
          (build-path dir "oracle.rkt") #:exists 'truncate)]
    [else (void)]))

;; ---- run ----------------------------------------------------------------------------------------------
(define builtin '("Bash" "Read" "Write" "Edit" "Glob" "Grep"))
;; allowed : Arm -> (listof string)   Python and files for every arm; the oracle's one command for O
(define (allowed arm)
  (append '("Bash(python3:*)" "Bash(ls:*)" "Bash(cat:*)" "Bash(head:*)" "Bash(tail:*)" "Bash(grep:*)" "Bash(wc:*)"
            "Bash(mkdir:*)" "Bash(cp:*)" "Bash(diff:*)" "Read" "Write" "Edit" "Glob" "Grep")
          (if (eq? arm 'O) '("Bash(racket oracle.rkt:*)") '())))
;; what a session's commands must not name: the network, where the material came from, and any
;; use of the toolkit but the oracle's own command
(define forbidden '("urllib" "requests" "socket" "pip " "curl" "wget" "git clone" "github" "/home/" "/usr/" "qicore-2024"
                    "ecqm-content" "fhir-examples" "racket -" "raco " "collection-path"))

(define (check-id s arm) (format "~a-~a" s arm))

;; session-turns : how many model turns a session is given, in every arm (the trial's oracle session
;; took 78 and 3.5 million input tokens)
(define session-turns 60)

;; run-one! : dir Start Arm model -> void
(define (run-one! out s arm model)
  (define id (check-id s arm))
  (define work (build-path out id))
  (define rec
    (run-item id (check-prompt (start-measure s) (start-origin s) arm) work model (allowed arm)
              #:prepare (lambda () (prepare-check! s arm work))
              #:builtin builtin #:timeout 3000 #:max-turns session-turns))
  (define bad (audit rec forbidden))
  (unless (null? bad) (display-lines-to-file bad (build-path work "AUDIT") #:exists 'truncate))
  (printf "~a ~as in ~a out ~a turns ~a~a~a\n" id (hash-ref rec 'seconds) (hash-ref rec 'input_tokens)
          (hash-ref rec 'output_tokens) (hash-ref rec 'turns)
          (if (file-exists? (build-path work "verdict.json")) "" "  no verdict")
          (if (null? bad) "" "  AUDIT"))
  (flush-output))

;; ---- score and read ---------------------------------------------------------------------------------
;; score! : dir -> void   each start as it was (under OUT/_start) and as each session left it
(define (score! out)
  (define before (build-path out "_start"))
  (for ([s (in-list (starts))])
    (make-directory* (build-path before s))
    (copy-file (build-path implementations s "measure.py") (build-path before s "measure.py") #t))
  (void
   (in-parallel 6
                (append (for/list ([s (in-list (starts))]) (list before s (start-measure s)))
                        (for*/list ([s (in-list (starts))] [arm (in-list arms)]
                                    #:when (directory-exists? (build-path out (check-id s arm))))
                          (list out (check-id s arm) (start-measure s))))
                (lambda (job) (apply score-one! job)))))

;; rights : path -> Rights   a score.json's held-out cases
(define (rights file)
  (for/hash ([(c v) (in-hash (hash-ref (read-json-file file) 'cases))] #:unless (hash-ref v 'sample))
    (values (symbol->string c) (and (hash-ref v 'right) #t))))

;; belief-of : dir -> boolean | 'none   what a session's verdict.json says
(define (belief-of dir)
  (define f (build-path dir "verdict.json"))
  (define v (and (file-exists? f) (with-handlers ([exn:fail? (lambda (_) #f)]) (read-json-file f))))
  (if (and (hash? v) (boolean? (hash-ref v 'correct 'none))) (hash-ref v 'correct) 'none))

;; read-checks : dir -> (listof Check)   a scored run
(define (read-checks out)
  (for/list ([s (in-list (starts))])
    (define run (filter (lambda (arm) (file-exists? (build-path out (check-id s arm) "score.json"))) arms))
    (review s (start-measure s) (start-origin s)
           (rights (build-path out "_start" s "score.json"))
           (for/hash ([arm (in-list run)]) (values arm (rights (build-path out (check-id s arm) "score.json"))))
           (for/hash ([arm (in-list run)])
             (define rec (read-json-file (build-path out (check-id s arm) "record.json")))
             (values arm (for/hasheq ([k (in-list '(input_tokens output_tokens seconds turns))])
                           (values k (let ([v (hash-ref rec k 0)]) (if (real? v) v 0))))))
           (for/hash ([arm (in-list run)]) (values arm (belief-of (build-path out (check-id s arm))))))))

;; keep! : (listof Check) path -> void   a scored run as one JSON file
(define (keep! checks file)
  (define (rights->json r) (for/hasheq ([(k v) (in-hash r)]) (values (string->symbol k) v)))
  (write-json-file
   file
   (for/list ([c (in-list checks)])
     (hasheq 'start (review-start c)
             'before (rights->json (review-before c))
             'after (for/hasheq ([(arm r) (in-hash (review-after c))]) (values arm (rights->json r)))
             'cost (for/hasheq ([(arm k) (in-hash (review-cost c))]) (values arm k))
             'belief (for/hasheq ([(arm b) (in-hash (review-belief c))]) (values arm (if (boolean? b) b "none")))))))

;; kept : path [(Start -> group) (Start -> origin)] -> (listof Check)   what `keep!` wrote; a start's
;; group (its measure) and origin are read from its name
(define (kept file [group-of start-measure] [origin-of start-origin])
  (define (json->rights j) (for/hash ([(k v) (in-hash j)]) (values (symbol->string k) v)))
  (for/list ([j (in-list (read-json-file file))])
    (define s (hash-ref j 'start))
    (review s (group-of s) (origin-of s)
            (json->rights (hash-ref j 'before))
            (for/hash ([(arm r) (in-hash (hash-ref j 'after))]) (values arm (json->rights r)))
            (for/hash ([(arm k) (in-hash (hash-ref j 'cost))]) (values arm k))
            (for/hash ([(arm b) (in-hash (hash-ref j 'belief))]) (values arm (if (boolean? b) b 'none))))))

;; checks-of : path -> (listof Check)   a scored run's directory, or the file kept of one
(define (checks-of path) (if (directory-exists? path) (read-checks path) (kept path)))

;; ---- analysis ---------------------------------------------------------------------------------------
(define (mean xs) (if (null? xs) 0 (/ (apply + xs) (length xs))))
(define (ones rights) (for/list ([(c r) (in-hash rights)]) (if r 1 0)))

;; share-before : (listof Check) -> real   pooled over implementations and their held-out cases
(define (share-before checks) (mean (append-map (lambda (c) (ones (review-before c))) checks)))
;; share-after : (listof Check) Arm -> real
(define (share-after checks arm) (mean (append-map (lambda (c) (ones (hash-ref (review-after c) arm))) checks)))

;; fixed : (listof Check) Arm -> (cons natural natural)   of the answers wrong before, how many
;; are right after the arm's session, and how many there were
(define (fixed checks arm)
  (define pairs (for*/list ([c (in-list checks)] [(k r) (in-hash (review-before c))] #:unless r)
                  (hash-ref (hash-ref (review-after c) arm) k)))
  (cons (count values pairs) (length pairs)))
;; broken : (listof Check) Arm -> (cons natural natural)   of the answers right before, how many
;; are wrong after
(define (broken checks arm)
  (define pairs (for*/list ([c (in-list checks)] [(k r) (in-hash (review-before c))] #:when r)
                  (hash-ref (hash-ref (review-after c) arm) k)))
  (cons (count not pairs) (length pairs)))

;; difference : (listof Check) Arm Arm -> real   the first arm's share right after, less the second's
(define (difference checks a b) (- (share-after checks a) (share-after checks b)))

(define (seeded-rng seed)
  (define rng (make-pseudo-random-generator))
  (parameterize ([current-pseudo-random-generator rng]) (random-seed seed))
  rng)
(define (percentiles vs)
  (define sorted (list->vector (sort vs <)))
  (define k (vector-length sorted))
  (cons (vector-ref sorted (exact-floor (* 0.025 (- k 1)))) (vector-ref sorted (exact-ceiling (* 0.975 (- k 1))))))
(define (draw v) (vector-ref v (random (vector-length v))))

;; resampled : (listof Check) -> (listof Check)   implementations drawn with replacement within
;; measure and origin; within each measure its held-out cases drawn with replacement, the same
;; draw for every implementation and arm of the measure (a case is paired)
(define (resampled checks)
  (append*
   (for/list ([m (in-list (remove-duplicates (map review-measure checks)))])
     (define group (filter (lambda (c) (equal? (review-measure c) m)) checks))
     (define cases (list->vector (sort (hash-keys (review-before (car group))) string<?)))
     (define drawn (for/list ([_ (in-range (vector-length cases))]) (draw cases)))
     (define (redrawn rights) (for/hash ([k (in-list drawn)] [j (in-naturals)]) (values (format "~a#~a" k j) (hash-ref rights k))))
     (append*
      (for/list ([origin (in-list (remove-duplicates (map review-origin group)))])
        (define mine (list->vector (filter (lambda (c) (eq? (review-origin c) origin)) group)))
        (for/list ([_ (in-range (vector-length mine))])
          (define c (draw mine))
          (review (review-start c) m origin (redrawn (review-before c))
                 (for/hash ([(arm r) (in-hash (review-after c))]) (values arm (redrawn r)))
                 (review-cost c) (review-belief c))))))))

;; bootstrap-difference : (listof Check) Arm Arm [natural] -> (cons low high)   the 95% interval
(define (bootstrap-difference checks a b [resamples 4000])
  (parameterize ([current-pseudo-random-generator (seeded-rng 20261126)])
    (percentiles (for/list ([_ (in-range resamples)]) (exact->inexact (difference (resampled checks) a b))))))

;; sign-flip-p : (listof Check) Arm Arm [natural] -> real   how often swapping the two arms' labels
;; within an implementation, each at random, gives a difference at least as large (two-sided)
(define (sign-flip-p checks a b [shuffles 20000])
  (define observed (abs (difference checks a b)))
  (parameterize ([current-pseudo-random-generator (seeded-rng 20261127)])
    (/ (for/sum ([_ (in-range shuffles)])
         (define swapped
           (for/list ([c (in-list checks)])
             (if (zero? (random 2))
                 c
                 (review (review-start c) (review-measure c) (review-origin c) (review-before c)
                        (hash-set* (review-after c) a (hash-ref (review-after c) b) b (hash-ref (review-after c) a))
                        (review-cost c) (review-belief c)))))
         (if (>= (abs (difference swapped a b)) observed) 1 0))
       shuffles)))

;; perfect? : Rights -> boolean
(define (perfect? rights) (for/and ([(c r) (in-hash rights)]) r))

;; ---- report ----------------------------------------------------------------------------------------
(define (percent x) (format "~a%" (/ (round (* 1000.0 x)) 10.0)))
(define (points x) (format "~a~a" (if (negative? x) "" "+") (/ (round (* 1000.0 x)) 10.0)))
(define (thousands x) (format "~ak" (/ (round (/ x 100.0)) 10.0)))
(define arm-name (hash 'R "read (R)" 'T "tested (T)" 'O "oracle (O)"))

(define (report all)
  (define checks (filter (lambda (c) (for/and ([arm (in-list arms)]) (hash-has-key? (review-after c) arm))) all))
  (define (of origin) (filter (lambda (c) (eq? (review-origin c) origin)) checks))
  (printf "implementations checked in every arm: ~a (~a written from the narrative, ~a from the CQL); held-out cases: ~a\n\n"
          (length checks) (length (of 'N)) (length (of 'S))
          (for/sum ([m (in-list (remove-duplicates (map review-measure checks)))])
            (hash-count (review-before (findf (lambda (c) (equal? (review-measure c) m)) checks)))))
  (printf "right on the held-out cases          before    after R    after T    after O\n")
  (for ([label (in-list '("  all                               " "  written from the narrative        " "  written from the CQL              "))]
        [group (in-list (list checks (of 'N) (of 'S)))])
    (printf "~a ~a     ~a      ~a      ~a\n" label (percent (share-before group))
            (percent (share-after group 'R)) (percent (share-after group 'T)) (percent (share-after group 'O))))
  (for ([m (in-list (remove-duplicates (map review-measure checks)))])
    (define group (filter (lambda (c) (equal? (review-measure c) m)) checks))
    (printf "  ~a ~a     ~a      ~a      ~a\n" (string-append (short-name m) (make-string (max 1 (- 34 (string-length (short-name m)))) #\space))
            (percent (share-before group)) (percent (share-after group 'R)) (percent (share-after group 'T)) (percent (share-after group 'O))))
  (newline)
  (for ([arm (in-list arms)])
    (define f (fixed checks arm))
    (define b (broken checks arm))
    (printf "~a: of ~a answers wrong before, ~a right after (~a); of ~a right before, ~a wrong after\n"
            (hash-ref arm-name arm) (cdr f) (car f) (if (zero? (cdr f)) "-" (percent (/ (car f) (cdr f)))) (cdr b) (car b)))
  (printf "implementations right on every held-out case: before ~a; after R ~a, T ~a, O ~a (of ~a)\n"
          (count (lambda (c) (perfect? (review-before c))) checks)
          (count (lambda (c) (perfect? (hash-ref (review-after c) 'R))) checks)
          (count (lambda (c) (perfect? (hash-ref (review-after c) 'T))) checks)
          (count (lambda (c) (perfect? (hash-ref (review-after c) 'O))) checks) (length checks))
  (newline)
  (for ([arm (in-list arms)])
    (define said (filter (lambda (c) (eq? (hash-ref (review-belief c) arm) #t)) checks))
    (define doubted (filter (lambda (c) (eq? (hash-ref (review-belief c) arm) #f)) checks))
    (printf "~a: said the implementation is right ~a times, and it was right on every held-out case ~a times; said errors remain ~a times (they did ~a times); no verdict ~a\n"
            (hash-ref arm-name arm) (length said) (count (lambda (c) (perfect? (hash-ref (review-after c) arm))) said)
            (length doubted) (count (lambda (c) (not (perfect? (hash-ref (review-after c) arm)))) doubted)
            (- (length checks) (length said) (length doubted))))
  (newline)
  (define (compare label group a b)
    (define d (difference group a b))
    (define ci (bootstrap-difference group a b))
    (printf "~a ~a − ~a = ~a points (95% interval ~a to ~a; label swap p = ~a)\n" label a b
            (points d) (points (car ci)) (points (cdr ci)) (exact->inexact (/ (round (* 10000 (sign-flip-p group a b))) 10000)))
    (values d ci))
  (define-values (d ci) (compare "written from the narrative:" (of 'N) 'O 'R))
  (call-with-values (lambda () (compare "written from the narrative:" (of 'N) 'O 'T)) void)
  (call-with-values (lambda () (compare "written from the narrative:" (of 'N) 'T 'R)) void)
  (call-with-values (lambda () (compare "written from the CQL:      " (of 'S) 'O 'R)) void)
  (call-with-values (lambda () (compare "all:                       " checks 'O 'R)) void)
  (call-with-values (lambda () (compare "all:                       " checks 'O 'T)) void)
  (call-with-values (lambda () (compare "all:                       " checks 'T 'R)) void)
  (newline)
  (for ([arm (in-list arms)])
    (define (m key) (mean (map (lambda (c) (hash-ref (hash-ref (review-cost c) arm) key)) checks)))
    (printf "a session, ~a: ~a input and ~a output tokens, ~a turns, ~a s\n" (hash-ref arm-name arm)
            (thousands (m 'input_tokens)) (thousands (m 'output_tokens)) (exact->inexact (/ (round (* 10 (m 'turns))) 10)) (exact-round (m 'seconds))))
  (printf "\nverdict (written from the narrative, O against R)   ~a\n"
          (case (verdict-of d (interval (car ci) (cdr ci)) #f)
            [(more-right) "the oracle's checkers leave implementations right more often (the protocol's \"significant value\")"]
            [(worse) "the oracle's checkers leave implementations right less often"]
            [else "no difference shown"])))

;; changes : (listof Check) -> void   each held-out answer some session fixed or broke
(define (changes checks)
  (for* ([c (in-list checks)] [k (in-list (sort (hash-keys (review-before c)) string<?))])
    (define before (hash-ref (review-before c) k))
    (define after (for/list ([arm (in-list arms)] #:when (hash-has-key? (review-after c) arm)) (cons arm (hash-ref (hash-ref (review-after c) arm) k))))
    (unless (andmap (lambda (a) (eq? (cdr a) before)) after)
      (printf "~a ~a: ~a before; ~a\n" (review-start c) k (if before "right" "wrong")
              (string-join (for/list ([a (in-list after)]) (format "~a ~a" (car a) (if (cdr a) "right" "wrong"))) ", ")))))

;; oracle-right? : measure case -> boolean   does the specification executed give the authors' answers?
(define (oracle-right? m c) (equal? (oracle m (map cdr (case-resources m c))) (case-expected m c)))

;; broken-answers : (listof Check) -> void   for each arm, the held-out answers right before and wrong
;; after its session, told apart by what can be known of the cause: the session wrote no verdict
;; (it was cut off at the turn limit, its implementation left as it stood then); else the oracle
;; itself gives another answer than the authors for that patient, or for a sample patient of the
;; measure (an oracle's checker is shown the one answer, a tested arm's checker the other); else
;; neither.
(define (broken-answers checks)
  (define measures-oracle-wrong-on-sample
    (for/list ([m (in-list (remove-duplicates (map review-measure checks)))]
               #:when (for/or ([c (in-list (case-ids m))]) (and (sample-case? m c) (not (oracle-right? m c)))))
      m))
  (for ([arm (in-list arms)])
    (define rows
      (for*/list ([c (in-list checks)] #:when (hash-has-key? (review-after c) arm)
                  [(k r) (in-hash (review-before c))] #:when (and r (not (hash-ref (hash-ref (review-after c) arm) k))))
        (list (review-start c) k
              (cond [(eq? (hash-ref (review-belief c) arm) 'none) 'cut-off]
                    [(not (oracle-right? (review-measure c) k)) 'oracle-differs-on-it]
                    [(member (review-measure c) measures-oracle-wrong-on-sample) 'oracle-differs-on-a-sample-patient-of-the-measure]
                    [else 'other]))))
    (printf "~a: ~a answers right before and wrong after\n" (hash-ref arm-name arm) (length rows))
    (for ([cause (in-list '(cut-off oracle-differs-on-it oracle-differs-on-a-sample-patient-of-the-measure other))])
      (define mine (filter (lambda (r) (eq? (caddr r) cause)) rows))
      (unless (null? mine)
        (printf "  ~a: ~a, in ~a implementations (~a)\n"
                (case cause
                  [(cut-off) "the session was cut off at the turn limit (no verdict written)"]
                  [(oracle-differs-on-it) "the specification executed does not give the authors' answer for the patient"]
                  [(oracle-differs-on-a-sample-patient-of-the-measure) "another patient of a measure where, for a sample patient, the specification executed does not give the authors' answer"]
                  [else "neither"])
                (length mine) (length (remove-duplicates (map car mine)))
                (string-join (remove-duplicates (map car mine)) ", "))))))

;; ---- command line ---------------------------------------------------------------------------------------
(module+ main
  (define args (vector->list (current-command-line-arguments)))
  (define (option name default)
    (define at (member name args))
    (if (and at (pair? (cdr at))) (cadr at) default))
  (when (< (length args) 2) (raise-user-error 'verify "verify.rkt run|score|report|changes OUT [options]"))
  (define out (path->complete-path (cadr args)))
  (case (car args)
    [("run")
     (define wanted-arms (map string->symbol (string-split (option "--arms" "R,T,O") ",")))
     (define only (let ([o (option "--only" #f)]) (and o (string-split o ","))))
     (current-resume? (and (member "--resume" args) #t))
     (make-directory* out)
     (void (in-parallel (string->number (option "--parallel" "6"))
                        (for*/list ([s (in-list (starts))] #:when (or (not only) (member s only)) [arm (in-list wanted-arms)]) (list s arm))
                        (lambda (job) (run-one! out (car job) (cadr job) (option "--model" "sonnet")))))]
    [("score") (score! out)
               (for ([c (in-list (read-checks out))])
                 (printf "~a before ~a~a\n" (review-start c) (percent (share-before (list c)))
                         (string-join (for/list ([arm (in-list arms)] #:when (hash-has-key? (review-after c) arm))
                                        (format ", ~a ~a" arm (percent (share-after (list c) arm))))
                                      "")))]
    [("report") (report (checks-of out))]
    [("changes") (changes (checks-of out))]
    [("broken") (broken-answers (checks-of out))]
    [("keep") (keep! (read-checks out) (caddr args))]
    [else (raise-user-error 'verify "verify.rkt run|score|report|changes|broken|keep OUT [options]")]))

(module+ test
  (require rackunit)
  ;; the forty, each a measure and an origin
  (check-equal? (length (starts)) 40)
  (check-equal? (start-measure "breast-N-3") "BreastCancerScreeningFHIR")
  (check-equal? (start-origin "breast-N-3") 'N)
  (check-equal? (start-origin "diabetes-S-1") 'S)
  (check-equal? (count (lambda (s) (eq? (start-origin s) 'N)) (starts)) 20)
  ;; the arms' prompts differ in the one line that names what the arm adds
  (define (without-arm p) (regexp-replaces p '((#rx"- expected.json[^\n]*\n" "") (#rx"- oracle.rkt[^\n]*\n" ""))))
  (for* ([m (in-list measures)] [origin (in-list '(N S))])
    (check-equal? (check-prompt m origin 'R) (without-arm (check-prompt m origin 'T)))
    (check-equal? (check-prompt m origin 'R) (without-arm (check-prompt m origin 'O)))
    (check-false (equal? (check-prompt m origin 'R) (check-prompt m origin 'T))))
  ;; a checker of an implementation written from the narrative is not told of the CQL
  (check-false (regexp-match? #rx"CQL|spec/" (check-prompt (car measures) 'N 'O)))
  ;; a directory: the implementation, the implementer's material, what the arm adds
  (let ([dir (make-temporary-file "verify-~a" 'directory)])
    (prepare-check! "cervical-N-1" 'R (build-path dir "r"))
    (prepare-check! "cervical-N-1" 'T (build-path dir "t"))
    (prepare-check! "cervical-N-1" 'O (build-path dir "o"))
    (for ([d (in-list '("r" "t" "o"))])
      (check-true (file-exists? (build-path dir d "measure.py")))
      (check-true (file-exists? (build-path dir d "MEASURE.md")))
      (check-false (directory-exists? (build-path dir d "spec"))))
    (check-false (file-exists? (build-path dir "r" "expected.json")))
    (check-false (file-exists? (build-path dir "r" "oracle.rkt")))
    (check-equal? (hash-count (read-json-file (build-path dir "t" "expected.json"))) 6)
    (check-regexp-match #rx"CervicalCancerScreeningFHIR" (file->string (build-path dir "o" "oracle.rkt")))
    (check-false (file-exists? (build-path dir "o" "expected.json")))
    (delete-directory/files dir))
  ;; made data: two implementations of one measure, four held-out cases
  (define (made start origin before r t o)
    (define (rights bits) (for/hash ([b (in-list bits)] [k (in-naturals)]) (values (format "c~a" k) (= b 1))))
    (review start "m" origin (rights before) (hash 'R (rights r) 'T (rights t) 'O (rights o))
           (hash 'R (hasheq) 'T (hasheq) 'O (hasheq)) (hash 'R #t 'T #t 'O #t)))
  (define two (list (made "m-N-1" 'N '(1 0 0 1) '(1 0 0 1) '(1 1 0 1) '(1 1 1 1))
                    (made "m-N-2" 'N '(1 1 1 0) '(0 1 1 0) '(1 1 1 0) '(1 1 1 1))))
  (check-equal? (share-before two) 5/8)
  (check-equal? (share-after two 'R) 1/2)
  (check-equal? (share-after two 'O) 1)
  (check-equal? (fixed two 'R) '(0 . 3))
  (check-equal? (fixed two 'T) '(1 . 3))
  (check-equal? (fixed two 'O) '(3 . 3))
  (check-equal? (broken two 'R) '(1 . 5))
  (check-equal? (broken two 'O) '(0 . 5))
  (check-equal? (difference two 'O 'R) 1/2)
  (let ([ci (bootstrap-difference two 'O 'R 400)])
    (check-true (<= (car ci) 1/2 (cdr ci)))
    (check-true (>= (car ci) 0)))
  (check-true (<= 0 (sign-flip-p two 'O 'R 400) 1))
  (check-equal? (sign-flip-p two 'R 'R 100) 1)
  (check-true (perfect? (hash "a" #t "b" #t)))
  (check-false (perfect? (hash "a" #t "b" #f))))

;; probe : a checker's directory made by hand, for trying what an arm is given
(module+ probe
  (provide prepare)
  (define (prepare start arm dir) (prepare-check! start (string->symbol arm) dir)))
