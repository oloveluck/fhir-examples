#lang racket/base

;;; fhirpath-cases.rkt — the pairs of H's first part (value-experiment/PROTOCOL.md, "FHIRPath held to
;;; HL7's Java engine"): published FHIRPath expressions over published resources, and both changed
;;; in one small way. The rules below are the protocol's; they were committed before any answer of
;;; the reference was read.
;;;
;;; Data definitions.
;;; A Pair is (pair id group type base expr file sample?):
;;;   id      a string, its place in the list
;;;   group   'search | 'invariant | 'probe | 'changed | 'suite
;;;   type    the resource type the expression is published for (a string; the suite: its input file)
;;;   base    the published expression it is, or was made from
;;;   expr    the expression evaluated
;;;   file    the resource it is evaluated over, relative to the work directory
;;;   sample? whether its disagreements may be read (else it is held out and only counted)
;;; A Published is (list type expression): an expression published for a resource type.

(require racket/file racket/list racket/string racket/path json file/sha1 file/untgz xml
         (only-in fhir/spec-package spec-package-path)
         (only-in "../verify/profile-cases.rkt" profiles cases change-kind))

(provide (struct-out fp-pair) all-pairs write-materials! continuations continued sample-expression? pair->jsexpr jsexpr->pair
         current-guide current-fresh? fresh-guide)

