#lang racket/base

;;; pipeline.rkt — clinic notes (free text) -> FHIR data that conforms to a spec written in FSH.
;;;
;;; The contract is a small FHIR R4 IG in FSH (ig/: four profiles, two required value sets), compiled
;;; by the fsh package. For each note:
;;;   prompt   the note and the FSH source itself — the model reads the contract it is held to
;;;   extract  the answer's ```json block: a Bundle (collection) of resources
;;;   check    every resource claims one of the IG's profiles and passes $validate against it, with
;;;            the IG's value sets in context (a code outside them is an error); every subject is the
;;;            bundle's own Patient
;;;   repeat   while anything fails: the next prompt carries the previous answer and each issue with
;;;            its resource and path
;;;   score    against the note's answer key, as facts: the patient's name / gender / birth date, the
;;;            blood pressure readings, the problems and the medications (one per resource: the coding
;;;            the key names, if the resource has it among its codings)
;;; Every round is recorded (prompt, answer, issues, score); `replay` re-checks a recorded run with
;;; no model.

(require racket/list racket/string racket/file racket/match racket/runtime-path json
         fhir/operation fhir/data-source
         (only-in fhir/sd/sd-index current-sd-packages)
         (only-in fhir/conformance/operations $validate)
         (only-in fsh/project compile-project project-artifacts project-sd-packages project-diagnostics)
         (only-in "../model.rkt" ask extract-block))

(provide run-note replay-note check-bundle bundle-facts score-facts note-names ig-artifacts current-spec)

(define-runtime-path here ".")
(define ig-dir (build-path here "ig"))
(define notes-dir (build-path here "notes"))
(define fsh-source (file->string (build-path ig-dir "input" "fsh" "notes.fsh")))
(define canonical "http://example.org/fhir/notes")

