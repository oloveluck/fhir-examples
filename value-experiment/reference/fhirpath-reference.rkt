#lang racket/base

;;; fhirpath-reference.rkt — this toolkit's FHIRPath engine beside HL7's Java engine
;;; (value-experiment/PROTOCOL.md, H part 1). Everything that decides a result is here: each
;;; engine's answer brought to one form, the comparison, the classes, the report.
;;;
;;;   racket fhirpath-reference.rkt pairs DIR            the materials and DIR/pairs.jsonl
;;;   racket fhirpath-reference.rkt ask DIR JAR          HL7's engine over them (the Java bridge): DIR/answers.jsonl
;;;   racket fhirpath-reference.rkt keep DIR FILE.gz     the reference's answers, in the compared form
;;;   racket fhirpath-reference.rkt ours DIR FILE.gz     this engine's answers, in the compared form
;;;   racket fhirpath-reference.rkt report DIR REF.gz OURS.gz [OURS-AFTER.gz]
;;;   racket fhirpath-reference.rkt read DIR REF.gz OURS.gz [CLASS]   the SAMPLE's disagreements, by class
;;;   racket fhirpath-reference.rkt classes DIR REF.gz OURS.gz        every disagreement counted by class
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

(provide normal-reference our-answer read-answers agreement-rows classes class-of)

(define-runtime-path bridge "FhirPathReference.java")

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

