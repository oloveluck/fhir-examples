#lang racket/base

;;; materials.rkt — what an implementer of experiment S is given, and what it is held to.
;;;
;;; The material is cql's vendored copy of cqframework/ecqm-content-qicore-2024 (CC0): four
;;; measures, each with its Measure resource (the English narrative), its CQL library and the
;;; libraries it includes (the specification), the value sets it declares, and its authors' test
;;; cases (a patient's resources and the expected MeasureReport).
;;;
;;; An Arm is 'N (narrative first) or 'S (spec first).
;;; A Case is a directory of one patient's resources; its Expected is a hash population -> boolean.
;;; A Term is (term kind name value system library): a value set (value = its url) or a code the
;;; CQL declares by name.

(require racket/file racket/list racket/string racket/path racket/runtime-path json)

(provide measures short-name measure-title populations
         library-closure declared-terms valueset-members valuesets-json
         case-ids sample-case? case-resources case-expected
         narrative spec-readme terminology-text contract-text task-prompt
         prepare-task! write-cases!
         (struct-out term))

(define-runtime-path try-script "try.py")

(define populations '("initial-population" "denominator" "denominator-exclusion" "numerator"))

;; the four measures, with the names their runs are filed under
(define measures
  '("BreastCancerScreeningFHIR" "CervicalCancerScreeningFHIR" "ControllingHighBloodPressureFHIR"
    "DiabetesGlycemicStatusAssessmentGreaterThan9PercentFHIR"))
(define (short-name m)
  (cdr (assoc m '(("BreastCancerScreeningFHIR" . "breast") ("CervicalCancerScreeningFHIR" . "cervical")
                  ("ControllingHighBloodPressureFHIR" . "pressure")
                  ("DiabetesGlycemicStatusAssessmentGreaterThan9PercentFHIR" . "diabetes")))))

(define (vendor . parts) (apply build-path (collection-path "cql") "tests" "vendor" "qicore-2024" parts))
(define (read-json-file f) (call-with-input-file f read-json))

