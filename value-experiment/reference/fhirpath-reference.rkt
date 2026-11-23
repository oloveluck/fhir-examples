#lang racket/base

;;; fhirpath-reference.rkt — this toolkit's FHIRPath engine beside HL7's Java engine
;;; (value-experiment/PROTOCOL.md, H part 1). Everything that decides a result is here: each
;;; engine's answer brought to one form, the comparison, the classes, the report.
;;;
;;;   racket fhirpath-reference.rkt pairs DIR            the materials and DIR/pairs.jsonl
;;;   racket fhirpath-reference.rkt fresh-pairs DIR ips|mcode   the same for another guide (the second pass's fresh set)
;;;   racket fhirpath-reference.rkt ask DIR JAR          HL7's engine over them (the Java bridge): DIR/answers.jsonl
;;;   racket fhirpath-reference.rkt keep DIR FILE.gz     the reference's answers, in the compared form
;;;   racket fhirpath-reference.rkt ours DIR FILE.gz     this engine's answers, in the compared form
;;;   racket fhirpath-reference.rkt report DIR REF.gz OURS.gz [OURS-AFTER.gz]
;;;   racket fhirpath-reference.rkt read DIR REF.gz OURS.gz [CLASS]   the SAMPLE's disagreements, by class
;;;   racket fhirpath-reference.rkt classes DIR REF.gz OURS.gz        every disagreement counted by class
;;;   racket fhirpath-reference.rkt suite DIR REF.gz OURS.gz          HL7's own suite: where the engines differ
;;;
;;; Data definitions.
;;; An Answer is "error" | (listof Item): the engine raised, or its result in order.
;;; An Item is (list kind value): kind one of "string" "integer" "decimal" "boolean" "date"
;;;   "dateTime" "time" "quantity" "complex"; value a string, or for a complex item the sorted
;;;   list of its primitive leaves, each "<path>=<value>".
;;; Answers is (hash id Answer).

(require racket/file racket/list racket/string racket/port racket/system racket/runtime-path racket/path json file/gzip file/gunzip
         (only-in fhir/r4/schemas)
         (only-in fhir/model/node fhir?)
         (only-in fhir/serialize/from-json from-json)
         (only-in fhir/serialize/read-json read-fhir-json)
         (only-in fhir/serialize/to-json node->jsexpr)
         (only-in fhir/result/result ok? ok-value)
         (only-in fhirpath/parser/parse parse-fhirpath)
         (only-in fhirpath/eval eval-fhirpath)
         (only-in fhirpath/value item->system item-fhir-type item-system-type prim-item? value-less?
                  fp-quantity? fp-quantity-value fp-quantity-unit typeinfo? typeinfo-namespace typeinfo-name)
         (only-in fhirpath/decimal decimal->string)
         (only-in fhirpath/render item->text)
         "fhirpath-cases.rkt")

(provide normal-reference our-answer read-answers read-errors agreement-rows classes class-of)

(define-runtime-path bridge "FhirPathReference.java")
(define-runtime-path kept-reference "answers/fhirpath-reference.jsonl.gz")
(define-runtime-path kept-ips "answers/fhirpath-fresh-ips-reference.jsonl.gz")
(define-runtime-path kept-mcode "answers/fhirpath-fresh-mcode-reference.jsonl.gz")

;; ---- the compared form ---------------------------------------------------------------------------
(define string-types '("string" "code" "uri" "url" "canonical" "id" "oid" "uuid" "markdown" "base64Binary" "xhtml"))
(define integer-types '("integer" "positiveInt" "unsignedInt" "integer64"))
(define quantity-types '("Quantity" "Age" "Count" "Distance" "Duration" "SimpleQuantity" "MoneyQuantity"))

;; kind-of-type : string -> string   the kind of a primitive of a FHIR type
(define (kind-of-type t)
  (cond [(member t string-types) "string"]
        [(member t integer-types) "integer"]
        [(member t '("dateTime" "instant")) "dateTime"]
        [(member t '("decimal" "boolean" "date" "time")) t]
        [else t]))

;; number-text : string -> string   a number as its exact value (1.0 and 1 are one value); other text as it is
(define (number-text s)
  (cond [(and (regexp-match? #px"^[+-]?[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$" s)
              (string->number s 10 'number-or-false 'decimal-as-exact))
         => number->string]
        [else s]))

;; instant-text : string -> string   a dateTime in UTC written with Z is the one written with +00:00
;; (the reference prints the second for an element whose text is the first)
(define (instant-text s)
  (if (regexp-match? #px"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z$" s) (regexp-replace #rx"Z$" s "+00:00") s))

;; valued : kind string -> Item   a primitive item; numbers and instants by value
(define (valued kind v)
  (list kind (cond [(member kind '("integer" "decimal")) (number-text v)]
                   [(equal? kind "dateTime") (instant-text v)]
                   [else v])))

;; quantity-item : string string -> Item
(define (quantity-item value unit) (list "quantity" (format "~a ~a" (number-text value) unit)))

;; dropped-leaf? : string -> boolean   a narrative's XHTML is not compared (the engines hold it differently)
(define (dropped-leaf? path) (regexp-match? #rx"(^|[.])div$" path))

;; ---- the reference's answers ---------------------------------------------------------------------
;; normal-reference : jsexpr -> Answer   a line of the bridge's output
(define (normal-reference j)
  (cond [(hash-ref j 'error #f) "error"]
        [else (map reference-item (hash-ref j 'items))]))

(define (reference-item i)
  (define t (hash-ref i 't))
  (cond [(or (hash-has-key? i 'v) (not (hash-has-key? i 'leaves)))   ; a primitive (one with no value is written without its `v`)
         (define v (hash-ref i 'v #f))
         (valued (kind-of-type t) (if (string? v) v ""))]
        [(member t quantity-types)
         (define (leaf name) (for/first ([l (in-list (hash-ref i 'leaves))] #:when (equal? (car l) name)) (caddr l)))
         (quantity-item (or (leaf "value") "") (or (leaf "code") (leaf "unit") "1"))]
        [else
         (list "complex"
               (sort (for/list ([l (in-list (hash-ref i 'leaves))] #:unless (dropped-leaf? (car l)))
                       (format "~a=~a" (car l) (if (member (cadr l) (cons "decimal" integer-types)) (number-text (caddr l)) (instant-text (caddr l)))))
                     string<?))]))

;; ---- this engine's answers -----------------------------------------------------------------------
;; json-leaves : jsexpr string -> (listof string)   the primitive leaves of FHIR JSON, each with the
;; element names that lead to it (`_x` is x; a list's entries share its name)
(define (json-leaves j path)
  (cond [(hash? j)
         (append* (for/list ([(k v) (in-hash j)] #:unless (eq? k 'resourceType))
                    (define name (regexp-replace #rx"^_" (symbol->string k) ""))
                    (json-leaves v (if (string=? path "") name (string-append path "." name)))))]
        [(list? j) (append* (for/list ([x (in-list j)]) (json-leaves x path)))]
        [(dropped-leaf? path) '()]
        [(string? j) (list (format "~a=~a" path (instant-text j)))]
        [(boolean? j) (list (format "~a=~a" path (if j "true" "false")))]
        [(real? j) (list (format "~a=~a" path (number-text (number->string j))))]
        [else '()]))

;; temporal-text : string -> string   a date, dateTime or time as FHIR writes it (no `@`, no `T` before a time)
(define (temporal-text s) (regexp-replace #rx"^@T?" s ""))

;; our-item : item -> Item
(define (our-item x)
  (define s (item->system x))
  (cond [(fp-quantity? s) (quantity-item (decimal->string (fp-quantity-value s)) (fp-quantity-unit s))]
        [(fhir? x) (list "complex" (sort (json-leaves (node->jsexpr x) "") string<?))]
        [(typeinfo? x) (list "complex" (sort (list (format "name=~a" (typeinfo-name x)) (format "namespace=~a" (typeinfo-namespace x))) string<?))]
        [else
         (define kind
           (cond [(and (prim-item? x) (item-fhir-type x)) => (lambda (t) (kind-of-type (symbol->string t)))]
                 [else (case (item-system-type x)
                         [(String) "string"] [(Integer Long) "integer"] [(Decimal) "decimal"] [(Boolean) "boolean"]
                         [(Date) "date"] [(DateTime) "dateTime"] [(Time) "time"]
                         [else (format "~a" (item-system-type x))])]))
         (valued kind (cond [(and (prim-item? x) (value-less? x)) ""]
                            [(member kind '("date" "dateTime" "time")) (temporal-text (item->text x))]
                            [else (item->text x)]))]))

;; resource-node : path -> (listof node)   a resource file as the engine's input, read as `raco fhirpath` reads it
(define resource-node
  (let ([cache (make-hash)])
    (lambda (file)
      (hash-ref! cache file
                 (lambda ()
                   (define r (from-json (call-with-input-file file read-fhir-json) #:lenient? #t))
                   (if (ok? r) (list (ok-value r)) #f))))))

;; our-answer : path string -> Answer   this engine, called as `raco fhirpath` calls it
(define (our-answer file expr)
  (with-handlers ([exn:fail? (lambda (_) "error")])
    (define root (or (resource-node file) (error "resource not read")))
    (map our-item (eval-fhirpath (parse-fhirpath expr) root))))

;; ---- files ---------------------------------------------------------------------------------------
(define (pairs-file dir) (build-path dir "pairs.jsonl"))

;; write-pairs! : dir -> natural   the materials, and the pairs one JSON object a line (the file
;; absolute, for the bridge)
(define (write-pairs! dir)
  (write-materials! dir)
  (define ps (all-pairs dir))
  (call-with-output-file (pairs-file dir) #:exists 'truncate
    (lambda (o)
      (for ([p (in-list ps)])
        (write-json (hash-set (pair->jsexpr p) 'file (path->string (simple-form-path (build-path dir (fp-pair-file p))))) o)
        (newline o))))
  (length ps))

;; read-pairs : dir -> (listof Pair)   as written (the file absolute)
(define (read-pairs dir)
  (call-with-input-file (pairs-file dir)
    (lambda (i) (for/list ([l (in-lines i)] #:unless (string=? l "")) (jsexpr->pair (string->jsexpr l))))))

;; write-answers! : path (listof (cons id Answer)) -> void   one {"id", "a"} a line, gzipped
(define (write-answers! file rows)
  (define-values (in out) (make-pipe))
  (define t (thread (lambda () (call-with-output-file file #:exists 'truncate (lambda (o) (gzip-through-ports in o #f 0))))))
  (for ([r (in-list rows)])
    (write-json (hasheq 'id (car r) 'a (cdr r)) out)
    (newline out))
  (close-output-port out)
  (thread-wait t))

;; read-answers : path -> Answers
(define (read-answers file)
  (define-values (in out) (make-pipe))
  (define t (thread (lambda () (call-with-input-file file (lambda (i) (gunzip-through-ports i out))) (close-output-port out))))
  (begin0
    (for/hash ([l (in-lines in)] #:unless (string=? l ""))
      (define j (string->jsexpr l))
      (values (hash-ref j 'id) (hash-ref j 'a)))
    (thread-wait t)))

;; ask-reference! : dir jar -> void   the bridge compiled and run over the pairs
(define (ask-reference! dir jar)
  (define classes (build-path dir "classes"))
  (make-directory* classes)
  (define javac (find-executable-path "javac"))
  (define java (find-executable-path "java"))
  (unless (and javac java) (raise-user-error 'fhirpath-reference "java and javac are needed to ask the reference"))
  (putenv "JAVA_TOOL_OPTIONS" "")
  (unless (system* javac "-proc:none" "-cp" jar "-d" (path->string classes) (path->string bridge))
    (raise-user-error 'fhirpath-reference "the bridge did not compile"))
  (unless (system* java "-Xmx6g" "-cp" (format "~a:~a" jar (path->string classes)) "FhirPathReference"
                   (path->string (pairs-file dir)) (path->string (build-path dir "answers.jsonl")))
    (raise-user-error 'fhirpath-reference "the bridge failed")))

;; keep-reference! : dir path -> void   the bridge's answers in the compared form
(define (keep-reference! dir file)
  (write-answers! file
                  (call-with-input-file (build-path dir "answers.jsonl")
                    (lambda (i) (for/list ([l (in-lines i)] #:unless (string=? l ""))
                                  (define j (string->jsexpr l))
                                  (cons (hash-ref j 'id) (normal-reference j))))))
  ;; and why it raised, where it did: a class of disagreement may be told by the message
  (call-with-output-file (errors-file file) #:exists 'truncate
    (lambda (o)
      (write-json (call-with-input-file (build-path dir "answers.jsonl")
                    (lambda (i) (for*/hasheq ([l (in-lines i)] #:unless (string=? l "")
                                              [j (in-value (string->jsexpr l))] #:when (hash-ref j 'error #f))
                                  (values (string->symbol (hash-ref j 'id)) (stable-message (hash-ref j 'error))))))
                  o))))

;; errors-file : path -> path   beside the reference's answers, the messages of its errors
(define (errors-file file) (path-replace-extension (path-replace-extension file #"") #"-errors.json"))
;; stable-message : string -> string   a message without where in the expression it arose
(define (stable-message m)
  (regexp-replace* #px" ?\\(@char [0-9]+\\)|@[0-9]+, [0-9]+:? ?" m ""))
;; read-errors : path -> (hash id string)
(define (read-errors file)
  (define f (errors-file file))
  (if (file-exists? f)
      (for/hash ([(k v) (in-hash (call-with-input-file f read-json))]) (values (symbol->string k) v))
      (hash)))

;; keep-ours! : dir path -> void   this engine over every pair
(define (keep-ours! dir file)
  (define ps (read-pairs dir))
  (write-answers! file
                  (for/list ([p (in-list ps)] [n (in-naturals 1)])
                    (when (zero? (modulo n 50000)) (eprintf "~a pairs\n" n))
                    (cons (fp-pair-id p) (our-answer (fp-pair-file p) (fp-pair-expr p))))))

;; ---- the comparison ------------------------------------------------------------------------------
;; A Row is (list Pair reference-answer our-answer message): the message of the reference's error, or "".
;; agreement-rows : (listof Pair) Answers Answers [(hash id string)] -> (listof Row)
(define (agreement-rows ps ref ours [errors (hash)])
  (for/list ([p (in-list ps)])
    (list p (hash-ref ref (fp-pair-id p) 'missing) (hash-ref ours (fp-pair-id p) 'missing) (hash-ref errors (fp-pair-id p) ""))))
(define (agree? r) (equal? (cadr r) (caddr r)))

(define (percent a n) (if (zero? n) "-" (format "~a%" (/ (round (* 1000.0 (/ a n))) 10.0))))

;; print-agreement : string (listof Row) -> void   by group, sample and held out
(define (print-agreement title rows)
  (printf "~a\n" title)
  (printf "  ~a ~a ~a ~a\n" (pad "group" 10) (pad "part" 9) (pad "pairs" 8) "agree")
  (for* ([g '(search invariant probe changed suite)]
         [part '(sample held-out)])
    (define mine (filter (lambda (r) (and (eq? (fp-pair-group (car r)) g) (eq? (fp-pair-sample? (car r)) (eq? part 'sample)))) rows))
    (unless (null? mine)
      (printf "  ~a ~a ~a ~a (~a)\n" (pad g 10) (pad part 9) (pad (length mine) 8) (count agree? mine) (percent (count agree? mine) (length mine)))))
  (for ([part '(sample held-out)])
    (define mine (filter (lambda (r) (and (not (eq? (fp-pair-group (car r)) 'suite)) (eq? (fp-pair-sample? (car r)) (eq? part 'sample)))) rows))
    (printf "  ~a ~a ~a ~a (~a)\n" (pad "all but the suite" 10) (pad part 9) (pad (length mine) 8) (count agree? mine) (percent (count agree? mine) (length mine)))))
(define (pad v n) (let ([s (format "~a" v)]) (string-append s (make-string (max 0 (- n (string-length s))) #\space))))

;; ---- the classes of disagreement -----------------------------------------------------------------
;; A Class is (list name head rule): head 'ours | 'reference | 'open; rule : Row -> boolean, read
;; from the sample's disagreements alone. The first class whose rule holds is the row's.
(define (expr-of r) (fp-pair-expr (car r)))
(define (said r rx) (regexp-match? rx (cadddr r)))
(define (one kind a) (and (pair? a) (null? (cdr a)) (equal? (car (car a)) kind) (cadr (car a))))
;; with-offsets : Answer -> Answer   every Z at the end of a UTC time written +00:00, in any text
(define (with-offsets a)
  (if (string? a) a
      (for/list ([i (in-list a)])
        (list (car i) (if (string? (cadr i)) (regexp-replace* #px"(?i:(T[0-9:.]+)Z)" (cadr i) "\\1+00:00") (cadr i))))))

(define classes
  (list
   (list "resolve(): the reference, run as its command line runs it, raises" 'reference
         (lambda (r) (and (equal? (cadr r) "error") (said r #rx"Parent not set"))))
   (list "toDate(): the reference does not know the function" 'reference
         (lambda (r) (and (equal? (cadr r) "error") (said r #rx"toDate is not a known function"))))
   (list "toTime(): the reference does not implement it" 'reference
         (lambda (r) (and (equal? (cadr r) "error") (said r #rx"toTime is not implemented"))))
   (list "hasExtension(): no function of the specification; this engine has it, the reference does not" 'open
         (lambda (r) (and (equal? (cadr r) "error") (said r #rx"hasExtension is not a known function"))))
   (list "single() of nothing: the reference raises" 'reference
         (lambda (r) (and (equal? (cadr r) "error") (said r #rx"single can only be used on a singleton value but found 0") (null? (caddr r)))))
   (list "convertsTo…() of nothing: the reference answers false" 'reference
         (lambda (r) (and (regexp-match? #rx"[.]convertsTo[A-Za-z]+\\(\\)$" (expr-of r)) (equal? (one "boolean" (cadr r)) "false") (null? (caddr r)))))
   (list "convertsToString() of a complex value: the reference answers true" 'reference
         (lambda (r) (and (regexp-match? #rx"[.]convertsToString\\(\\)$" (expr-of r)) (equal? (one "boolean" (cadr r)) "true") (equal? (one "boolean" (caddr r)) "false"))))
   (list "division: the reference keeps too few digits" 'reference
         (lambda (r) (and (regexp-match? #rx" / 3\\)[.]round\\(2\\)$" (expr-of r)) (one "decimal" (cadr r)) (one "decimal" (caddr r)))))
   (list "type().name of a FHIR primitive: the reference capitalises it" 'reference
         (lambda (r) (and (regexp-match? #rx"[.]type\\(\\)[.]name$" (expr-of r)) (one "string" (cadr r)) (one "string" (caddr r))
                          (string-ci=? (one "string" (cadr r)) (one "string" (caddr r))))))
   (list "type().name of a nested element: this engine answered its own name for the type" 'ours
         (lambda (r) (and (regexp-match? #rx"[.]type\\(\\)[.]name$" (expr-of r)) (member (one "string" (cadr r)) '("BackboneElement" "Element"))
                          (one "string" (caddr r)))))
   ;; ---- read in the second pass, from part 1's held-out pairs once they were opened ----
   (list "a path rooted at another type than the resource's: an error here, as HL7's suite requires; nothing there" 'reference
         (lambda (r) (and (equal? (caddr r) "error") (not (equal? (cadr r) "error"))
                          (let ([m (regexp-match #px"^[(]*([A-Z][A-Za-z]+)[.]" (fp-pair-base (car r)))])
                            (and m (not (regexp-match? #rx"[|]" (fp-pair-base (car r))))
                                 (not (member (cadr m) (list (fp-pair-type (car r)) "Resource" "DomainResource"))))))))
   (list "a step named div without backticks (this harness's own joining of an invariant's path): a syntax error here, read there" 'open
         (lambda (r) (and (equal? (caddr r) "error") (not (equal? (cadr r) "error")) (regexp-match? #rx"[.]div[.]select[(]" (expr-of r)))))
   (list "as() of several items (FHIR's own dom-3 calls it so): an error here, as HL7's suite requires; an answer there" 'open
         (lambda (r) (and (equal? (caddr r) "error") (not (equal? (cadr r) "error"))
                          (regexp-match? #rx"[.]as[(]" (expr-of r)) (not (regexp-match? #rx"[tT]oString[(][)]" (expr-of r))))))
   (list "toInteger(), toDecimal() … of a value read from the resource: the reference answers nothing" 'reference
         (lambda (r) (and (regexp-match? #rx"[.]to(Integer|Decimal|Boolean|Quantity|DateTime)[(][)]$" (expr-of r)) (null? (cadr r))
                          (pair? (caddr r)) (null? (cdr (caddr r))))))
   (list "convertsToInteger() … of a value read from the resource that converts: the reference answers false" 'reference
         (lambda (r) (and (regexp-match? #rx"[.]convertsTo(Integer|Decimal|Boolean|Quantity|Date|DateTime|Time)[(][)]$" (expr-of r))
                          (equal? (one "boolean" (cadr r)) "false") (equal? (one "boolean" (caddr r)) "true"))))
   (list "hasValue() of several items: this engine answered for the first" 'ours
         (lambda (r) (and (regexp-match? #rx"[.]hasValue[(][)]$" (expr-of r)) (not (regexp-match? #rx"[.]first[(][)][.]hasValue[(][)]$" (expr-of r)))
                          (equal? (one "boolean" (cadr r)) "false") (equal? (one "boolean" (caddr r)) "true"))))
   (list "hasValue() of a value that is no FHIR primitive (Resource.id, a computed Boolean): false here, true there" 'open
         (lambda (r) (and (regexp-match? #rx"[.]hasValue[(][)]$" (expr-of r))
                          (equal? (one "boolean" (cadr r)) "true") (equal? (one "boolean" (caddr r)) "false"))))
   (list "Resource.id: a System.String here, as its definition says; an id there" 'open
         (lambda (r) (and (regexp-match? #rx"(^|[.])id$" (fp-pair-base (car r)))
                          (or (and (regexp-match? #rx"[.]type[(][)][.]name$" (expr-of r)) (equal? (one "string" (cadr r)) "Id") (equal? (one "string" (caddr r)) "String"))
                              (and (regexp-match? #rx" is string$" (expr-of r)) (equal? (one "boolean" (cadr r)) "true") (equal? (one "boolean" (caddr r)) "false"))))))
   (list "toString() of a complex value: this engine raised" 'ours
         (lambda (r) (and (regexp-match? #rx"[tT]oString\\(\\)" (expr-of r)) (equal? (caddr r) "error") (not (equal? (cadr r) "error")))))
   (list "children(): this engine's order was a hash walk's" 'ours
         (lambda (r) (and (regexp-match? #rx"[.]children\\(\\)[.]first\\(\\)$" (expr-of r)) (pair? (cadr r)) (pair? (caddr r)))))
   (list "comparing values no order is defined for: an error here, nothing there" 'open
         (lambda (r) (and (regexp-match? #rx" (<|>=) " (expr-of r)) (null? (cadr r)) (equal? (caddr r) "error"))))
   (list "a UTC dateTime as text: Z here, +00:00 there" 'open
         (lambda (r) (and (regexp-match? #rx"toString\\(\\)" (expr-of r)) (pair? (cadr r)) (pair? (caddr r))
                          (or (equal? (cadr r) (with-offsets (caddr r)))
                              (and (regexp-match? #rx"[.](length\\(\\)|toChars\\(\\)[.]count\\(\\))$" (expr-of r))
                                   (equal? (one "integer" (cadr r)) "25") (equal? (one "integer" (caddr r)) "20"))))))))

;; class-of : Row -> string
(define (class-of r)
  (or (for/first ([c (in-list classes)] #:when ((caddr c) r)) (car c)) "unclassified"))

;; shape : Answer -> string   an answer in a word, for sorting what is read
(define (shape a)
  (cond [(equal? a "error") "error"]
        [(null? a) "empty"]
        [else (string-join (remove-duplicates (map car a)) "+")]))

(define (show a)
  (define s (if (string? a) a (jsexpr->string a)))
  (if (> (string-length s) 300) (string-append (substring s 0 300) "…") s))

;; template-of : Pair -> string   the continuation a probe was made with ("" for the other groups)
(define (template-of p)
  (or (and (eq? (fp-pair-group p) 'probe)
           (for/first ([t (in-list continuations)] #:when (equal? (continued t (fp-pair-base p)) (fp-pair-expr p))) t))
      ""))

;; our-error : Pair -> string   this engine's message for a pair it raised on
(define (our-error p)
  (with-handlers ([exn:fail? (lambda (e) (car (string-split (exn-message e) "\n")))])
    (eval-fhirpath (parse-fhirpath (fp-pair-expr p)) (or (resource-node (fp-pair-file p)) (error "resource not read")))
    "(no error)"))

(define (short s n) (if (> (string-length s) n) (string-append (substring s 0 n) "…") s))

;; print-sample : dir (listof Row) (or/c string #f) -> void   the sample's disagreements: counted by
;; class, group, continuation and the shapes of the two answers, with the first few of each
(define (print-sample dir rows only [all? #f])
  (define wrong (filter (lambda (r) (and (or all? (fp-pair-sample? (car r))) (not (agree? r)))) rows))
  (define groups (group-by (lambda (r) (list (class-of r) (fp-pair-group (car r)) (template-of (car r)) (shape (cadr r)) (shape (caddr r)))) wrong))
  (for ([g (in-list (sort groups > #:key length))]
        #:when (or (not only) (equal? only (class-of (car g)))))
    (define r0 (car g))
    (printf "\n~a pairs [~a] ~a ~a — the reference: ~a; ours: ~a\n" (length g) (class-of r0) (fp-pair-group (car r0)) (template-of (car r0)) (shape (cadr r0)) (shape (caddr r0)))
    (define by-expr (group-by (lambda (r) (fp-pair-expr (car r))) g))
    (for ([e (in-list (take by-expr (min 3 (length by-expr))))])
      (define r (car e))
      (printf "  ~a ~a  (~a)\n    reference: ~a\n    ours:      ~a\n"
              (fp-pair-type (car r)) (short (fp-pair-expr (car r)) 150) (file-name (fp-pair-file (car r)))
              (if (equal? (cadr r) "error") (short (string-append "error: " (cadddr r)) 200) (short (show (cadr r)) 200))
              (if (equal? (caddr r) "error") (short (our-error (car r)) 200) (short (show (caddr r)) 200))))))
(define (file-name f) (let-values ([(_b n _d) (split-path f)]) (path->string n)))

;; print-suite : (listof Row) -> void   HL7's own suite: every expression on which the two engines differ
(define (print-suite rows)
  (define mine (filter (lambda (r) (eq? (fp-pair-group (car r)) 'suite)) rows))
  (define wrong (filter (lambda (r) (not (agree? r))) mine))
  (printf "HL7's FHIRPath suite for R4, ~a expressions over its own resources: the two engines differ on ~a\n" (length mine) (length wrong))
  (for ([r (in-list wrong)])
    (printf "  ~a\n    reference: ~a\n    ours:      ~a\n" (short (fp-pair-expr (car r)) 110)
            (if (equal? (cadr r) "error") (short (string-append "error: " (cadddr r)) 150) (short (show (cadr r)) 150))
            (if (equal? (caddr r) "error") (short (string-append "error: " (our-error (car r))) 150) (short (show (caddr r)) 150)))))

;; print-classes : (listof Row) -> void   every disagreement by class: sample, held out
(define (print-classes rows [held-out-note " (unread)"])
  (define wrong (filter (lambda (r) (and (not (agree? r)) (not (eq? (fp-pair-group (car r)) 'suite)))) rows))
  (define names (append (map car classes) '("unclassified")))
  (printf "~a ~a ~a ~a\n" (pad "class" 92) (pad "head" 10) (pad "sample" 8) "held out")
  (for ([n (in-list names)])
    (define mine (filter (lambda (r) (equal? (class-of r) n)) wrong))
    (define head (cond [(assoc n classes) => cadr] [else '-]))
    (printf "~a ~a ~a ~a\n" (pad n 92) (pad head 10) (pad (count (lambda (r) (fp-pair-sample? (car r))) mine) 8)
            (count (lambda (r) (not (fp-pair-sample? (car r)))) mine)))
  ;; by head, and what the agreement is when the reference's own departures are set aside
  (define (head-of r) (cond [(assoc (class-of r) classes) => cadr] [else 'unread]))
  (newline)
  (for ([part '(sample held-out all)])
    (define sample? (eq? part 'sample))
    (define (in-part? r) (or (eq? part 'all) (eq? (fp-pair-sample? (car r)) sample?)))
    (define all (filter (lambda (r) (and (not (eq? (fp-pair-group (car r)) 'suite)) (in-part? r))) rows))
    (define mine (filter in-part? wrong))
    (define (n head) (count (lambda (r) (eq? (head-of r) head)) mine))
    (printf "~a: ~a pairs, ~a differ — the reference's departure ~a, this engine's ~a, open ~a, in no class ~a~a\n"
            part (length all) (length mine) (n 'reference) (n 'ours) (n 'open) (n 'unread) (if (eq? part 'held-out) held-out-note ""))
    (printf "  the same answer, or a difference that is the reference's departure: ~a of ~a (~a)\n"
            (+ (- (length all) (length mine)) (n 'reference)) (length all)
            (percent (+ (- (length all) (length mine)) (n 'reference)) (length all)))))

(module+ main
  (define args (vector->list (current-command-line-arguments)))
  (define (rows-of dir ref ours) (agreement-rows (read-pairs dir) (read-answers ref) (read-answers ours) (read-errors ref)))
  (cond
    [(and (= (length args) 2) (equal? (car args) "pairs"))
     (printf "~a pairs\n" (write-pairs! (cadr args)))]
    ;; the second pass's fresh set: another guide's examples under the same rules, no changed copies, no suite
    [(and (= (length args) 3) (equal? (car args) "fresh-pairs"))
     (parameterize ([current-guide (fresh-guide (caddr args))] [current-fresh? #t])
       (printf "~a pairs\n" (write-pairs! (cadr args))))]
    [(and (= (length args) 3) (equal? (car args) "ask")) (ask-reference! (cadr args) (caddr args))]
    [(and (= (length args) 3) (equal? (car args) "keep")) (keep-reference! (cadr args) (caddr args))]
    [(and (= (length args) 3) (equal? (car args) "ours")) (keep-ours! (cadr args) (caddr args))]
    [(and (>= (length args) 4) (equal? (car args) "report"))
     (print-agreement "this engine's answer is the reference's:" (rows-of (cadr args) (caddr args) (cadddr args)))
     (when (= (length args) 5)
       (newline)
       (print-agreement "after:" (rows-of (cadr args) (caddr args) (list-ref args 4))))]
    [(and (>= (length args) 4) (equal? (car args) "read"))
     (print-sample (cadr args) (rows-of (cadr args) (caddr args) (cadddr args)) (and (= (length args) 5) (list-ref args 4)))]
    ;; the second pass (PROTOCOL.md): part 1's held-out pairs, opened
    [(and (>= (length args) 4) (equal? (car args) "read-opened"))
     (print-sample (cadr args) (rows-of (cadr args) (caddr args) (cadddr args)) (and (= (length args) 5) (list-ref args 4)) #t)]
    [(and (= (length args) 4) (equal? (car args) "suite"))
     (print-suite (rows-of (cadr args) (caddr args) (cadddr args)))]
    [(and (= (length args) 4) (equal? (car args) "classes"))
     (print-classes (rows-of (cadr args) (caddr args) (cadddr args)))]
    ;; the same once part 1's held-out pairs have been opened, or for a set none of which is read
    [(and (= (length args) 5) (equal? (car args) "classes") (member (list-ref args 4) '("opened" "fresh")))
     (print-classes (rows-of (cadr args) (caddr args) (cadddr args))
                    (if (equal? (list-ref args 4) "opened") " (read in the second pass)" " (no pair of this set is read)"))]
    [else (eprintf "usage: fhirpath-reference.rkt pairs DIR | ask DIR JAR | keep DIR FILE | ours DIR FILE | report DIR REF OURS [AFTER] | read DIR REF OURS [CLASS] | classes DIR REF OURS\n")
          (exit 2)]))

;; live-rows : dir path -> (listof Row)   the pairs made afresh under dir, this engine run over them
;; now, beside the reference's kept answers
(define (live-rows dir reference)
  (write-materials! dir)
  (define ps (all-pairs dir))
  (define ref (read-answers reference))
  (define errors (read-errors reference))
  (for/list ([p (in-list ps)])
    (list p (hash-ref ref (fp-pair-id p) 'missing)
          (our-answer (path->string (build-path dir (fp-pair-file p))) (fp-pair-expr p))
          (hash-ref errors (fp-pair-id p) ""))))

(module+ test
  (require rackunit)
  ;; the engine as it is now, held to the reference's kept answers: the agreement of the write-up
  ;; as floors, and no disagreement of the sample outside the classes read from it
  (let ([dir (make-temporary-file "fhirpath-reference-~a" 'directory)])
    (dynamic-wind
     void
     (lambda ()
       (define rows (live-rows dir kept-reference))
       (define (part group sample?) (filter (lambda (r) (and (eq? (fp-pair-group (car r)) group) (eq? (fp-pair-sample? (car r)) sample?))) rows))
       (check-equal? (length rows) 172527)
       (check-false (ormap (lambda (r) (eq? (cadr r) 'missing)) rows))
       (for ([floor (in-list '((search #t 926) (search #f 5909) (invariant #t 417) (invariant #f 2684)
                               (probe #t 19141) (probe #f 109342) (changed #t 2363) (changed #f 11629) (suite #t 833)))])
         (check-true (>= (count agree? (part (car floor) (cadr floor))) (caddr floor)) (format "~a" floor)))
       (check-equal? (count (lambda (r) (and (fp-pair-sample? (car r)) (not (eq? (fp-pair-group (car r)) 'suite))
                                             (not (agree? r)) (equal? (class-of r) "unclassified")))
                            rows)
                     0)
       ;; nothing of the sample is still this engine's
       (check-equal? (count (lambda (r) (and (fp-pair-sample? (car r)) (not (agree? r))
                                             (eq? 'ours (cond [(assoc (class-of r) classes) => cadr] [else #f]))))
                            rows)
                     0))
     (lambda () (delete-directory/files dir))))
  ;; the second pass's fresh sets (IPS, mCODE): how many pairs agree, how many differ under no
  ;; class, and none under a class that is this engine's
  (for ([fresh (in-list (list (list "ips" kept-ips 61298 54846 66) (list "mcode" kept-mcode 81190 72949 0)))])
    (define dir (make-temporary-file "fhirpath-fresh-~a" 'directory))
    (dynamic-wind
     void
     (lambda ()
       (define rows (parameterize ([current-guide (fresh-guide (car fresh))] [current-fresh? #t]) (live-rows dir (cadr fresh))))
       (check-equal? (length rows) (caddr fresh))
       (check-true (>= (count agree? rows) (cadddr fresh)) (car fresh))
       (check-true (<= (count (lambda (r) (and (not (agree? r)) (equal? (class-of r) "unclassified"))) rows) (list-ref fresh 4)) (car fresh))
       (check-equal? (count (lambda (r) (and (not (agree? r)) (eq? 'ours (cond [(assoc (class-of r) classes) => cadr] [else #f])))) rows) 0))
     (lambda () (delete-directory/files dir))))
  (check-equal? (number-text "1.0") "1")
  (check-equal? (number-text "0.10") "1/10")
  (check-equal? (number-text "abc") "abc")
  (check-equal? (normal-reference (hasheq 'id "1" 'error "x")) "error")
  (check-equal? (normal-reference (hasheq 'id "1" 'items (list (hasheq 't "code" 'v "final") (hasheq 't "decimal" 'v "1.50"))))
                '(("string" "final") ("decimal" "3/2")))
  (check-equal? (normal-reference (hasheq 'id "1" 'items (list (hasheq 't "HumanName" 'element #t 'leaves '(("given" "string" "Ann") ("family" "string" "Ng"))))))
                '(("complex" ("family=Ng" "given=Ann"))))
  (check-equal? (normal-reference (hasheq 'id "1" 'items (list (hasheq 't "Quantity" 'element #f 'leaves '(("value" "decimal" "5.0") ("code" "code" "mg"))))))
                '(("quantity" "5 mg")))
  (check-equal? (sort (json-leaves (hasheq 'family "Ng" '_family (hasheq 'extension (list (hasheq 'url "u" 'valueInteger 2))) 'given '("Ann" "Bea")) "") string<?)
                '("family.extension.url=u" "family.extension.valueInteger=2" "family=Ng" "given=Ann" "given=Bea")))
