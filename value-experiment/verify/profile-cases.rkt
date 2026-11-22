#lang racket/base

;;; profile-cases.rkt — the material of V-profile (value-experiment/PROTOCOL.md): profiles of a
;;; published guide, each with the guide's own examples of it and resources changed from them by
;;; one change each, and for every such resource the verdict of HL7's reference validator.
;;;
;;;   racket profile-cases.rkt write DIR          the cases of every profile, DIR/<profile>/<case>.json
;;;   racket profile-cases.rkt label DIR JAR      HL7's validator (validator_cli.jar) run over them;
;;;                                               its verdicts written to truth/<profile>.json
;;;   racket profile-cases.rkt ceiling            the toolkit's validator against those verdicts
;;;
;;; Data definitions.
;;; A Profile is a string: the id of a StructureDefinition of the guide ("us-core-patient").
;;; A Case is (cons name resource): a name ("<example id>" for an example as published,
;;;   "<example id>~<kind>-<n>" for a resource changed from it) and the resource as a jsexpr.
;;; A Change is (list kind path resource): one change made to an example — its kind, where, the result.
;;; Truth is (hash name boolean): whether HL7's validator finds no error in the case.

(require racket/file racket/list racket/string racket/runtime-path racket/port racket/system json file/untgz
         (only-in fhir/spec-package spec-package-path)
         (only-in fhir/package-set package-set)
         (only-in fhir/conformance/validate write-errors/rows))

(provide guide-package profiles profile-definition profile-url profile-examples changes cases
         sample-case? truth toolkit-valid? case-example)

(define guide-package (spec-package-path "hl7.fhir.us.core.tgz"))
(define-runtime-path truth-dir "truth")