;; ---- the measure and its narrative -----------------------------------------------------------------
(define (measure-resource m) (read-json-file (vendor "measure" (string-append m ".json"))))
(define (measure-title m) (hash-ref (measure-resource m) 'title m))

;; population-entries : measure -> (listof (list code description define))
(define (population-entries m)
  (for*/list ([g (in-list (hash-ref (measure-resource m) 'group '()))]
              [p (in-list (hash-ref g 'population '()))])
    (list (hash-ref (car (hash-ref (hash-ref p 'code) 'coding)) 'code)
          (string-trim (hash-ref p 'description ""))
          (hash-ref (hash-ref p 'criteria (hasheq)) 'expression ""))))

(define population-words
  '(("initial-population" . "Initial population") ("denominator" . "Denominator")
    ("denominator-exclusion" . "Denominator exclusions") ("numerator" . "Numerator")))

;; narrative : measure -> string   the measure's published English, as its Measure resource holds it
(define (narrative m)
  (define r (measure-resource m))
  (define (section title key)
    (define text (hash-ref r key #f))
    (if (and (string? text) (not (member (string-trim text) '("" "UNKNOWN"))))
        (format "\n## ~a\n\n~a\n" title (string-trim text))
        ""))
  (string-append
   (format "# ~a\n\n~a\n" (measure-title m) (string-trim (hash-ref r 'description "")))
   "\n## Population criteria\n\n"
   (string-join (for/list ([p (in-list (population-entries m))] #:when (assoc (car p) population-words))
                  (format "**~a.** ~a" (cdr (assoc (car p) population-words)) (cadr p)))
                "\n\n")
   "\n"
   (section "Guidance" 'usage)
   "\n## Scoring\n\nA proportion measure: each population is a yes or a no for a patient.\n"
   (section "Rationale" 'rationale)
   (section "Clinical recommendation statement" 'clinicalRecommendationStatement)))

;; spec-readme : measure -> string   for the spec arm: where the specification is, and which of
;; its definitions is which population (the Measure resource's criteria)
(define (spec-readme m)
  (string-append
   (format "# ~a\n\n" (measure-title m))
   (format "The measure is specified in Clinical Quality Language (CQL): `spec/~a.cql`, and the libraries it includes, all in `spec/`.\n\n" m)
   "Its populations are these definitions of that library:\n\n"
   (string-join (for/list ([p (in-list (population-entries m))] #:when (member (car p) populations))
                  (format "- ~a: `~a`" (car p) (caddr p)))
                "\n")
   "\n\nA proportion measure: each population is a yes or a no for a patient.\n"))

;; ---- the specification: the CQL library and what it includes -----------------------------------------
(define (cql-file name) (vendor "elm-corpus" "ecqm-content-qicore-2024" (string-append name ".cql")))

;; library-closure : measure -> (listof (cons name path))   the measure's library first
(define (library-closure m)
  (let loop ([todo (list m)] [seen '()])
    (cond [(null? todo) (reverse seen)]
          [(or (assoc (car todo) seen) (not (file-exists? (cql-file (car todo))))) (loop (cdr todo) seen)]
          [else
           (define path (cql-file (car todo)))
           (define includes (map cadr (regexp-match* #px"(?m:^include\\s+([A-Za-z0-9_.]+))" (file->string path) #:match-select values)))
           (loop (append (cdr todo) includes) (cons (cons (car todo) path) seen))])))

(struct term (kind name value system library) #:transparent)

;; declared-terms : measure -> (listof Term)   the value sets and codes the measure's libraries
;; declare by name (FHIRHelpers declares none)
(define (declared-terms m)
  (append*
   (for/list ([lib (in-list (library-closure m))])
     (define text (file->string (cdr lib)))
     (define systems
       (for/hash ([d (in-list (regexp-match* #px"(?m:^codesystem\\s+\"([^\"]+)\":\\s*'([^']+)')" text #:match-select cdr))])
         (values (car d) (cadr d))))
     (append
      (for/list ([d (in-list (regexp-match* #px"(?m:^valueset\\s+\"([^\"]+)\":\\s*'([^']+)')" text #:match-select cdr))])
        (term 'valueset (car d) (cadr d) #f (car lib)))
      (for/list ([d (in-list (regexp-match* #px"(?m:^code\\s+\"([^\"]+)\":\\s*'([^']+)'\\s+from\\s+\"([^\"]+)\")" text #:match-select cdr))])
        (term 'code (car d) (cadr d) (hash-ref systems (caddr d) (caddr d)) (car lib)))))))

;; valueset-index : -> (hash url (listof (list system code)))   the vendored expansions, by url
(define valueset-index
  (let ([index #f])
    (lambda ()
      (unless index
        (set! index
              (for/hash ([f (in-list (directory-list (vendor "valueset") #:build? #t))]
                         #:when (regexp-match? #rx"[.]json$" (path->string f)))
                (define v (read-json-file f))
                (values (hash-ref v 'url "")
                        (for/list ([c (in-list (hash-ref (hash-ref v 'expansion (hasheq)) 'contains '()))])
                          (list (hash-ref c 'system "") (hash-ref c 'code "")))))))
      index)))
(define (valueset-members url) (hash-ref (valueset-index) url #f))

;; valuesets-json : measure -> jsexpr   name -> [[system, code], …], one entry a declared value set
(define (valuesets-json m)
  (for/hash ([t (in-list (remove-duplicates (filter (lambda (t) (eq? (term-kind t) 'valueset)) (declared-terms m))
                                            #:key term-name))])
    (values (string->symbol (term-name t)) (or (valueset-members (term-value t)) '()))))

;; terminology-text : measure -> string   the value sets and codes by name: what the published
;; measure lists beside its narrative, and what the CQL declares
(define (terminology-text m)
  (define terms (remove-duplicates (declared-terms m) #:key (lambda (t) (cons (term-kind t) (term-name t)))))
  (define-values (sets codes) (partition (lambda (t) (eq? (term-kind t) 'valueset)) terms))
  (string-append
   "# Terminology of the measure\n\n"
   "## Value sets\n\nEach is a set of codes; `valuesets.json` has the members of each under this name, as [system, code] pairs.\n\n"
   (string-join (for/list ([t (in-list (sort sets string<? #:key term-name))])
                  (format "- \"~a\" (~a codes)" (term-name t) (length (or (valueset-members (term-value t)) '()))))
                "\n")
   "\n\n## Single codes\n\n"
   (string-join (for/list ([t (in-list (sort codes string<? #:key term-name))])
                  (format "- \"~a\": `~a` in ~a" (term-name t) (term-value t) (term-system t)))
                "\n")
   "\n"))

;; ---- the test cases ---------------------------------------------------------------------------------
;; case-ids : measure -> (listof string)   in name order
(define (case-ids m)
  (sort (for/list ([d (in-list (directory-list (vendor "tests" m)))] #:when (directory-exists? (vendor "tests" m d)))
          (path->string d))
        string<?))

;; sample-case? : measure id -> boolean   a fifth of a measure's cases, every fifth in name order
;; (the ids are random UUIDs): the ones an implementer is shown, and is not scored on
(define (sample-case? m id) (zero? (modulo (index-of (case-ids m) id) 5)))

(define (case-files m id)
  (for/list ([f (in-list (directory-list (vendor "tests" m id) #:build? #t))]
             #:when (regexp-match? #rx"[.]json$" (path->string f)))
    f))
(define (measure-report? f) (regexp-match? #rx"^MeasureReport-" (path->string (file-name-from-path f))))

;; scrubbed : jsexpr -> jsexpr   a Patient without its name (one measure's test patients are named
;; after their expected result)
(define (scrubbed r)
  (if (equal? (hash-ref r 'resourceType #f) "Patient")
      (hash-set r 'name (list (hasheq 'family "Patient" 'given '("Test"))))
      r))

;; case-resources : measure id -> (listof (cons file-name jsexpr))   the patient's records
(define (case-resources m id)
  (for/list ([f (in-list (case-files m id))] #:unless (measure-report? f))
    (cons (path->string (file-name-from-path f)) (scrubbed (read-json-file f)))))

;; case-expected : measure id -> (hash string boolean)   the authors' expected populations
(define (case-expected m id)
  (define report (read-json-file (findf measure-report? (case-files m id))))
  (for*/hash ([g (in-list (hash-ref report 'group '()))] [p (in-list (hash-ref g 'population '()))]
              [code (in-value (hash-ref (car (hash-ref (hash-ref p 'code) 'coding)) 'code))]
              #:when (member code populations))
    (values code (positive? (hash-ref p 'count 0)))))

;; write-cases! : measure dir (id -> boolean) -> void   the chosen cases' records, a directory a patient
(define (write-cases! m dir keep?)
  (for ([id (in-list (case-ids m))] #:when (keep? id))
    (make-directory* (build-path dir id))
    (for ([r (in-list (case-resources m id))])
      (call-with-output-file (build-path dir id (car r)) #:exists 'truncate
        (lambda (o) (write-json (cdr r) o))))))

;; ---- the task ----------------------------------------------------------------------------------------
(define contract-text #<<EOF
# The function to write

Write `measure.py`, defining

    def evaluate(resources, valuesets, period_start, period_end):
        ...
        return {"initial-population": True or False,
                "denominator": True or False,
                "denominator-exclusion": True or False,
                "numerator": True or False}

- `resources`: a list of dicts, every FHIR R4 resource recorded for ONE patient (the Patient
  resource among them), as parsed JSON. All of them are that patient's, whatever a resource's
  subject reference says.
- `valuesets`: a dict from a value set's name (see terminology.md) to a set of `(system, code)`
  tuples.
- `period_start`, `period_end`: the measurement period as dates, `"2025-01-01"` and
  `"2025-12-31"`: those whole days, both included.

The four answers follow the rules of any proportion measure: a patient is in the denominator
only if in the initial population; in the denominator exclusions only if in the denominator;
in the numerator only if in the denominator and not excluded.

Python 3 standard library only. `python3 try.py` runs it over `sample/`.
EOF
  )

;; task-prompt : measure Arm -> string   the same but for the sentences that name the description
(define (task-prompt m arm)
  (define described
    (case arm
      [(N) "It is described in MEASURE.md: the measure's published description and the criteria of each population, in English."]
      [(S) (format "It is specified in Clinical Quality Language (CQL): spec/~a.cql and the libraries it includes, all in spec/. MEASURE.md says which of its definitions is which population. There is no CQL engine here: read the specification and implement what it says." m)]))
  (string-append
   "You are implementing a clinical quality measure as one Python function.\n\n"
   (format "The measure: ~a. ~a\n\n" (measure-title m) described)
   "In this directory:\n"
   (case arm
     [(N) "- MEASURE.md: the measure, in English\n"]
     [(S) "- MEASURE.md and spec/: the measure, in CQL\n"])
   "- CONTRACT.md: the function to write, exactly. Read it first.\n"
   "- terminology.md and valuesets.json: the value sets and codes of the measure, by name\n"
   "- sample/: the records of a few test patients (FHIR R4 JSON, a directory a patient). There are no expected results.\n"
   "- try.py: `python3 try.py` runs your measure.py over sample/ and prints what it answers for each patient\n\n"
   "Write measure.py. It will be run on other patients than the sample's, and judged by whether each of the four answers is what the measure's authors expect for each patient. "
   (case arm
     [(N) "Implement the measure as described, completely: every criterion and every exclusion."]
     [(S) "Implement the measure as specified, completely: every criterion and every exclusion."])
   "\n\nUse only this directory and Python 3's standard library: no network, no other files, no packages. "
   "When measure.py is written and runs over the sample, end with one short line."))

;; prepare-task! : measure Arm dir -> void   an implementer's directory
(define (prepare-task! m arm dir)
  (make-directory* dir)
  (define (put name text) (display-to-file text (build-path dir name) #:exists 'truncate))
  (put "MEASURE.md" (case arm [(N) (narrative m)] [(S) (spec-readme m)]))
  (when (eq? arm 'S)
    (make-directory* (build-path dir "spec"))
    (for ([lib (in-list (library-closure m))])
      (copy-file (cdr lib) (build-path dir "spec" (string-append (car lib) ".cql")) #t)))
  (put "CONTRACT.md" contract-text)
  (put "terminology.md" (terminology-text m))
  (call-with-output-file (build-path dir "valuesets.json") #:exists 'truncate
    (lambda (o) (write-json (valuesets-json m) o)))
  (copy-file try-script (build-path dir "try.py") #t)
  (write-cases! m (build-path dir "sample") (lambda (id) (sample-case? m id))))

(module+ test
  (require rackunit)
  (check-equal? (length measures) 4)
  ;; the cases: 190, a fifth of each measure's shown
  (check-equal? (map (lambda (m) (length (case-ids m))) measures) '(58 29 60 43))
  (check-equal? (map (lambda (m) (count (lambda (id) (sample-case? m id)) (case-ids m))) measures) '(12 6 12 9))
  (for ([m (in-list measures)])
    ;; every case has its four expected answers, in proportion form
    (for ([id (in-list (case-ids m))])
      (define e (case-expected m id))
      (check-equal? (sort (hash-keys e) string<?) (sort populations string<?))
      (check-false (and (hash-ref e "numerator") (hash-ref e "denominator-exclusion")))
      ;; no expected result and no name among what an implementer is shown
      (for ([r (in-list (case-resources m id))])
        (check-false (equal? (hash-ref (cdr r) 'resourceType) "MeasureReport"))
        (check-false (regexp-match? #rx"DENEX|NUMER|IPP|Pass|Fail" (jsexpr->string (cdr r))) (car r))))
    ;; the specification: the measure's library first, FHIRHelpers among what it includes
    (define libs (library-closure m))
    (check-equal? (caar libs) m)
    (check-not-false (assoc "FHIRHelpers" libs))
    ;; every declared value set has its members
    (for ([t (in-list (declared-terms m))] #:when (eq? (term-kind t) 'valueset))
      (check-true (pair? (valueset-members (term-value t))) (term-name t)))
    ;; the narrative states each population's criteria and names no CQL; the spec arm's page names
    ;; the definitions and states no criteria
    (check-regexp-match #rx"[*][*]Numerator[.][*][*] [A-Z]" (narrative m))
    (check-false (regexp-match? #rx"[.]cql|define " (narrative m)))
    (check-regexp-match #rx"- numerator: `Numerator`" (spec-readme m))
    ;; the two arms' prompts differ in the sentences that name the description, and nowhere else
    (define (without-description text)
      (regexp-replaces text '((#rx"It is (described|specified) in [^\n]*\n" "")
                              (#rx"- MEASURE.md[^\n]*\n" "")
                              (#rx"as (described|specified), completely" "completely"))))
    (check-equal? (without-description (task-prompt m 'N)) (without-description (task-prompt m 'S))))
  (check-regexp-match #rx"Women 52-74 years of age" (narrative "BreastCancerScreeningFHIR"))
  ;; an implementer's directory
  (define dir (make-temporary-file "spec-first-~a" 'directory))
  (prepare-task! "CervicalCancerScreeningFHIR" 'N (build-path dir "n"))
  (prepare-task! "CervicalCancerScreeningFHIR" 'S (build-path dir "s"))
  (check-false (directory-exists? (build-path dir "n" "spec")))
  (check-equal? (length (directory-list (build-path dir "s" "spec"))) 7)
  (check-equal? (length (directory-list (build-path dir "n" "sample"))) 6)
  (check-equal? (file->string (build-path dir "n" "valuesets.json")) (file->string (build-path dir "s" "valuesets.json")))
  (check-equal? (file->string (build-path dir "n" "terminology.md")) (file->string (build-path dir "s" "terminology.md")))
  (delete-directory/files dir))
