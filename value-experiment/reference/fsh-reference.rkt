#lang racket/base

;;; fsh-reference.rkt — this toolkit's FSH compiler beside SUSHI (value-experiment/PROTOCOL.md, H
;;; part 3). Everything that decides a result is here.
;;;
;;;   racket fsh-reference.rkt pairs DIR                  the texts and DIR/pairs.jsonl
;;;   racket fsh-reference.rkt ask DIR NODE_MODULES [N]   SUSHI over them (the Node bridge): DIR/answers.jsonl;
;;;                                                       with N, N texts are also given to SUSHI's own client
;;;   racket fsh-reference.rkt keep DIR FILE.gz           SUSHI's answers, in the compared form
;;;   racket fsh-reference.rkt ours DIR FILE.gz           this compiler's answers, in the compared form
;;;   racket fsh-reference.rkt report DIR REF.gz OURS.gz [OURS-AFTER.gz]
;;;   racket fsh-reference.rkt read DIR REF.gz OURS.gz [CLASS]      the SAMPLE's disagreements, by cause
;;;   racket fsh-reference.rkt read-opened DIR REF.gz OURS.gz [CLASS]   every disagreement, by cause
;;;   racket fsh-reference.rkt classes DIR REF.gz OURS.gz [opened]  every disagreement counted by class
;;;
;;; An Answer is "error" (the compiler reported an error, or raised) or the resources it wrote as
;;; one JSON text: each with its keys in order of name and numbers by value, in order of type and id.
;;; Beside each kept answers file is FILE-errors.json: id -> the first error's message.

(require racket/file racket/list racket/string racket/port racket/system racket/runtime-path racket/path json file/gzip file/gunzip
         (only-in fsh/project compile-project project-artifacts project-diagnostics)
         (only-in fhir/diagnostic diagnostic-severity diagnostic-message)
         "fsh-cases.rkt")

(provide canonical resources-answer our-answer read-answers read-errors fsh-rows classes class-of head-of agree? same-verdict?
         first-difference difference-paths as-compared)

(define-runtime-path bridge "SushiReference.js")
(define-runtime-path kept-reference "answers/fsh-reference.jsonl.gz")

;; ---- the compared form ---------------------------------------------------------------------------
;; canonical : jsexpr -> string   JSON with an object's keys in order of name and numbers by value
(define (canonical j)
  (cond [(hash? j) (string-append "{" (string-join (for/list ([k (in-list (sort (hash-keys j) symbol<?))])
                                                     (format "~s:~a" (symbol->string k) (canonical (hash-ref j k)))) ",") "}")]
        [(list? j) (string-append "[" (string-join (map canonical j) ",") "]")]
        ;; a number by its value, in a form JSON reads back: 1.0 and 1 are "1", 1.50 and 1.5 are "1.5"
        [(and (real? j) (not (boolean? j)))
         (let ([x (or (string->number (number->string j) 10 'number-or-false 'decimal-as-exact) j)])
           (if (and (exact? x) (integer? x)) (number->string x) (number->string (exact->inexact x))))]
        [else (jsexpr->string j)]))

