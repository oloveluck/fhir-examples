#lang racket/base

;;; profile-materials.rkt — what an implementer or a checker of experiment V-profile is given about
;;; a profile: its published definition and what that definition rests on, as files; the sample
;;; resources; what "valid" means; the contract of the function to write.
;;;
;;;   (write-spec! profile dir)        dir/profile.json, types/, extensions/, terminology/
;;;   (write-sample! profile dir)      dir/case-NN.json: the profile's sample cases, unnamed
;;;   (sample-names profile)           (listof (cons "case-NN" case-name))
;;;   (profile-text profile)           PROFILE.md
;;;   contract-text                    CONTRACT.md
;;;
;;; Everything in spec/ is as published in the two packages the truth was judged in (US Core 9.0.0
;;; and FHIR R4's core), less each resource's narrative. WHICH definitions are given is a rule, not
;;; a choice: see `spec-files`.

(require racket/file racket/list racket/string json
         (only-in fhir/canonical canonical-url)
         (only-in fhir/package-set package-set)
         (only-in fhir/package read-package)
         "profile-cases.rkt")

(provide write-spec! write-sample! sample-names profile-text contract-text spec-files short-name)

;; ---- the two packages, by canonical ---------------------------------------------------------------
;; A Definition is a jsexpr: a StructureDefinition, ValueSet or CodeSystem of the packages.
;; definitions : -> (hash url Definition)   the first package that holds a url wins (the guide's)
(define definitions
  (let ([table #f])
    (lambda ()
      (or table
          (begin
            (set! table
                  (for*/fold ([h (hash)]) ([tgz (in-list (package-set guide-package))]
                                           [r (in-list (package-definitions tgz))])
                    (if (hash-has-key? h (hash-ref r 'url)) h (hash-set h (hash-ref r 'url) r))))
            table)))))

;; package-definitions : tgz -> (listof Definition)   a package's definitions that have a url
(define (package-definitions tgz)
  (define-values (_manifest resources _examples)
    (read-package tgz #:select (lambda (f) (regexp-match? #rx"^(StructureDefinition|ValueSet|CodeSystem)-" f))))
  (for/list ([r (in-list resources)] #:when (string? (hash-ref (cdr r) 'url #f))) (cdr r)))

(define (definition url) (hash-ref (definitions) (canonical-url url) #f))

;; elements : StructureDefinition -> (listof jsexpr)   its snapshot's elements
(define (elements sd) (hash-ref (hash-ref sd 'snapshot (hasheq)) 'element '()))

;; bound-value-sets : StructureDefinition -> (listof url)   every value set an element binds
(define (bound-value-sets sd)
  (for*/list ([e (in-list (elements sd))] [b (in-value (hash-ref e 'binding #f))]
              #:when (and (hash? b) (string? (hash-ref b 'valueSet #f))))
    (canonical-url (hash-ref b 'valueSet))))

;; named-extensions : StructureDefinition -> (listof url)   the extensions its elements are typed with
(define (named-extensions sd)
  (for*/list ([e (in-list (elements sd))] [t (in-list (hash-ref e 'type '()))]
              #:when (equal? (hash-ref t 'code #f) "Extension")
              [p (in-list (hash-ref t 'profile '()))])
    (canonical-url p)))

;; extension-urls : jsexpr -> (listof url)   every absolute extension url anywhere in a resource
(define (extension-urls v)
  (cond [(list? v) (append-map extension-urls v)]
        [(hash? v)
         (append (for*/list ([k (in-list '(extension modifierExtension))] [x (in-list (let ([xs (hash-ref v k '())]) (if (list? xs) xs '())))]
                             #:when (and (hash? x) (string? (hash-ref x 'url #f)) (regexp-match? #rx":" (hash-ref x 'url))))
                   (hash-ref x 'url))
                 (append-map extension-urls (hash-values v)))]
        [else '()]))

;; coding-systems : jsexpr -> (listof url)   the `system` of everything that has one beside a `code`
(define (coding-systems v)
  (cond [(list? v) (append-map coding-systems v)]
        [(hash? v)
         (append (if (and (string? (hash-ref v 'system #f)) (hash-has-key? v 'code)) (list (hash-ref v 'system)) '())
                 (append-map coding-systems (hash-values v)))]
        [else '()]))

;; included-systems : ValueSet -> (listof url)   the code systems its compose names, and those of
;; the value sets it includes (once each)
(define (included-systems vs [seen '()])
  (define includes (let ([c (hash-ref vs 'compose #f)]) (if (hash? c) (append (hash-ref c 'include '()) (hash-ref c 'exclude '())) '())))
  (remove-duplicates
   (append (for/list ([i (in-list includes)] #:when (string? (hash-ref i 'system #f))) (hash-ref i 'system))
           (for*/list ([i (in-list includes)] [u (in-list (hash-ref i 'valueSet '()))]
                       #:unless (member (canonical-url u) seen)
                       [inner (in-value (definition u))] #:when inner
                       [s (in-list (included-systems inner (cons (canonical-url u) seen)))])
             s))))

;; datatypes : -> (listof StructureDefinition)   FHIR R4's own datatypes: complex and primitive
(define (datatypes)
  (sort (for/list ([(url d) (in-hash (definitions))]
                   #:when (and (equal? (hash-ref d 'resourceType #f) "StructureDefinition")
                               (member (hash-ref d 'kind #f) '("complex-type" "primitive-type"))
                               (not (equal? (hash-ref d 'type #f) "Extension"))
                               (regexp-match? #rx"^http://hl7.org/fhir/StructureDefinition/[A-Za-z]+$" url)))
          d)
        string<? #:key (lambda (d) (hash-ref d 'id))))

;; spec-files : Profile -> (listof (cons relative-path Definition))
;; THE RULE for what is given, each as published in the packages the truth was judged in:
;;   profile.json            the profile
;;   types/                  the definition of the profile's resource type, and of every FHIR R4 datatype
;;   extensions/             every extension the profile's elements are typed with, or that one of
;;                           the profile's published examples carries, when the packages define it
;;   terminology/            every value set an element of any of those definitions binds (and the
;;                           value sets those include), every code system those value sets select
;;                           from, and every code system that is the `system` of a code in one of the
;;                           profile's published examples — each when the packages hold it
(define (spec-files p)
  (define sd (profile-definition p))
  (define examples (map cdr (profile-examples p)))
  (define base (definition (format "http://hl7.org/fhir/StructureDefinition/~a" (hash-ref sd 'type))))
  (define types (cons base (datatypes)))
  (define extensions
    (filter values (map definition (remove-duplicates (append (named-extensions sd) (append-map extension-urls examples))))))
  (define structures (append (list sd) types extensions))
  (define value-sets
    (let loop ([todo (remove-duplicates (append-map bound-value-sets structures))] [done '()])
      (cond [(null? todo) (reverse done)]
            [(or (member (car todo) (map (lambda (d) (hash-ref d 'url)) done)) (not (definition (car todo)))) (loop (cdr todo) done)]
            [else
             (define vs (definition (car todo)))
             (define inner (for*/list ([i (in-list (let ([c (hash-ref vs 'compose #f)]) (if (hash? c) (hash-ref c 'include '()) '())))]
                                       [u (in-list (hash-ref i 'valueSet '()))])
                             (canonical-url u)))
             (loop (append (cdr todo) inner) (cons vs done))])))
  (define code-systems
    (filter (lambda (d) (and d (equal? (hash-ref d 'resourceType #f) "CodeSystem")))
            (map definition (remove-duplicates (append (append-map included-systems value-sets) (append-map coding-systems examples))))))
  (define (named dir ds) (for/list ([d (in-list ds)]) (cons (format "~a/~a-~a.json" dir (hash-ref d 'resourceType) (hash-ref d 'id)) d)))
  (append (list (cons "profile.json" sd))
          (for/list ([d (in-list types)]) (cons (format "types/~a.json" (hash-ref d 'id)) d))
          (for/list ([d (in-list extensions)]) (cons (format "extensions/~a.json" (hash-ref d 'id)) d))
          (named "terminology" (sort (append value-sets code-systems) string<? #:key (lambda (d) (hash-ref d 'id))))))

;; write-spec! : Profile dir -> void   the files of `spec-files`, each without its narrative
(define (write-spec! p dir)
  (for ([f (in-list (spec-files p))])
    (define to (build-path dir (car f)))
    (make-directory* (let-values ([(base _n _d) (split-path to)]) base))
    (call-with-output-file to #:exists 'truncate (lambda (o) (write-json (hash-remove (cdr f) 'text) o)))))

;; ---- the sample ---------------------------------------------------------------------------------------
;; sample-names : Profile -> (listof (cons string case-name))   the sample cases under names that say
;; nothing of what was changed, in an order that is the same every time and not the catalogue's
(define (sample-names p)
  (define mine (filter (lambda (n) (sample-case? p n)) (map car (cases p))))
  (define shuffled (sort mine string<? #:key (lambda (n) (number->string (equal-hash-code* n)))))
  (for/list ([n (in-list shuffled)] [i (in-naturals 1)])
    (cons (format "case-~a" (if (< i 10) (format "0~a" i) i)) n)))

;; equal-hash-code* : string -> natural   a hash that does not change between runs or machines
(define (equal-hash-code* s)
  (for/fold ([h 5381]) ([c (in-string s)]) (modulo (+ (* h 33) (char->integer c)) 1000000007)))

;; write-sample! : Profile dir -> void
(define (write-sample! p dir)
  (make-directory* dir)
  (define by-name (for/hash ([c (in-list (cases p))]) (values (car c) (cdr c))))
  (for ([s (in-list (sample-names p))])
    (call-with-output-file (build-path dir (string-append (car s) ".json")) #:exists 'truncate
      (lambda (o) (write-json (hash-ref by-name (cdr s)) o)))))

;; ---- the words ------------------------------------------------------------------------------------------
;; short-name : Profile -> string
(define (short-name p) (regexp-replace #rx"^us-core-" p ""))

;; profile-text : Profile -> string   PROFILE.md: the profile, what is in spec/, what valid means
(define (profile-text p)
  (define sd (profile-definition p))
  (string-append
   (format "# ~a\n\n" (hash-ref sd 'title (hash-ref sd 'name)))
   (format "A profile of the FHIR R4 resource type ~a, published in the US Core Implementation Guide 9.0.0.\n" (hash-ref sd 'type))
   (format "Canonical: ~a\n\n" (hash-ref sd 'url))
   (let ([d (hash-ref sd 'description #f)]) (if (string? d) (string-append d "\n\n") ""))
   "## What is in spec/\n\n"
   "Everything as published (FHIR JSON), without the narrative:\n\n"
   "- spec/profile.json: the profile's StructureDefinition (its `snapshot` holds every element with its cardinality, types, "
   "bindings, fixed and pattern values, slicing and constraints; its `differential` what the profile changes)\n"
   (format "- spec/types/: the StructureDefinitions of ~a and of every FHIR R4 datatype\n" (hash-ref sd 'type))
   "- spec/extensions/: the StructureDefinitions of the extensions the profile names or its published examples carry\n"
   "- spec/terminology/: the ValueSets those definitions bind and the CodeSystems they select from, and the CodeSystems of "
   "the codes in the profile's published examples, where FHIR R4 or the guide publishes them\n\n"
   "## What valid means\n\n"
   "A resource is VALID when HL7's FHIR validator (the reference validator, validator_cli) reports no ERROR for it against "
   "this profile. Warnings and information messages do not count. It was run on FHIR R4 with this guide, WITHOUT a terminology "
   "server: codes are checked against the code systems and value sets of FHIR R4 and of the guide only (those in "
   "spec/terminology/); a code of any other system (SNOMED CT, LOINC, RxNorm, a system of your own) is not checked, in any "
   "binding. `http://example.org/…` urls are allowed. So valid means: the JSON is FHIR R4's for the resource type and its "
   "datatypes, the profile's constraints hold, and so do the definitions the resource's extensions name.\n"))

;; contract-text : string   CONTRACT.md
(define contract-text
  (string-append
   "# The function\n\n"
   "validator.py defines\n\n"
   "    def valid(resource) -> bool\n\n"
   "- `resource`: a dict, one FHIR R4 resource as parsed from its JSON (json.load).\n"
   "- Returns True when the resource is valid against the profile, as PROFILE.md says what valid means, and False when it is not.\n\n"
   "validator.py is one file. It may read the files of spec/, which will be beside it (find them from `__file__`), when it is "
   "imported or when `valid` is called; everything else it needs is in validator.py itself. Python 3's standard library only. "
   "It is given at most 20 seconds a resource, and a minute to import. An exception counts as a wrong answer.\n"))

(module+ test
  (require rackunit)
  (define p "us-core-patient")
  (define files (spec-files p))
  (check-equal? (car (car files)) "profile.json")
  ;; the rule's four parts are there, and each file once
  (check-not-false (assoc "types/Patient.json" files))
  (check-not-false (assoc "types/HumanName.json" files))
  (check-not-false (assoc "types/date.json" files))
  (check-not-false (assoc "extensions/us-core-race.json" files))
  (check-not-false (assoc "terminology/ValueSet-administrative-gender.json" files))
  (check-not-false (assoc "terminology/CodeSystem-administrative-gender.json" files))
  (check-false (check-duplicates (map car files)))
  ;; no Extension among the types (an extension is given by its own definition), no resource but the profile's
  (check-false (assoc "types/Extension.json" (filter (lambda (f) (equal? (hash-ref (cdr f) 'kind #f) "resource")) (cdr files))))
  ;; the sample: every sample case once, under names that do not say what was changed
  (define names (sample-names p))
  (check-equal? (sort (map cdr names) string<?) (sort (filter (lambda (n) (sample-case? p n)) (map car (cases p))) string<?))
  (check-true (andmap (lambda (n) (regexp-match? #px"^case-[0-9]{2,}$" (car n))) names))
  (check-equal? names (sample-names p) "the same every time")
  (check-false (equal? (map cdr names) (filter (lambda (n) (sample-case? p n)) (map car (cases p)))) "not the catalogue's order")
  (check-regexp-match #rx"reports no ERROR" (profile-text p))
  (check-regexp-match #rx"def valid[(]resource[)]" contract-text)
  (check-equal? (short-name "us-core-condition-problems-health-concerns") "condition-problems-health-concerns"))