(struct fp-pair (id group type base expr file sample?) #:transparent)

(define guide-package (spec-package-path "hl7.fhir.us.core.tgz"))
(define core-package (spec-package-path "hl7.fhir.r4.core.tgz"))
;; The guide whose examples and definitions the pairs are made from (US Core for part 1), and
;; whether the set is a fresh one: another guide under the same rules, with no changed copies and
;; no suite (the second pass).
(define current-guide (make-parameter guide-package))
(define current-fresh? (make-parameter #f))
;; fresh-guide : string -> path
(define (fresh-guide name)
  (spec-package-path (cond [(equal? name "ips") "hl7.fhir.uv.ips.tgz"]
                           [(equal? name "mcode") "hl7.fhir.us.mcode-4.0.0.tgz"]
                           [else (raise-user-error 'fhirpath-cases "no fresh guide ~a (ips, mcode)" name)])))
(define suite-xml (build-path (collection-path "fhirpath") "tests" "vendor" "tests-fhir-r4.xml"))
(define suite-inputs (build-path (collection-path "fhirpath") "tests" "inputs-r4"))

;; ---- the packages, unpacked once into the work directory -----------------------------------------
;; unpacked! : dir -> void   guide/ and core/ under dir hold the two packages' files
(define (unpacked! dir)
  (for ([name '("guide" "core")] [tgz (list (current-guide) core-package)])
    (define d (build-path dir name))
    (unless (directory-exists? d)
      (make-directory* d)
      (untgz tgz #:dest d))))

;; json-files : dir -> (listof (cons path jsexpr))   the JSON objects of a directory, by file name
(define (json-files d)
  (for*/list ([f (in-list (sort (directory-list d) string<? #:key path->string))]
              #:when (regexp-match? #rx"[.]json$" (path->string f))
              [j (in-value (with-handlers ([exn:fail? (lambda (_) #f)]) (call-with-input-file (build-path d f) read-json)))]
              #:when (hash? j))
    (cons (build-path d f) j)))

;; ---- published resources -------------------------------------------------------------------------
;; examples : dir -> (hash type (listof (cons id relative-file)))   US Core's examples by type, in id order
(define (examples dir)
  (define all
    (for/list ([e (in-list (json-files (build-path dir "guide" "package" "example")))]
               #:when (and (string? (hash-ref (cdr e) 'resourceType #f)) (string? (hash-ref (cdr e) 'id #f))))
      (list (hash-ref (cdr e) 'resourceType) (hash-ref (cdr e) 'id)
            (path->string (find-relative-path (simple-form-path dir) (simple-form-path (car e)))))))
  (for/hash ([g (in-list (group-by car all))])
    (values (car (car g)) (sort (map (lambda (x) (cons (cadr x) (caddr x))) g) string<? #:key car))))

;; ---- published expressions -----------------------------------------------------------------------
;; definitions : dir -> (listof jsexpr)   the conformance resources of the core package and the guide
(define (definitions dir)
  (append (map cdr (json-files (build-path dir "core" "package")))
          (map cdr (json-files (build-path dir "guide" "package")))))

;; search-expressions : (listof jsexpr) (listof type) -> (listof Published)
;; every SearchParameter's expression, whole, for each of its bases that is one of the types
(define (search-expressions defs types)
  (remove-duplicates
   (for*/list ([d (in-list defs)]
               #:when (equal? (hash-ref d 'resourceType #f) "SearchParameter")
               [e (in-value (hash-ref d 'expression #f))]
               #:when (and (string? e) (not (string=? (string-trim e) "")))
               [b (in-list (hash-ref d 'base '()))]
               #:when (member b types))
     (list b e))))

;; invariant-expressions : (listof jsexpr) (listof type) -> (listof Published)
;; every constraint but ele-1 and ext-1 in the snapshot of a type's core definition and of the
;; guide's profiles of it, at an element whose path names no choice: as published on the
;; resource, `<path>.select(<expression>)` on an element
(define (invariant-expressions defs types)
  (remove-duplicates
   (for*/list ([d (in-list defs)]
               #:when (and (equal? (hash-ref d 'resourceType #f) "StructureDefinition")
                           (equal? (hash-ref d 'kind #f) "resource")
                           (member (hash-ref d 'type #f) types))
               [el (in-list (hash-ref (hash-ref d 'snapshot (hasheq)) 'element '()))]
               [path (in-value (hash-ref el 'path ""))]
               #:unless (regexp-match? #rx"\\[x\\]" path)
               [c (in-list (hash-ref el 'constraint '()))]
               [e (in-value (hash-ref c 'expression #f))]
               #:when (and (string? e) (not (member (hash-ref c 'key "") '("ele-1" "ext-1")))))
     (define type (hash-ref d 'type))
     (list type (if (equal? path type) e (format "~a.select(~a)" path e))))))

;; ---- one change to an expression -----------------------------------------------------------------
;; continuations : (listof string)   each a template in which E stands for the published
;; expression in parentheses. Between them they call the functions and operators of the
;; specification; none reads the clock.
(define continuations
  (let ([s "E.first().toString()"] [n "E.count()"])
    (append
     ;; existence
     '("E.empty()" "E.exists()" "E.exists($this.exists())" "E.all($this.exists())" "E.count()"
       "E.distinct().count()" "E.isDistinct()" "E.select($this.exists()).allTrue()"
       "E.select($this.empty()).anyTrue()" "E.select($this.exists()).allFalse()"
       "E.select($this.empty()).anyFalse()" "E.subsetOf(E)" "E.supersetOf(E.first())" "E.hasValue()"
       "E.first().hasValue()")
     ;; filtering and projection
     '("E.where($this.exists())" "E.select($this)" "E.ofType(string)" "E.ofType(code)" "E.ofType(dateTime)"
       "E.ofType(CodeableConcept)" "E.ofType(Reference)" "E.ofType(Quantity)" "E.repeat(children()).count()")
     ;; subsetting
     '("E[0]" "E.first()" "E.last()" "E.tail()" "E.skip(1)" "E.take(1)" "E.single()" "E.intersect(E)" "E.exclude(E.first())")
     ;; combining
     '("E | E" "E.union(E)" "E.combine(E)")
     ;; conversion
     '("E.first().toString()" "E.first().toInteger()" "E.first().toDecimal()" "E.first().toBoolean()"
       "E.first().toDate()" "E.first().toDateTime()" "E.first().toTime()" "E.first().toQuantity()"
       "E.first().convertsToString()" "E.first().convertsToInteger()" "E.first().convertsToDecimal()"
       "E.first().convertsToBoolean()" "E.first().convertsToDate()" "E.first().convertsToDateTime()"
       "E.first().convertsToTime()" "E.first().convertsToQuantity()" "iif(E.exists(), 'some', 'none')")
     ;; strings
     (for/list ([f '(".length()" ".upper()" ".lower()" ".substring(1)" ".substring(0, 2)" ".startsWith('a')"
                     ".endsWith('e')" ".contains('a')" ".indexOf('a')" ".replace('a', 'b')"
                     ".matches('^[A-Za-z]+$')" ".replaceMatches('[aeiou]', '*')" ".toChars().count()"
                     " + 'x'" " & 'x'" ".trim()" ".split('-').count()")])
       (string-append s f))
     '("E.select($this.toString()).join(',')")
     ;; math
     (for/list ([f '("~a + 1" "~a - 1" "~a * 2" "~a / 2" "~a div 2" "~a mod 2" "(~a / 3).round(2)" "~a.sqrt()"
                     "(~a + 0.5).floor()" "(~a + 0.5).ceiling()" "(~a + 0.5).truncate()" "(~a - 5).abs()"
                     "~a.power(2)" "(~a + 1).ln()" "~a.exp()" "(~a + 1).log(10)")])
       (format f n))
     ;; tree navigation
     '("E.children().count()" "E.descendants().count()" "E.children().first()")
     ;; types
     '("E.first() is string" "E.first() is CodeableConcept" "E.first().is(Reference)" "E.first() as string"
       "E.first().as(Quantity)" "E.first().type().name")
     ;; equality, comparison, membership
     '("E = E" "E != E" "E ~ E" "E !~ E" "E.first() = E.last()" "E.count() > 1" "E.first() < E.last()"
       "E.first() >= E.last()" "E.first() in E" "E contains E.first()")
     ;; boolean logic
     '("E.exists() and E.empty()" "E.exists() or E.empty()" "E.exists() xor true" "E.empty() implies false"
       "E.exists().not()")
     ;; dates, extensions, tracing
     '("E.ofType(date).first() + 1 month" "E.ofType(dateTime).first() + 1 day" "E.extension.count()"
       "E.first().extension('http://example.org/x').exists()" "E.trace('t')"))))

;; continued : string string -> string   a template with the expression in the place of each E
(define (continued template e)
  (regexp-replace* #px"\\bE\\b" template (regexp-replace-quote (string-append "(" e ")"))))

;; ---- sample and held out -------------------------------------------------------------------------
;; sample-expression? : type expression -> boolean   about a fifth of the published expressions:
;; the first byte of the SHA-1 of "<type> <expression>" is divisible by five
(define (sample-expression? type e)
  (zero? (modulo (bytes-ref (sha1-bytes (open-input-bytes (string->bytes/utf-8 (format "~a ~a" type e)))) 0) 5)))

;; ---- HL7's own suite -----------------------------------------------------------------------------
;; suite-tests : -> (listof (list input-file expression))   the R4 suite's tests that name an
;; input resource this repository holds as JSON
(define (suite-tests)
  (define doc (call-with-input-file suite-xml read-xml))
  (define (attr e name) (for/first ([a (in-list (element-attributes e))] #:when (eq? (attribute-name a) name)) (attribute-value a)))
  (define (text e) (apply string-append (for/list ([c (in-list (element-content e))])
                                          (cond [(pcdata? c) (pcdata-string c)]
                                                [(cdata? c) (regexp-replace* #rx"^<!\\[CDATA\\[|\\]\\]>$" (cdata-string c) "")]
                                                [(entity? c) (let ([t (entity-text c)]) (if (number? t) (string (integer->char t)) (case t [(lt) "<"] [(gt) ">"] [(amp) "&"] [(quot) "\""] [(apos) "'"] [else ""])))]
                                                [else ""]))))
  (let loop ([x (document-element doc)])
    (cond [(and (element? x) (eq? (element-name x) 'test))
           (define ex (for/first ([c (in-list (element-content x))] #:when (and (element? c) (eq? (element-name c) 'expression))) c))
           (define input (attr x 'inputfile))
           (define json (and input (regexp-replace #rx"[.]xml$" input ".json")))
           (if (and ex json (file-exists? (build-path suite-inputs json)))
               (list (list json (text ex)))
               '())]
          [(element? x) (append-map loop (element-content x))]
          [else '()])))

;; ---- the pairs -----------------------------------------------------------------------------------
;; changed-copies : dir -> (listof (list type relative-file))   V-profile's changed copies of the
;; three kinds that leave well-formed FHIR JSON, written under dir/changed
(define (changed-copies dir)
  (for*/list ([p (in-list (profiles))]
              [c (in-list (cases p))]
              #:when (member (change-kind (car c)) '("remove" "code" "twice")))
    (define rel (build-path "changed" p (string-append (car c) ".json")))
    (define f (build-path dir rel))
    (unless (file-exists? f)
      (make-directory* (build-path dir "changed" p))
      (call-with-output-file f (lambda (o) (write-json (cdr c) o))))
    (list (hash-ref (cdr c) 'resourceType) (path->string rel))))

;; write-materials! : dir -> void   the packages and the changed copies, where the pairs name them
(define (write-materials! dir)
  (make-directory* dir)
  (unpacked! dir)
  (unless (current-fresh?)
    (void (changed-copies dir))
    (make-directory* (build-path dir "suite"))
    (for ([f (in-list (directory-list suite-inputs))] #:when (regexp-match? #rx"[.]json$" (path->string f)))
      (copy-file (build-path suite-inputs f) (build-path dir "suite" f) #t))))

;; all-pairs : dir -> (listof Pair)   every pair, in a fixed order (write-materials! first)
(define (all-pairs dir)
  (define by-type (examples dir))
  (define types (sort (hash-keys by-type) string<?))
  (define defs (definitions dir))
  (define search (sort (search-expressions defs types) (lambda (a b) (string<? (format "~a ~a" (car a) (cadr a)) (format "~a ~a" (car b) (cadr b))))))
  (define invariant (sort (invariant-expressions defs types) (lambda (a b) (string<? (format "~a ~a" (car a) (cadr a)) (format "~a ~a" (car b) (cadr b))))))
  (define changed (if (current-fresh?) '() (changed-copies dir)))
  (define (over group published files-of)
    (for*/list ([p (in-list published)] [f (in-list (files-of (car p)))])
      (list group (car p) (cadr p) (cadr p) f (sample-expression? (car p) (cadr p)))))
  (define (examples-of type) (map cdr (hash-ref by-type type '())))
  (define (changed-of type) (for/list ([c (in-list changed)] #:when (equal? (car c) type)) (cadr c)))
  (define rows
    (append
     (over 'search search examples-of)
     (over 'invariant invariant examples-of)
     (for*/list ([p (in-list search)]
                 [f (in-list (let ([fs (examples-of (car p))]) (take fs (min 3 (length fs)))))]
                 [t (in-list continuations)])
       (list 'probe (car p) (cadr p) (continued t (cadr p)) f (sample-expression? (car p) (cadr p))))
     (over 'changed (append search invariant) changed-of)
     (if (current-fresh?)
         '()
         (for/list ([t (in-list (suite-tests))])
           (list 'suite (car t) (cadr t) (cadr t) (path->string (build-path "suite" (car t))) #t)))))
  (for/list ([r (in-list rows)] [i (in-naturals)])
    (apply fp-pair (number->string i) r)))

(define (pair->jsexpr p)
  (hasheq 'id (fp-pair-id p) 'group (symbol->string (fp-pair-group p)) 'type (fp-pair-type p) 'base (fp-pair-base p)
          'expr (fp-pair-expr p) 'file (fp-pair-file p) 'sample (fp-pair-sample? p)))
(define (jsexpr->pair j)
  (fp-pair (hash-ref j 'id) (string->symbol (hash-ref j 'group)) (hash-ref j 'type) (hash-ref j 'base)
        (hash-ref j 'expr) (hash-ref j 'file) (hash-ref j 'sample)))

(module+ test
  (require rackunit)
  (check-equal? (continued "E.first() = E.last()" "a | b") "(a | b).first() = (a | b).last()")
  (check-true (> (length continuations) 90))
  (check-equal? (length continuations) (length (remove-duplicates continuations)))
  ;; nothing reads the clock
  (check-false (ormap (lambda (t) (regexp-match? #rx"now\\(|today\\(|timeOfDay\\(" t)) continuations))
  ;; the split is a fixed function of the type and the expression
  (check-equal? (sample-expression? "Patient" "Patient.birthDate") (sample-expression? "Patient" "Patient.birthDate")))