;; resource-key : jsexpr -> string   what a resource is, for order and for pairing: its type and id
(define (resource-key r) (format "~a/~a" (hash-ref r 'resourceType "") (hash-ref r 'id "")))
;; resources-answer : (listof jsexpr) -> Answer
(define (resources-answer rs) (canonical (sort rs string<? #:key resource-key)))

;; reference-answer : jsexpr -> Answer   a line of the bridge's output
(define (reference-answer j)
  (cond [(hash-ref j 'crash #f) "error"]
        [(pair? (hash-ref j 'errors '())) "error"]
        [else (resources-answer (hash-ref j 'fhir '()))]))
(define (reference-message j)
  (cond [(hash-ref j 'crash #f) => (lambda (m) (string-append "crash: " m))]
        [(pair? (hash-ref j 'errors '())) (car (hash-ref j 'errors))]
        [else #f]))

;; ---- this compiler ---------------------------------------------------------------------------------
;; work : a project directory with the reference's settings, made once; each text is its one file
(define work
  (let ([made #f])
    (lambda ()
      (unless made
        (set! made (make-temporary-file "fsh-reference-~a" 'directory))
        (display-to-file "canonical: http://example.org\nfhirVersion: 4.0.1\nFSHOnly: true\nversion: 1.0.0\n"
                         (build-path made "sushi-config.yaml")))
      made)))

;; compile-text : string -> (values (listof jsexpr) (listof string))   the resources and the error
;; messages of the text compiled as a project of one file (what `raco fsh <dir>` does)
(define (compile-text text)
  (display-to-file text (build-path (work) "input.fsh") #:exists 'truncate)
  (define p (compile-project (work)))
  (values (project-artifacts p)
          (for/list ([d (in-list (project-diagnostics p))] #:when (eq? (diagnostic-severity d) 'error)) (diagnostic-message d))))

;; our-answer+message : string -> (values Answer (or/c string #f))
(define (our-answer+message text)
  (with-handlers ([exn:fail? (lambda (e) (values "error" (string-append "raised: " (car (string-split (exn-message e) "\n")))))])
    (define-values (rs errors) (compile-text text))
    (if (pair? errors) (values "error" (car errors)) (values (resources-answer rs) #f))))
(define (our-answer text) (let-values ([(a _m) (our-answer+message text)]) a))

;; ---- files -----------------------------------------------------------------------------------------
(define (pairs-file dir) (build-path dir "pairs.jsonl"))
(define (write-pairs! dir)
  (write-fsh-materials! dir)
  (define ps (all-fsh-pairs dir))
  (call-with-output-file (pairs-file dir) #:exists 'truncate
    (lambda (o) (for ([p (in-list ps)]) (write-json (pair->jsexpr p) o) (newline o))))
  (length ps))
(define (read-pairs dir)
  (call-with-input-file (pairs-file dir)
    (lambda (i) (for/list ([l (in-lines i)] #:unless (string=? l "")) (jsexpr->pair (string->jsexpr l))))))

(define (write-answers! file rows)
  (define-values (in out) (make-pipe))
  (define t (thread (lambda () (call-with-output-file file #:exists 'truncate (lambda (o) (gzip-through-ports in o #f 0))))))
  (for ([r (in-list rows)]) (write-json (hasheq 'id (car r) 'a (cadr r)) out) (newline out))
  (close-output-port out)
  (thread-wait t)
  (call-with-output-file (errors-file file) #:exists 'truncate
    (lambda (o) (write-json (for/hasheq ([r (in-list rows)] #:when (caddr r)) (values (string->symbol (car r)) (caddr r))) o))))
(define (read-answers file)
  (define-values (in out) (make-pipe))
  (define t (thread (lambda () (call-with-input-file file (lambda (i) (gunzip-through-ports i out))) (close-output-port out))))
  (begin0 (for/hash ([l (in-lines in)] #:unless (string=? l ""))
            (define j (string->jsexpr l))
            (values (hash-ref j 'id) (hash-ref j 'a)))
          (thread-wait t)))
(define (errors-file file) (path-replace-extension (path-replace-extension file #"") #"-errors.json"))
(define (read-errors file)
  (define f (errors-file file))
  (if (file-exists? f) (for/hash ([(k v) (in-hash (call-with-input-file f read-json))]) (values (symbol->string k) v)) (hash)))

;; ask-reference! : dir node-modules (or/c string #f) -> void   the bridge run over every text
(define (ask-reference! dir node-modules check)
  (define (abs rel) (path->string (simple-form-path (build-path dir rel))))
  (call-with-output-file (build-path dir "bridge-pairs.jsonl") #:exists 'truncate
    (lambda (o) (for ([p (in-list (read-pairs dir))])
                  (write-json (hasheq 'id (fsh-pair-id p) 'file (abs (fsh-pair-file p))) o) (newline o))))
  (putenv "NODE_PATH" (path->string (simple-form-path node-modules)))
  (unless (apply system* (find-executable-path "node") (path->string bridge)
                 (abs "bridge-pairs.jsonl") (abs "answers.jsonl") (if check (list "check" check) '()))
    (raise-user-error 'fsh-reference "the bridge failed, or differs from SUSHI's own client")))

(define (keep-reference! dir file)
  (define lines (call-with-input-file (build-path dir "answers.jsonl")
                  (lambda (i) (for/list ([l (in-lines i)] #:unless (string=? l "")) (string->jsexpr l)))))
  (write-answers! file (for/list ([j (in-list lines)]) (list (hash-ref j 'id) (reference-answer j) (reference-message j)))))

(define (keep-ours! dir file)
  (define rows (for/list ([p (in-list (read-pairs dir))])
                 (define-values (a m) (our-answer+message (file->string (build-path dir (fsh-pair-file p)))))
                 (list (fsh-pair-id p) a m)))
  ;; a compiler that does not load raises on every text, and "error" is an answer: say so instead
  (when (and (pair? rows) (andmap (lambda (r) (and (caddr r) (regexp-match? #rx"^raised: " (caddr r)))) rows))
    (raise-user-error 'fsh-reference "this compiler raised on every text: ~a" (caddr (car rows))))
  (write-answers! file rows))

;; ---- the comparison --------------------------------------------------------------------------------
;; as-compared : Answer Answer -> Answer   this compiler's answer as it is compared with the
;; reference's: without the `status` of a resource on which the reference wrote none (SUSHI's
;; client gives its configuration no status; its command line writes `draft` — the protocol's
;; entry "H part 3 after its first read")
(define (as-compared ref ours)
  (cond
    [(or (not (string? ref)) (not (string? ours)) (equal? ref "error") (equal? ours "error") (equal? ref ours)) ours]
    [else
     (define without-status
       (for/hash ([r (in-list (string->jsexpr ref))] #:unless (hash-has-key? r 'status)) (values (resource-key r) #t)))
     (resources-answer (for/list ([r (in-list (string->jsexpr ours))])
                         (if (hash-ref without-status (resource-key r) #f) (hash-remove r 'status) r)))]))

;; A Row is (list FshPair reference-answer our-answer reference-message our-message): our answer
;; as it is compared; a message is the first error's, or "".
(define (fsh-rows ps ref ours [ref-errors (hash)] [our-errors (hash)])
  (for/list ([p (in-list ps)])
    (define id (fsh-pair-id p))
    (define r (hash-ref ref id 'missing))
    (list p r (as-compared r (hash-ref ours id 'missing)) (hash-ref ref-errors id "") (hash-ref our-errors id ""))))
(define (ref-of r) (cadr r))
(define (ours-of r) (caddr r))
(define (ref-message r) (cadddr r))
(define (our-message r) (list-ref r 4))
(define (error? a) (equal? a "error"))
(define (agree? r) (equal? (ref-of r) (ours-of r)))
(define (same-verdict? r) (eq? (error? (ref-of r)) (error? (ours-of r))))
(define (percent a n) (if (zero? n) "-" (format "~a%" (/ (round (* 1000.0 (/ a n))) 10.0))))
(define (pad v n) (let ([s (format "~a" v)]) (string-append s (make-string (max 0 (- n (string-length s))) #\space))))

(define (print-agreement title rows)
  (printf "~a\n  ~a ~a ~a ~a ~a\n" title (pad "group" 11) (pad "part" 9) (pad "texts" 6) (pad "same answer" 15) "same verdict")
  (for* ([g '(published changed all)] [part '(sample held-out)])
    (define mine (filter (lambda (r) (and (or (eq? g 'all) (eq? (fsh-pair-group (car r)) g)) (eq? (fsh-pair-sample? (car r)) (eq? part 'sample)))) rows))
    (unless (null? mine)
      (printf "  ~a ~a ~a ~a ~a\n" (pad g 11) (pad part 9) (pad (length mine) 6)
              (pad (format "~a (~a)" (count agree? mine) (percent (count agree? mine) (length mine))) 15)
              (format "~a (~a)" (count same-verdict? mine) (percent (count same-verdict? mine) (length mine))))))
  (printf "  an error from the reference on ~a of the ~a texts, from this compiler on ~a, from both on ~a\n"
          (count (lambda (r) (error? (ref-of r))) rows) (length rows) (count (lambda (r) (error? (ours-of r))) rows)
          (count (lambda (r) (and (error? (ref-of r)) (error? (ours-of r)))) rows)))

;; ---- what a difference is --------------------------------------------------------------------------
;; first-difference : Answer Answer -> (values path detail)   for two answers that are both resources:
;; where they first differ, as a path with its indexes left out ("StructureDefinition.differential.
;; element.min"), and the two values there. Lists of objects that carry an `id` (a differential's
;; elements) are paired by it; other lists by position.
(define (first-difference ref ours)
  (define a (string->jsexpr ref))
  (define b (string->jsexpr ours))
  (define (short v) (let ([s (if (string? v) v (jsexpr->string v))]) (if (> (string-length s) 110) (string-append (substring s 0 110) "…") s)))
  (define (keyed? l) (and (pair? l) (andmap (lambda (x) (and (hash? x) (string? (hash-ref x 'id #f)))) l)))
  ;; diff : path jsexpr jsexpr -> (or/c (cons path detail) #f)
  (define (diff path x y)
    (cond
      [(equal? x y) #f]
      [(and (hash? x) (hash? y))
       (for/or ([k (in-list (sort (remove-duplicates (append (hash-keys x) (hash-keys y))) symbol<?))])
         (define p (format "~a.~a" path k))
         (cond [(not (hash-has-key? y k)) (cons p (format "only the reference: ~a" (short (hash-ref x k))))]
               [(not (hash-has-key? x k)) (cons p (format "only this compiler: ~a" (short (hash-ref y k))))]
               [else (diff p (hash-ref x k) (hash-ref y k))]))]
      [(and (list? x) (list? y) (keyed? x) (keyed? y))
       (define (ids l) (map (lambda (e) (hash-ref e 'id)) l))
       (define (by-id l id) (findf (lambda (e) (equal? (hash-ref e 'id) id)) l))
       (cond [(findf (lambda (id) (not (member id (ids y)))) (ids x))
              => (lambda (id) (cons (string-append path "(entry)") (format "only the reference: ~a" (short (by-id x id)))))]
             [(findf (lambda (id) (not (member id (ids x)))) (ids y))
              => (lambda (id) (cons (string-append path "(entry)") (format "only this compiler: ~a" (short (by-id y id)))))]
             [(for/or ([id (in-list (ids x))]) (diff path (by-id x id) (by-id y id))) => values]
             [else (cons (string-append path "(order)") (format "~a | ~a" (short (ids x)) (short (ids y))))])]
      [(and (list? x) (list? y))
       (cond [(not (= (length x) (length y))) (cons (string-append path "(length)") (format "~a | ~a" (short x) (short y)))]
             [else (for/or ([u (in-list x)] [v (in-list y)]) (diff path u v))])]
      [else (cons path (format "~a | ~a" (short x) (short y)))]))
  (define (keys l) (map resource-key l))
  (define found
    (cond [(findf (lambda (k) (not (member k (keys b)))) (keys a))
           => (lambda (k) (cons "(resources)" (format "only the reference: ~a" k)))]
          [(findf (lambda (k) (not (member k (keys a)))) (keys b))
           => (lambda (k) (cons "(resources)" (format "only this compiler: ~a" k)))]
          [else (for/or ([x (in-list a)] [y (in-list b)]) (diff (hash-ref x 'resourceType "?") x y))]))
  (if found (values (car found) (cdr found)) (values "(none)" "")))

;; difference-paths : Answer Answer -> (listof string)   every place two answers of resources
;; differ, each a path with its indexes left out, in order of name: the top-level elements of
;; each resource that are not equal, a differential's elements taken one level further
(define (difference-paths ref ours)
  (define a (string->jsexpr ref))
  (define b (string->jsexpr ours))
  (define (keys l) (map resource-key l))
  (define (by-key l k) (findf (lambda (r) (equal? (resource-key r) k)) l))
  (define (element-paths x y)   ; two differentials: what differs among their elements
    (define (els d) (if (hash? d) (hash-ref d 'element '()) '()))
    (define (ids l) (map (lambda (e) (hash-ref e 'id #f)) l))
    (define ex (els x))
    (define ey (els y))
    (append
     (if (for/or ([id (in-list (ids ex))]) (not (member id (ids ey)))) '("differential.element(only the reference)") '())
     (if (for/or ([id (in-list (ids ey))]) (not (member id (ids ex)))) '("differential.element(only this compiler)") '())
     (for*/list ([e (in-list ex)] [f (in-value (findf (lambda (f) (equal? (hash-ref f 'id #f) (hash-ref e 'id #f))) ey))] #:when f
                 [k (in-list (remove-duplicates (append (hash-keys e) (hash-keys f))))]
                 #:unless (equal? (hash-ref e k 'none) (hash-ref f k 'none)))
       (format "differential.element.~a" k))
     (if (and (equal? (sort (filter values (ids ex)) string<?) (sort (filter values (ids ey)) string<?)) (not (equal? (ids ex) (ids ey))))
         '("differential.element(order)") '())))
  (sort
   (remove-duplicates
    (append
     (for/list ([k (in-list (keys a))] #:unless (member k (keys b))) "(a resource only the reference wrote)")
     (for/list ([k (in-list (keys b))] #:unless (member k (keys a))) "(a resource only this compiler wrote)")
     (for*/list ([x (in-list a)] [y (in-value (by-key b (resource-key x)))] #:when y
                 [k (in-list (remove-duplicates (append (hash-keys x) (hash-keys y))))]
                 #:unless (equal? (hash-ref x k 'none) (hash-ref y k 'none))
                 [p (in-list (if (eq? k 'differential)
                                 (element-paths (hash-ref x k #f) (hash-ref y k #f))
                                 (list (symbol->string k))))])
       (format "~a.~a" (hash-ref x 'resourceType "?") p))))
   string<?))

;; cause : Row -> string   what a disagreement is about, for grouping: the reference's message or
;; this compiler's with what they quote left out, or the path of the first difference
(define (cause r)
  (define (plain m) (let ([s (regexp-replace* #px"\"[^\"]*\"|'[^']*'|`[^`]*`|\\b[0-9]+\\b|\\bFile: .*$" m "…")])
                      (if (> (string-length s) 100) (substring s 0 100) s)))
  (cond [(and (error? (ref-of r)) (not (error? (ours-of r)))) (string-append "the reference alone errs: " (plain (ref-message r)))]
        [(and (error? (ours-of r)) (not (error? (ref-of r)))) (string-append "this compiler alone errs: " (plain (our-message r)))]
        [else (string-append "differ at " (string-join (difference-paths (ref-of r) (ours-of r)) ", "))]))

;; ---- the classes of disagreement -------------------------------------------------------------------
;; A Class is (list name head rule): head 'ours | 'reference | 'open; rule : Row -> boolean, read from
;; the sample's disagreements alone. The first class whose rule holds is the row's.
;; without-units : jsexpr -> jsexpr   every Quantity's `unit` left out
(define (without-units j)
  (cond [(hash? j) (for/hasheq ([(k v) (in-hash j)] #:unless (eq? k 'unit)) (values k (without-units v)))]
        [(list? j) (map without-units j)]
        [else j]))
(define (results? r) (and (not (error? (ref-of r))) (not (error? (ours-of r)))))
;; unit-only? : Row -> boolean   two answers of resources that differ in nothing but a `unit`
(define (unit-only? r)
  (and (results? r) (equal? (without-units (string->jsexpr (ref-of r))) (without-units (string->jsexpr (ours-of r))))))
;; written-paths : the places where what this compiler wrote for an entity that states little, or
;; for a flag, differed from SUSHI's (each fixed in this pass)
(define written-paths
  '("StructureDefinition.differential.element(only the reference)" "StructureDefinition.differential.element(only this compiler)"
    "StructureDefinition.differential.element.extension" "ValueSet.compose" "CodeSystem.concept"))
(define (reference-alone r rx) (and (error? (ref-of r)) (not (error? (ours-of r))) (regexp-match? rx (ref-message r))))
(define classes
  (list
   (list "a quantity's unit: this compiler writes the UCUM code as the `unit` too, SUSHI writes a unit only for a display (decided earlier and said in fsh's manual; left)" 'open
         unit-only?)
   (list "a unit with its display and no number (`'[lb_av]' \"lb\"`): this compiler wrote the unit as the value and the display as the code" 'ours
         (lambda (r) (and (results? r) (regexp-match? #rx"Quantity\":\\{[^}]*\"value\":\"" (ours-of r)))))
   (list "what is written for an entity that states little, or for a flag: a bare root element, no empty compose, the standards status of TU/N/D, a concept named twice, an extension's scaffold" 'ours
         (lambda (r) (and (results? r) (let ([ps (difference-paths (ref-of r) (without-units-answer (ours-of r) (ref-of r)))])
                                         (and (pair? ps) (andmap (lambda (p) (member p written-paths)) ps))))))
   (list "a Ratio assigned in a profile: this compiler raised" 'ours
         (lambda (r) (and (error? (ours-of r)) (not (error? (ref-of r))) (regexp-match? #rx"^raised: " (our-message r)))))
   (list "an instance without an element its type requires: an error of SUSHI's compile; here `raco fsh check` says it (compiling does not validate)" 'open
         (lambda (r) (reference-alone r #rx"has minimum cardinality .* but occurs")))
   (list "a value set or a code's system named by a name nothing defines (\"is not a valid URI\"): written as the name here" 'ours
         (lambda (r) (reference-alone r #rx"is not a valid URI")))
   (list "an id that is no FHIR id" 'ours
         (lambda (r) (reference-alone r #rx"does not represent a valid FHIR id")))
   (list "`contains` on an element nothing says how to slice" 'ours
         (lambda (r) (reference-alone r #rx"No slicing found")))
   (list "a cardinality that does not fit within the base's" 'ours
         (lambda (r) (reference-alone r #rx"Cannot constrain cardinality")))
   (list "an extension slice with no Extension behind it, in a profile" 'ours
         (lambda (r) (reference-alone r #rx"Inline extensions should only be defined in Extensions")))
   (list "a Parent nothing defines, for an Extension or a Logical model" 'ours
         (lambda (r) (reference-alone r #rx"^Parent .* not found")))
   (list "an invariant no Invariant defines" 'ours
         (lambda (r) (reference-alone r #rx"because it was never defined")))
   (list "a path whose later step is no element, or an index in a profile's path: only a path's first step is checked here (named, not fixed)" 'ours
         (lambda (r) (reference-alone r #rx"No element found at path|The element or path you referenced does not exist")))
   (list "a name that is defined nowhere: a RuleSet inserted in a value set or code system, a Mapping's Source, an instance to embed, a concept's ancestor (named, not fixed)" 'ours
         (lambda (r) (reference-alone r #rx"Unable to find definition for RuleSet|Unable to find source|Could not find a resource named|Could not find .* in concept hierarchy")))
   (list "a value that does not fit its element: its type, a value the Parent already fixed, a code of one of FHIR's own required sets (named, not fixed)" 'ours
         (lambda (r) (reference-alone r #rx"Value does not match element type|does not match any of the allowed types|is already assigned|Missing required value|Invalid value: ")))))
;; without-units-answer : Answer Answer -> Answer   this compiler's answer without the units the
;; reference did not write (so that a difference in units does not hide the others)
(define (without-units-answer ours ref)
  (if (equal? (without-units (string->jsexpr ours)) (string->jsexpr ours)) ours
      (resources-answer (for/list ([o (in-list (string->jsexpr ours))] [r (in-list (string->jsexpr ref))]) (if (equal? (without-units o) (without-units r)) r (without-units o))))))
(define (class-of r) (or (for/first ([c (in-list classes)] #:when ((caddr c) r)) (car c)) "unclassified"))
(define (head-of r) (cond [(assoc (class-of r) classes) => cadr] [else 'unread]))

(define (short s n) (if (> (string-length s) n) (string-append (substring s 0 n) "…") s))

;; print-causes : dir (listof Row) (or/c string #f) boolean -> void   the disagreements (the
;; sample's, unless all?) grouped by class and cause, largest first, with two of each
(define (print-causes dir rows only all?)
  (define wrong (filter (lambda (r) (and (or all? (fsh-pair-sample? (car r))) (not (agree? r)))) rows))
  (define groups (group-by (lambda (r) (list (class-of r) (cause r))) wrong))
  (printf "~a disagreements in ~a causes\n" (length wrong) (length groups))
  (for ([g (in-list (sort groups > #:key length))] #:when (or (not only) (equal? only (class-of (car g)))))
    (define r0 (car g))
    (printf "\n~a texts [~a] ~a\n  corpora: ~a; changes: ~a\n" (length g) (short (class-of r0) 60) (cause r0)
            (string-join (remove-duplicates (map (lambda (r) (fsh-pair-corpus (car r))) g)) ", ")
            (short (string-join (remove-duplicates (map (lambda (r) (let ([c (fsh-pair-change (car r))]) (if (equal? c "") "published" c))) g)) ", ") 150))
    (for ([r (in-list (take g (min 2 (length g))))])
      (printf "  ~a  (~a~a)\n" (fsh-pair-file (car r)) (short (fsh-pair-base (car r)) 90)
              (if (equal? (fsh-pair-change (car r)) "") "" (string-append "; " (fsh-pair-change (car r)))))
      (cond [(and (error? (ref-of r)) (error? (ours-of r))) (void)]
            [(error? (ref-of r)) (printf "    reference: ~a\n" (short (ref-message r) 300))]
            [(error? (ours-of r)) (printf "    ours:      ~a\n" (short (our-message r) 300))]
            [else (let-values ([(path detail) (first-difference (ref-of r) (ours-of r))]) (printf "    ~a: ~a\n" path detail))]))))

(define (print-classes rows [held-out-note " (unread)"])
  (define wrong (filter (lambda (r) (not (agree? r))) rows))
  (printf "~a ~a ~a ~a\n" (pad "class" 100) (pad "head" 10) (pad "sample" 8) "held out")
  (for ([n (in-list (append (map car classes) '("unclassified")))])
    (define mine (filter (lambda (r) (equal? (class-of r) n)) wrong))
    (printf "~a ~a ~a ~a\n" (pad n 100) (pad (cond [(assoc n classes) => cadr] [else '-]) 10)
            (pad (count (lambda (r) (fsh-pair-sample? (car r))) mine) 8) (count (lambda (r) (not (fsh-pair-sample? (car r)))) mine)))
  (newline)
  (for ([part '(sample held-out all)])
    (define (in-part? r) (or (eq? part 'all) (eq? (fsh-pair-sample? (car r)) (eq? part 'sample))))
    (define all (filter in-part? rows))
    (define mine (filter in-part? wrong))
    (define (n head) (count (lambda (r) (eq? (head-of r) head)) mine))
    (printf "~a: ~a texts, ~a differ — the reference's departure ~a, this compiler's ~a, open ~a, in no class ~a~a\n"
            part (length all) (length mine) (n 'reference) (n 'ours) (n 'open) (n 'unread) (if (eq? part 'held-out) held-out-note ""))
    (printf "  the same answer, or a difference that is the reference's departure: ~a of ~a (~a)\n"
            (+ (- (length all) (length mine)) (n 'reference)) (length all) (percent (+ (- (length all) (length mine)) (n 'reference)) (length all)))))

(module+ main
  (define args (vector->list (current-command-line-arguments)))
  (define (rows-of dir ref ours) (fsh-rows (read-pairs dir) (read-answers ref) (read-answers ours) (read-errors ref) (read-errors ours)))
  (cond
    [(and (= (length args) 2) (equal? (car args) "pairs")) (printf "~a texts\n" (write-pairs! (cadr args)))]
    [(and (<= 3 (length args) 4) (equal? (car args) "ask")) (ask-reference! (cadr args) (caddr args) (and (= (length args) 4) (cadddr args)))]
    [(and (= (length args) 3) (equal? (car args) "keep")) (keep-reference! (cadr args) (caddr args))]
    [(and (= (length args) 3) (equal? (car args) "ours")) (keep-ours! (cadr args) (caddr args))]
    [(and (>= (length args) 4) (equal? (car args) "report"))
     (print-agreement "this compiler's answer is the reference's:" (rows-of (cadr args) (caddr args) (cadddr args)))
     (when (= (length args) 5) (newline) (print-agreement "after:" (rows-of (cadr args) (caddr args) (list-ref args 4))))]
    [(and (>= (length args) 4) (member (car args) '("read" "read-opened")))
     (print-causes (cadr args) (rows-of (cadr args) (caddr args) (cadddr args)) (and (= (length args) 5) (list-ref args 4)) (equal? (car args) "read-opened"))]
    [(and (= (length args) 4) (equal? (car args) "classes")) (print-classes (rows-of (cadr args) (caddr args) (cadddr args)))]
    [(and (= (length args) 5) (equal? (car args) "classes") (equal? (list-ref args 4) "opened"))
     (print-classes (rows-of (cadr args) (caddr args) (cadddr args)) " (opened and read)")]
    [else (eprintf "usage: fsh-reference.rkt pairs DIR | ask DIR NODE_MODULES [N] | keep DIR FILE | ours DIR FILE | report DIR REF OURS [AFTER] | read DIR REF OURS [CLASS] | classes DIR REF OURS [opened]\n")
          (exit 2)]))

(module+ test
  (require rackunit)
  (check-equal? (canonical (hasheq 'b 1.0 'a (list "x" #t))) "{\"a\":[\"x\",true],\"b\":1}")
  (check-equal? (reference-answer (hasheq 'id "1" 'fhir '() 'errors (list "bad") 'warnings 0)) "error")
  (check-equal? (reference-answer (hasheq 'id "1" 'crash "boom")) "error")
  (check-equal? (reference-answer (hasheq 'id "1" 'errors '() 'warnings 0
                                          'fhir (list (hasheq 'resourceType "Patient" 'id "b") (hasheq 'resourceType "Patient" 'id "a"))))
                "[{\"id\":\"a\",\"resourceType\":\"Patient\"},{\"id\":\"b\",\"resourceType\":\"Patient\"}]")
  ;; where two answers first differ: a differential's elements are paired by id
  (define (sd . elements) (resources-answer (list (hasheq 'resourceType "StructureDefinition" 'id "p" 'differential (hasheq 'element elements)))))
  (let-values ([(path detail) (first-difference (sd (hasheq 'id "Patient.name" 'min 1) (hasheq 'id "Patient.gender" 'max "1"))
                                                (sd (hasheq 'id "Patient.gender" 'max "1") (hasheq 'id "Patient.name" 'min 0)))])
    (check-equal? path "StructureDefinition.differential.element.min")
    (check-equal? detail "1 | 0"))
  (let-values ([(path detail) (first-difference (sd (hasheq 'id "Patient.name" 'min 1)) (sd))])
    (check-equal? path "StructureDefinition.differential.element(length)"))
  (let-values ([(path detail) (first-difference (sd (hasheq 'id "Patient.name" 'min 1)) (sd (hasheq 'id "Patient.gender" 'min 1)))])
    (check-equal? path "StructureDefinition.differential.element(entry)")
    (check-regexp-match #rx"only the reference" detail))
  ;; the compiler as it is now over every text, held to SUSHI's kept answers: the write-up's
  ;; agreement as floors, and nothing of the sample left in no class
  (let ([dir (make-temporary-file "fsh-reference-~a" 'directory)])
    (dynamic-wind
     void
     (lambda ()
       (write-fsh-materials! dir)
       (define ref (read-answers kept-reference))
       (define ref-errors (read-errors kept-reference))
       (define rows
         (for/list ([p (in-list (all-fsh-pairs dir))])
           (define-values (a m) (our-answer+message (file->string (build-path dir (fsh-pair-file p)))))
           (define r (hash-ref ref (fsh-pair-id p) 'missing))
           (list p r (as-compared r a) (hash-ref ref-errors (fsh-pair-id p) "") (or m ""))))
       (define (part sample?) (filter (lambda (r) (eq? (fsh-pair-sample? (car r)) sample?)) rows))
       (check-equal? (length rows) 2802)
       (check-false (ormap (lambda (r) (eq? (ref-of r) 'missing)) rows))
       (check-true (>= (count agree? (part #t)) 715))
       (check-true (>= (count agree? (part #f)) 1640))
       (check-true (>= (count same-verdict? rows) 2453))
       ;; this compiler alone reports an error on no text
       (check-equal? (count (lambda (r) (and (error? (ours-of r)) (not (error? (ref-of r))))) rows) 0)
       (check-equal? (count (lambda (r) (and (fsh-pair-sample? (car r)) (not (agree? r)) (eq? (head-of r) 'unread))) rows) 0))
     (lambda () (delete-directory/files dir))))
  ;; this compiler on a small text: a profile and an instance of it, no error
  (let-values ([(a m) (our-answer+message "Profile: MyPatient\nParent: Patient\n* name 1..* MS\n\nInstance: Ann\nInstanceOf: MyPatient\n* name.family = \"Lee\"\n")])
    (check-false m)
    (check-equal? (map (lambda (r) (hash-ref r 'resourceType)) (string->jsexpr a)) '("Patient" "StructureDefinition")))
  (let-values ([(a m) (our-answer+message "Profile: P\nParent: Patient\n* nmae 1..1\n")])
    (check-equal? a "error")
    (check-regexp-match #rx"nmae" m)))