;; guide-resources : -> (hash file-name jsexpr)   the guide package's JSON files, read once
(define guide-resources
  (let ([cache #f])
    (lambda ()
      (or cache
          (let ([dir (make-temporary-file "guide-~a" 'directory)])
            (untgz guide-package #:dest dir)
            (set! cache
                  (for/hash ([f (in-directory dir)] #:when (regexp-match? #rx"[.]json$" (path->string f)))
                    (values (path->string (find-relative-path* dir f))
                            (with-handlers ([exn:fail? (lambda (_) #f)]) (call-with-input-file f read-json)))))
            (delete-directory/files dir)
            cache)))))
(define (find-relative-path* base f)
  (apply build-path (list-tail (explode-path f) (length (explode-path base)))))

;; resource-profile-definitions : -> (listof jsexpr)   the guide's profiles of resources
(define (resource-profile-definitions)
  (for/list ([(name r) (in-hash (guide-resources))]
             #:when (and (hash? r) (equal? (hash-ref r 'resourceType #f) "StructureDefinition")
                         (equal? (hash-ref r 'kind #f) "resource") (not (regexp-match? #rx"/example/" name))))
    r))

;; examples-of : url -> (listof Case)   the guide's examples that claim the profile, in id order
(define (examples-of url)
  (sort (for/list ([(name r) (in-hash (guide-resources))]
                   #:when (and (hash? r) (regexp-match? #rx"example/" name)
                               (member url (map (lambda (p) (car (string-split p "|")))
                                                (let ([m (hash-ref r 'meta #f)]) (if (hash? m) (hash-ref m 'profile '()) '()))))))
          (cons (hash-ref r 'id) r))
        string<? #:key car))

;; profiles : -> (listof Profile)   the rule, stated before any session: of the guide's profiles
;; with at least four published examples, the six with the most elements in their differential
(define (profiles)
  (define ranked
    (sort (for/list ([sd (in-list (resource-profile-definitions))]
                     #:when (>= (length (examples-of (hash-ref sd 'url))) 4))
            (cons (hash-ref sd 'id) (length (hash-ref (hash-ref sd 'differential (hasheq)) 'element '()))))
          (lambda (a b) (or (> (cdr a) (cdr b)) (and (= (cdr a) (cdr b)) (string<? (car a) (car b)))))))
  (map car (take ranked (min 6 (length ranked)))))

;; profile-definition : Profile -> jsexpr   its StructureDefinition, as published
(define (profile-definition p)
  (or (findf (lambda (sd) (equal? (hash-ref sd 'id) p)) (resource-profile-definitions))
      (raise-user-error 'profile-cases "the guide has no profile ~a" p)))
(define (profile-url p) (hash-ref (profile-definition p) 'url))
;; profile-examples : Profile -> (listof Case)
(define (profile-examples p) (examples-of (profile-url p)))

;; ---- one change to a resource -----------------------------------------------------------------------
;; The changes know nothing of the profile: they are what can be done to any JSON resource. Which
;; of them break the profile is HL7's validator's to say.

;; replaced : jsexpr (listof (or/c symbol natural)) (jsexpr -> jsexpr) -> jsexpr   the value at a
;; path replaced by a function of it
(define (replaced j path f)
  (cond [(null? path) (f j)]
        [(hash? j) (hash-set j (car path) (replaced (hash-ref j (car path)) (cdr path) f))]
        [else (for/list ([x (in-list j)] [i (in-naturals)]) (if (= i (car path)) (replaced x (cdr path) f) x))]))
;; removed : jsexpr path -> jsexpr   the key at the path's end taken out of its object
(define (removed j path)
  (replaced j (drop-right path 1) (lambda (o) (hash-remove o (last path)))))

;; places : jsexpr natural -> (listof (cons path value))   every value down to a depth, with its path
(define (places j depth [path '()])
  (cond [(zero? depth) '()]
        [(hash? j) (append* (for/list ([k (in-list (sort (hash-keys j) symbol<?))])
                              (define p (append path (list k)))
                              (cons (cons p (hash-ref j k)) (places (hash-ref j k) (sub1 depth) p))))]
        [(list? j) (append* (for/list ([x (in-list j)] [i (in-naturals)])
                              (define p (append path (list i)))
                              (cons (cons p x) (places x depth p))))]
        [else '()]))

(define coded-keys '(code system status intent gender use unit priority clinicalStatus verificationStatus))
(define kept-keys '(resourceType id meta text))

;; changes : jsexpr -> (listof Change)   every single change of the catalogue to a resource:
;; an element removed; a coded string replaced by one no code system has; a list's first entry
;; given twice; a number, a boolean or a date written as text that is none; an element the type
;; does not have added beside one
(define (changes resource)
  (define here (filter (lambda (pl) (not (memq (car (car pl)) kept-keys))) (places resource 4)))
  (define (key-of pl) (let ([k (last (car pl))]) (and (symbol? k) k)))
  (append
   (for/list ([pl (in-list here)] #:when (key-of pl))
     (list 'remove (car pl) (removed resource (car pl))))
   (for/list ([pl (in-list here)] #:when (and (memq (key-of pl) coded-keys) (string? (cdr pl))))
     (list 'code (car pl) (replaced resource (car pl) (lambda (_) (if (eq? (key-of pl) 'system) "http://example.org/not-a-code-system" "not-a-code")))))
   (for/list ([pl (in-list here)] #:when (and (list? (cdr pl)) (pair? (cdr pl))))
     (list 'twice (car pl) (replaced resource (car pl) (lambda (l) (cons (car l) l)))))
   (for/list ([pl (in-list here)]
              #:when (or (boolean? (cdr pl)) (real? (cdr pl))
                         (and (string? (cdr pl)) (regexp-match? #px"^[0-9]{4}-[0-9]{2}(-[0-9]{2})?" (cdr pl)))))
     (list 'text (car pl) (replaced resource (car pl) (lambda (_) "not-a-value"))))
   (for/list ([pl (in-list here)] #:when (hash? (cdr pl)))
     (list 'unknown (car pl) (replaced resource (car pl) (lambda (o) (hash-set o 'notAnElement "x")))))))

;; changes-kept : how many changed resources of each kind a case's example gives
(define changes-kept 6)

;; chosen : (listof Change) string -> (listof Change)   for each kind, a fixed number of its
;; changes, picked by a draw seeded by the example's id
(define (chosen all seed)
  (define rng (make-pseudo-random-generator))
  (parameterize ([current-pseudo-random-generator rng])
    (random-seed (for/fold ([h 7]) ([c (in-string seed)]) (modulo (+ (* h 31) (char->integer c)) 2147483647)))
    (append*
     (for/list ([kind (in-list '(remove code twice text unknown))])
       (define mine (filter (lambda (c) (eq? (car c) kind)) all))
       (take (shuffle mine) (min changes-kept (length mine)))))))

;; cases : Profile -> (listof Case)   each example as published, then the resources changed from it
(define (cases p)
  (append*
   (for/list ([ex (in-list (profile-examples p))])
     (cons ex
           (for/list ([c (in-list (chosen (changes (cdr ex)) (car ex)))] [n (in-naturals 1)])
             (cons (format "~a~~~a-~a" (car ex) (car c) n) (caddr c)))))))

;; case-example : string -> string   the example a case is, or was changed from
(define (case-example name) (car (string-split name "~")))

;; sample-case? : Profile string -> boolean   the cases of a profile's first example (in id order)
;; are what implementers and checkers are shown; the other examples' cases are held out
(define (sample-case? p name) (equal? (case-example name) (car (car (profile-examples p)))))

;; ---- truth: HL7's validator ---------------------------------------------------------------------------
;; truth : Profile -> Truth   its verdicts, as `label` wrote them
(define (truth p)
  (define f (build-path truth-dir (string-append p ".json")))
  (unless (file-exists? f) (raise-user-error 'profile-cases "no verdicts for ~a: run `profile-cases.rkt label`" p))
  (for/hash ([(k v) (in-hash (call-with-input-file f read-json))]) (values (symbol->string k) v)))

;; write-cases! : dir -> void
(define (write-cases! dir)
  (for ([p (in-list (profiles))])
    (define d (build-path dir p))
    (when (directory-exists? d) (delete-directory/files d))
    (make-directory* d)
    (for ([c (in-list (cases p))])
      (call-with-output-file (build-path d (string-append (car c) ".json")) (lambda (o) (write-json (cdr c) o))))))

;; outcome-errors? : jsexpr -> boolean   an OperationOutcome with an issue of severity error or fatal
(define (outcome-errors? oo)
  (for/or ([i (in-list (hash-ref oo 'issue '()))]) (and (member (hash-ref i 'severity #f) '("error" "fatal")) #t)))

;; outcome-file : jsexpr -> string | #f   the file an OperationOutcome of the validator is about
(define (outcome-file oo)
  (for/or ([e (in-list (hash-ref oo 'extension '()))])
    (and (regexp-match? #rx"operationoutcome-file" (hash-ref e 'url ""))
         (let ([v (hash-ref e 'valueString #f)]) (and v (regexp-replace #rx"[.]json$" (last (string-split v "/")) ""))))))

;; label! : dir path -> void   HL7's validator over each profile's cases, held to that profile, with
;; no terminology server (it is not reachable from here: codes of external systems are not checked)
(define (label! dir jar)
  (make-directory* truth-dir)
  (for ([p (in-list (profiles))])
    (define out (build-path dir (string-append p ".outcomes.json")))
    (define log (build-path dir (string-append p ".log")))
    (with-output-to-file log #:exists 'truncate
      (lambda ()
        (parameterize ([current-error-port (current-output-port)])
          (system* (find-executable-path "java") "-jar" (path->string (path->complete-path jar))
                   (path->string (build-path dir p)) "-version" "4.0.1" "-ig" (path->string guide-package)
                   "-profile" (profile-url p) "-tx" "n/a" "-output" (path->string out)))))
    (define result (call-with-input-file out read-json))
    (define outcomes (if (equal? (hash-ref result 'resourceType #f) "Bundle")
                         (map (lambda (e) (hash-ref e 'resource)) (hash-ref result 'entry '()))
                         (list result)))
    (define verdicts (for/hash ([oo (in-list outcomes)] #:when (outcome-file oo)) (values (outcome-file oo) (not (outcome-errors? oo)))))
    (define names (map car (cases p)))
    (unless (for/and ([n (in-list names)]) (hash-has-key? verdicts n))
      (raise-user-error 'label "HL7's validator answered ~a of ~a cases of ~a (see ~a)" (hash-count verdicts) (length names) p log))
    (call-with-output-file (build-path truth-dir (string-append p ".json")) #:exists 'truncate
      (lambda (o) (write-json (for/hasheq ([n (in-list names)]) (values (string->symbol n) (hash-ref verdicts n))) o)))
    (printf "~a: ~a cases, ~a valid by HL7's validator\n" p (length names) (count (lambda (n) (hash-ref verdicts n)) names))))

;; ---- the oracle: this toolkit's validator ---------------------------------------------------------
(define packages (let ([ps #f]) (lambda () (or ps (begin (set! ps (map path->string (package-set guide-package))) ps)))))

;; toolkit-valid? : Profile jsexpr -> boolean   no error from fhir-validation, the resource held to
;; the profile (claimed in meta.profile, as the examples claim it) in the guide's package context
(define (toolkit-valid? p resource)
  (define claimed
    (hash-set resource 'meta (hash-set (let ([m (hash-ref resource 'meta #f)]) (if (hash? m) m (hasheq))) 'profile (list (profile-url p)))))
  (null? (write-errors/rows (list (with-output-to-string (lambda () (write-json claimed))) (packages)))))

(module+ main
  (define args (vector->list (current-command-line-arguments)))
  (cond [(and (= (length args) 2) (equal? (car args) "write")) (write-cases! (cadr args))]
        [(and (= (length args) 3) (equal? (car args) "label")) (label! (cadr args) (caddr args))]
        [(equal? args '("ceiling"))
         (define rows
           (for*/list ([p (in-list (profiles))] [t (in-value (truth p))] [c (in-list (cases p))])
             (list p (car c) (hash-ref t (car c)) (toolkit-valid? p (cdr c)))))
         (for ([p (in-list (profiles))])
           (define mine (filter (lambda (r) (equal? (car r) p)) rows))
           (printf "~a: ~a cases, ~a valid by HL7's validator; the toolkit agrees on ~a (says valid where HL7 says not: ~a; says not where HL7 says valid: ~a)\n"
                   p (length mine) (count caddr mine) (count (lambda (r) (eq? (caddr r) (cadddr r))) mine)
                   (count (lambda (r) (and (cadddr r) (not (caddr r)))) mine) (count (lambda (r) (and (caddr r) (not (cadddr r)))) mine)))
         (define held (filter (lambda (r) (not (sample-case? (car r) (cadr r)))) rows))
         (printf "all: the toolkit agrees with HL7's validator on ~a of ~a cases (~a of the ~a held out)\n"
                 (count (lambda (r) (eq? (caddr r) (cadddr r))) rows) (length rows)
                 (count (lambda (r) (eq? (caddr r) (cadddr r))) held) (length held))]
        [else (raise-user-error 'profile-cases "write DIR | label DIR JAR | ceiling")]))

(module+ test
  (require rackunit)
  (define r (hasheq 'resourceType "Patient" 'id "a" 'active #t 'gender "female" 'birthDate "1950-01-05"
                    'name (list (hasheq 'family "Ng" 'given '("Ann")))))
  (check-equal? (replaced r '(name 0 family) (lambda (_) "X"))
                (hash-set r 'name (list (hasheq 'family "X" 'given '("Ann")))))
  (check-equal? (removed r '(name 0 given)) (hash-set r 'name (list (hasheq 'family "Ng"))))
  (define cs (changes r))
  ;; one change each, of the five kinds, never to the resource's type, id, meta or narrative
  (check-equal? (remove-duplicates (map car cs)) '(remove code twice text unknown))
  (check-false (for/or ([c (in-list cs)]) (memq (car (cadr c)) kept-keys)))
  (check-not-false (member (list 'remove '(gender) (hash-remove r 'gender)) cs))
  (check-not-false (member (list 'code '(gender) (hash-set r 'gender "not-a-code")) cs))
  (check-not-false (member (list 'text '(birthDate) (hash-set r 'birthDate "not-a-value")) cs))
  (check-not-false (member (list 'text '(active) (hash-set r 'active "not-a-value")) cs))
  (check-not-false (member (list 'twice '(name) (hash-set r 'name (list (car (hash-ref r 'name)) (car (hash-ref r 'name))))) cs))
  (check-not-false (member (list 'unknown '(name 0) (hash-set r 'name (list (hash-set (car (hash-ref r 'name)) 'notAnElement "x")))) cs))
  ;; the choice of changes is the same every time
  (check-equal? (chosen cs "a") (chosen cs "a"))
  (check-equal? (case-example "ex-1~remove-3") "ex-1")
  (check-true (outcome-errors? (hasheq 'issue (list (hasheq 'severity "warning") (hasheq 'severity "error")))))
  (check-false (outcome-errors? (hasheq 'issue (list (hasheq 'severity "information")))))
  (check-equal? (outcome-file (hasheq 'extension (list (hasheq 'url "http://hl7.org/fhir/StructureDefinition/operationoutcome-file" 'valueString "/x/y/ex-1~code-2.json"))))
                "ex-1~code-2")
  ;; the guide's profiles by the rule, each with its examples, its cases and a sample
  (define ps (profiles))
  (check-equal? (length ps) 6)
  (for ([p (in-list ps)])
    (check-true (>= (length (profile-examples p)) 4))
    (define names (map car (cases p)))
    (check-equal? names (remove-duplicates names))
    (check-true (< 0 (count (lambda (n) (sample-case? p n)) names) (length names)))))