;; ---- the contract, compiled -----------------------------------------------------------------------
(define ig (compile-project ig-dir))
(unless (null? (project-diagnostics ig))
  (error 'notes-to-fhir "the IG does not compile: ~a" (project-diagnostics ig)))
(define ig-artifacts (project-artifacts ig))
(define profiles
  (for/list ([a (in-list ig-artifacts)] #:when (equal? (hash-ref a 'resourceType) "StructureDefinition"))
    (hash-ref a 'url)))

(define (note-names)
  (sort (for/list ([f (in-list (directory-list notes-dir))] #:when (regexp-match? #rx"[.]txt$" (path->string f)))
          (regexp-replace #rx"[.]txt$" (path->string f) ""))
        string<?))

;; ---- prompting ------------------------------------------------------------------------------------
;; spec : 'full — the FSH source is in the prompt (the model reads the contract)
;;      | 'brief — only the profiles' names and urls (the model learns the contract from the checks)
(define current-spec (make-parameter 'full))
(define (contract-text)
  (case (current-spec)
    [(full)
     (string-append "The profiles and the codes they allow, in FHIR Shorthand (FSH). The IG's canonical is " canonical
                    ", so a profile's url is " canonical "/StructureDefinition/<Id>:\n\n```fsh\n" fsh-source "```\n\n")]
    [else
     (string-append "The profiles (their urls):\n"
                    (string-join (for/list ([a (in-list ig-artifacts)] #:when (equal? (hash-ref a 'resourceType) "StructureDefinition"))
                                   (format "- ~a (~a): ~a" (hash-ref a 'title "") (hash-ref a 'type "") (hash-ref a 'url)))
                                 "\n")
                    "\n\n")]))
(define (prompt note)
  (string-append
   "Turn this clinic note into FHIR R4 resources that conform to the clinic's profiles.\n\n"
   (contract-text)
   "Rules:\n"
   "- Answer with ONE ```json block: a FHIR Bundle of type \"collection\", one entry per resource (each entry has `resource`).\n"
   "- Exactly one NotePatient. Every other resource's subject is a reference to it: \"Patient/<its id>\".\n"
   "- Every resource declares its profile in meta.profile.\n"
   "- Use only the codes the profiles allow. Leave out what the profiles do not cover (other labs and vitals, "
   "family history, conditions the note says the patient does not have).\n"
   "- Dates as YYYY-MM-DD.\n\n"
   "The note:\n\n" note "\n"))

(define (feedback note answer-json issues)
  (string-append
   (prompt note)
   "\n## Your previous answer\n\n```json\n" answer-json "\n```\n\n"
   "## It does not conform yet\n\n"
   (string-join (for/list ([i (in-list issues)]) (string-append "- " i)) "\n")
   "\n\nFix these and answer with the complete corrected Bundle in ONE ```json block.\n"))

;; ---- checking ---------------------------------------------------------------------------------------
;; check-bundle : jsexpr|#f -> (listof issue-string)   empty = conforms
(define (check-bundle b)
  (cond
    [(not (and (hash? b) (equal? (hash-ref b 'resourceType #f) "Bundle")))
     (list "the answer is not a FHIR Bundle")]
    [else
     (define resources (for/list ([e (in-list (hash-ref b 'entry '()))]) (hash-ref e 'resource (hasheq))))
     (define patients (filter (lambda (r) (equal? (hash-ref r 'resourceType #f) "Patient")) resources))
     (define patient-refs (for/list ([p (in-list patients)]) (format "Patient/~a" (hash-ref p 'id ""))))
     (append
      (if (= 1 (length patients)) '() (list (format "the Bundle needs exactly one Patient, it has ~a" (length patients))))
      (append*
       (for/list ([r (in-list resources)])
         (define label (format "~a/~a" (hash-ref r 'resourceType "?") (hash-ref r 'id "?")))
         (define claimed (let ([m (hash-ref r 'meta #f)]) (if (hash? m) (hash-ref m 'profile '()) '())))
         (define subject (let ([s (hash-ref r 'subject #f)]) (and (hash? s) (hash-ref s 'reference #f))))
         (append
          (if (ormap (lambda (u) (member u profiles)) claimed) '()
              (list (format "~a: meta.profile must name one of ~a" label (string-join profiles ", "))))
          (if (and subject (not (member subject patient-refs)))
              (list (format "~a: subject ~a is not the Bundle's Patient" label subject)) '())
          (validation-issues r label)))))]))

(define (validation-issues r label)
  (parameterize ([current-data-source (resources->data-source ig-artifacts)]
                 [current-sd-packages (project-sd-packages ig)])
    (define oo (apply-operation/outcome "$validate" r))
    (for/list ([i (in-list (hash-ref oo 'issue '()))] #:when (member (hash-ref i 'severity #f) '("error" "fatal")))
      (format "~a: ~a: ~a" label (let ([e (hash-ref i 'expression '())]) (if (pair? e) (car e) "")) (hash-ref i 'diagnostics "")))))

;; ---- facts and scoring -------------------------------------------------------------------------------
(define (of-type b t)
  (for/list ([e (in-list (if (hash? b) (hash-ref b 'entry '()) '()))]
             #:when (equal? (hash-ref (hash-ref e 'resource (hasheq)) 'resourceType #f) t))
    (hash-ref e 'resource)))
(define (codes-of cc) (for/list ([c (in-list (hash-ref cc 'coding '()))]) (hash-ref c 'code #f)))
(define (component-value o code)
  (for/first ([c (in-list (hash-ref o 'component '()))] #:when (member code (codes-of (hash-ref c 'code (hasheq)))))
    (hash-ref (hash-ref c 'valueQuantity (hasheq)) 'value #f)))

;; bundle-facts : Bundle -> the facts the answer key states
(define (bundle-facts b)
  (define p (let ([ps (of-type b "Patient")]) (if (pair? ps) (car ps) (hasheq))))
  (define name (let ([ns (hash-ref p 'name '())]) (if (pair? ns) (car ns) (hasheq))))
  (hasheq 'patient (hasheq 'family (hash-ref name 'family #f)
                           'given (let ([g (hash-ref name 'given '())]) (and (pair? g) (car g)))
                           'gender (hash-ref p 'gender #f)
                           'birthDate (hash-ref p 'birthDate #f))
          'bloodPressures (for/list ([o (in-list (of-type b "Observation"))])
                            (hasheq 'date (let ([d (hash-ref o 'effectiveDateTime #f)]) (and d (substring d 0 (min 10 (string-length d)))))
                                    'systolic (component-value o "8480-6")
                                    'diastolic (component-value o "8462-4")))
          ;; one entry per resource: its codes (a resource may carry several codings for one thing)
          'problems (map (lambda (c) (codes-of (hash-ref c 'code (hasheq)))) (of-type b "Condition"))
          'medications (map (lambda (m) (codes-of (hash-ref m 'medicationCodeableConcept (hasheq)))) (of-type b "MedicationStatement"))))

;; score-facts : facts expected -> (hash field -> (list right expected extra))
(define (score-facts f x)
  (define (set-score got want)
    (list (length (filter (lambda (w) (member w got)) want)) (length want)
          (length (filter (lambda (g) (not (member g want))) (remove-duplicates got)))))
  (define (bp-key r) (list (hash-ref r 'date #f) (hash-ref r 'systolic #f) (hash-ref r 'diastolic #f)))
  (hasheq 'patient (let ([fp (hash-ref f 'patient)] [xp (hash-ref x 'patient)])
                     (list (for/sum ([k (in-list '(family given gender birthDate))]) (if (equal? (hash-ref fp k #f) (hash-ref xp k #f)) 1 0)) 4 0))
          'bloodPressures (set-score (map bp-key (hash-ref f 'bloodPressures)) (map bp-key (hash-ref x 'bloodPressures)))
          'problems (set-score (resource-codes (hash-ref f 'problems) (hash-ref x 'problems)) (hash-ref x 'problems))
          'medications (set-score (resource-codes (hash-ref f 'medications) (hash-ref x 'medications)) (hash-ref x 'medications))))
;; resource-codes : (listof (listof code)) expected -> (listof code)   per resource, the code the
;; answer key names if one of its codings has it, else its first code
(define (resource-codes per-resource expected)
  (for/list ([codes (in-list per-resource)] #:when (pair? codes))
    (or (for/first ([c (in-list codes)] #:when (member c expected)) c) (car codes))))

(define (read-expected name)
  (string->jsexpr (file->string (build-path notes-dir (string-append name ".expected.json")))))

;; ---- running ----------------------------------------------------------------------------------------
(define (parse-answer text)
  (with-handlers ([exn:fail? (lambda (_) #f)]) (string->jsexpr (extract-block text "json"))))

;; run-note : name #:model #:rounds #:timeout #:record dir -> result
(define (run-note name #:model cmd #:rounds [rounds 3] #:timeout [timeout 600] #:record record-dir)
  (define note (file->string (build-path notes-dir (string-append name ".txt"))))
  (define dir (build-path record-dir name))
  (make-directory* dir)
  (let loop ([round 1] [text (prompt note)] [acc '()])
    (define (file ext) (build-path dir (format "round-~a.~a" round ext)))
    (call-with-output-file (file "prompt.md") #:exists 'truncate (lambda (o) (write-string text o)))
    (define-values (code seconds timed-out?) (ask cmd (file "prompt.md") (file "answer.txt") (file "err.txt") timeout))
    (define answer (file->string (file "answer.txt")))
    (define r (round-result name round answer seconds))
    (call-with-output-file (file "result.json") #:exists 'truncate (lambda (o) (write-json (hash-remove r 'bundle) o)))
    (define acc* (append acc (list r)))
    (if (or (null? (hash-ref r 'issues)) (= round rounds) timed-out? (not (eqv? code 0)))
        (hasheq 'note name 'rounds acc*)
        (loop (add1 round)
              (feedback note (let ([b (hash-ref r 'bundle)]) (if b (jsexpr->string b) answer)) (hash-ref r 'issues))
              acc*))))

;; round-result : name round answer-text seconds -> result
(define (round-result name round answer seconds)
  (define b (parse-answer answer))
  (define issues (check-bundle b))
  (hasheq 'note name 'round round 'seconds seconds 'bundle b
          'issues issues 'score (score-facts (bundle-facts b) (read-expected name))))

;; replay-note : recorded-dir name -> result   the recorded answers, checked and scored again
(define (replay-note record-dir name)
  (define dir (build-path record-dir name))
  (hasheq 'note name
          'rounds (for/list ([round (in-naturals 1)]
                             #:break (not (file-exists? (build-path dir (format "round-~a.answer.txt" round)))))
                    (define r (string->jsexpr (file->string (build-path dir (format "round-~a.result.json" round)))))
                    (round-result name round (file->string (build-path dir (format "round-~a.answer.txt" round)))
                                  (hash-ref r 'seconds #f)))))

(module+ test
  (require rackunit)
  ;; the contract compiled: four profiles
  (check-equal? (length profiles) 4)
  ;; a conforming bundle for the Ng note passes and scores fully; mistakes are named with their path
  (define (prof id) (hasheq 'profile (list (string-append canonical "/StructureDefinition/" id))))
  (define (qty v) (hasheq 'value v 'unit "mm[Hg]" 'system "http://unitsofmeasure.org" 'code "mm[Hg]"))
  (define (cc system code display) (hasheq 'coding (list (hasheq 'system system 'code code 'display display))))
  (define ok
    (hasheq 'resourceType "Bundle" 'type "collection"
            'entry (map (lambda (r) (hasheq 'resource r))
                        (list (hasheq 'resourceType "Patient" 'id "ann" 'meta (prof "note-patient")
                                      'name (list (hasheq 'family "Ng" 'given (list "Ann"))) 'gender "female" 'birthDate "1961-04-12")
                              (hasheq 'resourceType "Observation" 'id "bp" 'meta (prof "note-blood-pressure") 'status "final"
                                      'code (cc "http://loinc.org" "85354-9" "Blood pressure panel")
                                      'subject (hasheq 'reference "Patient/ann") 'effectiveDateTime "2026-10-14"
                                      'component (list (hasheq 'code (cc "http://loinc.org" "8480-6" "Systolic blood pressure") 'valueQuantity (qty 152))
                                                       (hasheq 'code (cc "http://loinc.org" "8462-4" "Diastolic blood pressure") 'valueQuantity (qty 96))))
                              (hasheq 'resourceType "Condition" 'id "htn" 'meta (prof "note-problem")
                                      'subject (hasheq 'reference "Patient/ann")
                                      'clinicalStatus (cc "http://terminology.hl7.org/CodeSystem/condition-clinical" "active" "Active")
                                      'code (cc "http://snomed.info/sct" "38341003" "Hypertensive disorder"))
                              (hasheq 'resourceType "Condition" 'id "hld" 'meta (prof "note-problem")
                                      'subject (hasheq 'reference "Patient/ann")
                                      'clinicalStatus (cc "http://terminology.hl7.org/CodeSystem/condition-clinical" "active" "Active")
                                      'code (cc "http://snomed.info/sct" "55822004" "Hyperlipidemia"))
                              (hasheq 'resourceType "MedicationStatement" 'id "lis" 'meta (prof "note-medication") 'status "active"
                                      'subject (hasheq 'reference "Patient/ann")
                                      'medicationCodeableConcept (cc "http://www.nlm.nih.gov/research/umls/rxnorm" "29046" "lisinopril")
                                      'dosage (list (hasheq 'text "10 mg PO daily")))
                              (hasheq 'resourceType "MedicationStatement" 'id "ator" 'meta (prof "note-medication") 'status "active"
                                      'subject (hasheq 'reference "Patient/ann")
                                      'medicationCodeableConcept (cc "http://www.nlm.nih.gov/research/umls/rxnorm" "83367" "atorvastatin")
                                      'dosage (list (hasheq 'text "20 mg nightly")))))))
  (check-equal? (check-bundle ok) '())
  (check-equal? (score-facts (bundle-facts ok) (read-expected "ng"))
                (hasheq 'patient '(4 4 0) 'bloodPressures '(1 1 0) 'problems '(2 2 0) 'medications '(2 2 0)))
  ;; a code outside the IG's value set is an error at its path
  (define invented (hash-update ok 'entry
                                (lambda (es) (for/list ([e es])
                                               (if (equal? (hash-ref (hash-ref e 'resource) 'id) "htn")
                                                   (hasheq 'resource (hash-set (hash-ref e 'resource) 'code (cc "http://snomed.info/sct" "59621000" "Essential hypertension")))
                                                   e)))))
  (check-true (for/or ([i (in-list (check-bundle invented))]) (regexp-match? #rx"Condition/htn: Condition.code: code not in required value set" i)))
  ;; a Patient without its required fields; the others' subject is no longer the Bundle's Patient
  (check-true (for/or ([i (in-list (check-bundle (hash-update ok 'entry (lambda (es) (cons (hasheq 'resource (hasheq 'resourceType "Patient" 'id "x" 'meta (prof "note-patient"))) (cdr es))))))])
                (regexp-match? #rx"Patient.birthDate: minimum required" i))))