;; valued : kind string -> Item   a primitive item; numbers by value
(define (valued kind v)
  (list kind (if (member kind '("integer" "decimal")) (number-text v) v)))

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
                       (format "~a=~a" (car l) (if (member (cadr l) (cons "decimal" integer-types)) (number-text (caddr l)) (caddr l))))
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
        [(string? j) (list (format "~a=~a" path j))]
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
        (write-json (hash-set (pair->jsexpr p) 'file (path->string (simple-form-path (build-path dir (pair-file p))))) o)
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
                                  (cons (hash-ref j 'id) (normal-reference j)))))))

;; keep-ours! : dir path -> void   this engine over every pair
(define (keep-ours! dir file)
  (define ps (read-pairs dir))
  (write-answers! file
                  (for/list ([p (in-list ps)] [n (in-naturals 1)])
                    (when (zero? (modulo n 50000)) (eprintf "~a pairs\n" n))
                    (cons (pair-id p) (our-answer (pair-file p) (pair-expr p))))))

;; ---- the comparison ------------------------------------------------------------------------------
;; A Row is (list Pair reference-answer our-answer).
;; agreement-rows : (listof Pair) Answers Answers -> (listof Row)
(define (agreement-rows ps ref ours)
  (for/list ([p (in-list ps)])
    (list p (hash-ref ref (pair-id p) 'missing) (hash-ref ours (pair-id p) 'missing))))
(define (agree? r) (equal? (cadr r) (caddr r)))

(define (percent a n) (if (zero? n) "-" (format "~a%" (/ (round (* 1000.0 (/ a n))) 10.0))))

;; print-agreement : string (listof Row) -> void   by group, sample and held out
(define (print-agreement title rows)
  (printf "~a\n" title)
  (printf "  ~a ~a ~a ~a\n" (pad "group" 10) (pad "part" 9) (pad "pairs" 8) "agree")
  (for* ([g '(search invariant probe changed suite)]
         [part '(sample held-out)])
    (define mine (filter (lambda (r) (and (eq? (pair-group (car r)) g) (eq? (pair-sample? (car r)) (eq? part 'sample)))) rows))
    (unless (null? mine)
      (printf "  ~a ~a ~a ~a (~a)\n" (pad g 10) (pad part 9) (pad (length mine) 8) (count agree? mine) (percent (count agree? mine) (length mine)))))
  (for ([part '(sample held-out)])
    (define mine (filter (lambda (r) (and (not (eq? (pair-group (car r)) 'suite)) (eq? (pair-sample? (car r)) (eq? part 'sample)))) rows))
    (printf "  ~a ~a ~a ~a (~a)\n" (pad "all but the suite" 10) (pad part 9) (pad (length mine) 8) (count agree? mine) (percent (count agree? mine) (length mine)))))
(define (pad v n) (let ([s (format "~a" v)]) (string-append s (make-string (max 0 (- n (string-length s))) #\space))))

;; ---- the classes of disagreement -----------------------------------------------------------------
;; A Class is (list name head rule): head 'ours | 'reference | 'open; rule : Row -> boolean, read
;; from the sample's disagreements alone. The first class whose rule holds is the row's.
(define classes
  (list))

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

;; print-sample : (listof Row) (or/c string #f) -> void   the sample's disagreements: counted by
;; class and by the shapes of the two answers, with the first few of each
(define (print-sample rows only)
  (define wrong (filter (lambda (r) (and (pair-sample? (car r)) (not (agree? r)))) rows))
  (define groups (group-by (lambda (r) (list (class-of r) (shape (cadr r)) (shape (caddr r)))) wrong))
  (for ([g (in-list (sort groups > #:key length))]
        #:when (or (not only) (equal? only (class-of (car g)))))
    (define r0 (car g))
    (printf "\n~a pairs — class ~a — the reference: ~a; ours: ~a\n" (length g) (class-of r0) (shape (cadr r0)) (shape (caddr r0)))
    (define by-expr (group-by (lambda (r) (pair-expr (car r))) g))
    (printf "  (~a expressions)\n" (length by-expr))
    (for ([e (in-list (take by-expr (min 6 (length by-expr))))])
      (define r (car e))
      (printf "  [~a ~a] ~a\n    over ~a\n    reference: ~a\n    ours:      ~a\n"
              (pair-group (car r)) (pair-type (car r)) (pair-expr (car r)) (file-name (pair-file (car r))) (show (cadr r)) (show (caddr r))))))
(define (file-name f) (let-values ([(_b n _d) (split-path f)]) (path->string n)))

;; print-classes : (listof Row) -> void   every disagreement by class: sample, held out
(define (print-classes rows)
  (define wrong (filter (lambda (r) (and (not (agree? r)) (not (eq? (pair-group (car r)) 'suite)))) rows))
  (define names (append (map car classes) '("unclassified")))
  (printf "~a ~a ~a ~a\n" (pad "class" 44) (pad "head" 10) (pad "sample" 8) "held out")
  (for ([n (in-list names)])
    (define mine (filter (lambda (r) (equal? (class-of r) n)) wrong))
    (define head (cond [(assoc n classes) => cadr] [else '-]))
    (printf "~a ~a ~a ~a\n" (pad n 44) (pad head 10) (pad (count (lambda (r) (pair-sample? (car r))) mine) 8)
            (count (lambda (r) (not (pair-sample? (car r)))) mine))))

(module+ main
  (define args (vector->list (current-command-line-arguments)))
  (define (rows-of dir ref ours) (agreement-rows (read-pairs dir) (read-answers ref) (read-answers ours)))
  (cond
    [(and (= (length args) 2) (equal? (car args) "pairs"))
     (printf "~a pairs\n" (write-pairs! (cadr args)))]
    [(and (= (length args) 3) (equal? (car args) "ask")) (ask-reference! (cadr args) (caddr args))]
    [(and (= (length args) 3) (equal? (car args) "keep")) (keep-reference! (cadr args) (caddr args))]
    [(and (= (length args) 3) (equal? (car args) "ours")) (keep-ours! (cadr args) (caddr args))]
    [(and (>= (length args) 4) (equal? (car args) "report"))
     (print-agreement "this engine's answer is the reference's:" (rows-of (cadr args) (caddr args) (cadddr args)))
     (when (= (length args) 5)
       (newline)
       (print-agreement "after:" (rows-of (cadr args) (caddr args) (list-ref args 4))))]
    [(and (>= (length args) 4) (equal? (car args) "read"))
     (print-sample (rows-of (cadr args) (caddr args) (cadddr args)) (and (= (length args) 5) (list-ref args 4)))]
    [(and (= (length args) 4) (equal? (car args) "classes"))
     (print-classes (rows-of (cadr args) (caddr args) (cadddr args)))]
    [else (eprintf "usage: fhirpath-reference.rkt pairs DIR | ask DIR JAR | keep DIR FILE | ours DIR FILE | report DIR REF OURS [AFTER] | read DIR REF OURS [CLASS] | classes DIR REF OURS\n")
          (exit 2)]))

(module+ test
  (require rackunit)
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
