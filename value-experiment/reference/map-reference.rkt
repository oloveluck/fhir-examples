#lang racket/base

;;; map-reference.rkt — this toolkit's mapping engine beside the validator's StructureMap engine
;;; (value-experiment/PROTOCOL.md, H part 2). Everything that decides a result is here.
;;;
;;;   racket map-reference.rkt pairs DIR            the materials and DIR/pairs.jsonl
;;;   racket map-reference.rkt ask DIR JAR          the reference over them (the Java bridge): DIR/answers.jsonl
;;;   racket map-reference.rkt keep DIR FILE.gz     the reference's answers, in the compared form
;;;   racket map-reference.rkt ours DIR FILE.gz     this engine's answers, in the compared form
;;;   racket map-reference.rkt report DIR REF.gz OURS.gz [OURS-AFTER.gz]
;;;   racket map-reference.rkt read DIR REF.gz OURS.gz [CLASS]     the SAMPLE's disagreements
;;;   racket map-reference.rkt classes DIR REF.gz OURS.gz          every disagreement counted by class
;;;
;;; An Answer is "error" (the engine raised, or did not read the map) or the result as JSON text
;;; with its keys in order of name and its numbers by value. Answers is (hash id Answer).

(require racket/file racket/list racket/string racket/port racket/system racket/runtime-path racket/path json file/gzip file/gunzip
         (only-in fhir/r5/schemas)
         (only-in fhir/data-source current-data-source resources->data-source)
         (only-in fhir/serialize/from-json from-json)
         (only-in fhir/result/result ok? ok-value)
         (only-in fml/parser/parse parse-fml)
         (only-in fml/transform run-map uses-types)
         "map-cases.rkt")

(provide canonical our-map-answer read-answers read-errors map-rows classes class-of)

(define-runtime-path bridge "MapReference.java")
(define-runtime-path kept-reference "answers/map-reference.jsonl.gz")

;; ---- the compared form ---------------------------------------------------------------------------
;; canonical : jsexpr -> string   JSON with an object's keys in order of name and numbers by value
(define (canonical j)
  (cond [(hash? j) (string-append "{" (string-join (for/list ([k (in-list (sort (hash-keys j) symbol<?))])
                                                     (format "~s:~a" (symbol->string k) (canonical (hash-ref j k)))) ",") "}")]
        [(list? j) (string-append "[" (string-join (map canonical j) ",") "]")]
        [(and (real? j) (not (boolean? j)))
         (number->string (or (string->number (number->string j) 10 'number-or-false 'decimal-as-exact) j))]
        [else (jsexpr->string j)]))

;; reference-answer : jsexpr -> Answer   a line of the bridge's output
(define (reference-answer j)
  (cond [(hash-ref j 'error #f) "error"]
        [else (with-handlers ([exn:fail? (lambda (_) "error")]) (canonical (string->jsexpr (hash-ref j 'result))))]))

;; logical-models : dir step -> (listof jsexpr)   the step's logical models, read once
(define logical-models
  (let ([cache (make-hash)])
    (lambda (dir step)
      (hash-ref! cache (cons dir step)
                 (lambda ()
                   (define d (build-path dir step "logical"))
                   (for/list ([f (in-list (sort (directory-list d #:build? #t) string<? #:key path->string))]
                              #:when (regexp-match? #rx"[.]json$" (path->string f)))
                     (call-with-input-file f read-json)))))))

;; run-ours : dir MapPair -> jsexpr   this engine: the map's text parsed, its structures registered,
;; the source read against them, the map run (raises what the engine raises)
(define (run-ours dir p)
  (define parsed (parse-fml (file->string (build-path dir (map-pair-map p)))))
  (unless (ok? parsed) (error "map not read"))
  (define m (ok-value parsed))
  (parameterize ([current-data-source (resources->data-source (logical-models dir (map-pair-step p)))])
    (uses-types m)
    (define src (from-json (call-with-input-file (build-path dir (map-pair-source p)) read-json) #:lenient? #t))
    (unless (ok? src) (error "source not read"))
    (run-map m (ok-value src))))

;; our-map-answer : dir MapPair -> Answer
(define (our-map-answer dir p)
  (with-handlers ([(lambda (e) #t) (lambda (_) "error")]) (canonical (run-ours dir p))))
;; our-error : dir MapPair -> string   this engine's message for a pair it raised on
(define (our-error dir p)
  (with-handlers ([exn:fail? (lambda (e) (car (string-split (exn-message e) "\n")))]) (run-ours dir p) "(no error)"))

;; ---- files ---------------------------------------------------------------------------------------
(define (pairs-file dir) (build-path dir "pairs.jsonl"))
(define (write-pairs! dir)
  (write-map-materials! dir)
  (define ps (all-map-pairs dir))
  (define (abs rel) (path->string (simple-form-path (build-path dir rel))))
  (call-with-output-file (pairs-file dir) #:exists 'truncate
    (lambda (o)
      (for ([p (in-list ps)])
        (write-json (hash-set* (pair->jsexpr p) 'dir (abs (build-path (map-pair-step p) "logical"))
                               'map-file (abs (map-pair-map p)) 'file (abs (map-pair-source p)))
                    o)
        (newline o))))
  (length ps))
(define (read-pairs dir)
  (call-with-input-file (pairs-file dir)
    (lambda (i) (for/list ([l (in-lines i)] #:unless (string=? l "")) (jsexpr->pair (string->jsexpr l))))))

(define (write-answers! file rows)
  (define-values (in out) (make-pipe))
  (define t (thread (lambda () (call-with-output-file file #:exists 'truncate (lambda (o) (gzip-through-ports in o #f 0))))))
  (for ([r (in-list rows)]) (write-json (hasheq 'id (car r) 'a (cdr r)) out) (newline out))
  (close-output-port out)
  (thread-wait t))
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

;; ask-reference! : dir jar -> void   the bridge compiled and run (it reads a pair's map as "map")
(define (ask-reference! dir jar)
  (define classes (build-path dir "classes"))
  (make-directory* classes)
  (putenv "JAVA_TOOL_OPTIONS" "")
  (unless (system* (find-executable-path "javac") "-proc:none" "-cp" jar "-d" (path->string classes) (path->string bridge))
    (raise-user-error 'map-reference "the bridge did not compile"))
  ;; the bridge's own view of a pair: the absolute files
  (call-with-output-file (build-path dir "bridge-pairs.jsonl") #:exists 'truncate
    (lambda (o)
      (call-with-input-file (pairs-file dir)
        (lambda (i) (for ([l (in-lines i)] #:unless (string=? l ""))
                      (define j (string->jsexpr l))
                      (write-json (hasheq 'id (hash-ref j 'id) 'dir (hash-ref j 'dir) 'map (hash-ref j 'map-file)
                                          'url (hash-ref j 'url) 'file (hash-ref j 'file)) o)
                      (newline o))))))
  (unless (system* (find-executable-path "java") "-Xmx6g" "-cp" (format "~a:~a" jar (path->string classes)) "MapReference"
                   (path->string (build-path dir "bridge-pairs.jsonl")) (path->string (build-path dir "answers.jsonl")))
    (raise-user-error 'map-reference "the bridge failed")))

(define (keep-reference! dir file)
  (define lines (call-with-input-file (build-path dir "answers.jsonl")
                  (lambda (i) (for/list ([l (in-lines i)] #:unless (string=? l "")) (string->jsexpr l)))))
  (write-answers! file (for/list ([j (in-list lines)]) (cons (hash-ref j 'id) (reference-answer j))))
  (call-with-output-file (errors-file file) #:exists 'truncate
    (lambda (o) (write-json (for/hasheq ([j (in-list lines)] #:when (hash-ref j 'error #f))
                              (values (string->symbol (hash-ref j 'id)) (hash-ref j 'error)))
                            o))))
(define (keep-ours! dir file)
  (write-answers! file (for/list ([p (in-list (read-pairs dir))]) (cons (map-pair-id p) (our-map-answer dir p)))))

;; ---- the comparison ------------------------------------------------------------------------------
;; A Row is (list MapPair reference-answer our-answer message).
(define (map-rows ps ref ours [errors (hash)])
  (for/list ([p (in-list ps)])
    (list p (hash-ref ref (map-pair-id p) 'missing) (hash-ref ours (map-pair-id p) 'missing) (hash-ref errors (map-pair-id p) ""))))
(define (agree? r) (equal? (cadr r) (caddr r)))
(define (percent a n) (if (zero? n) "-" (format "~a%" (/ (round (* 1000.0 (/ a n))) 10.0))))
(define (pad v n) (let ([s (format "~a" v)]) (string-append s (make-string (max 0 (- n (string-length s))) #\space))))

(define (print-agreement title rows)
  (printf "~a\n  ~a ~a ~a ~a\n" title (pad "group" 15) (pad "part" 9) (pad "pairs" 7) "agree")
  (for* ([g '(published changed-source changed-map all)] [part '(sample held-out)])
    (define mine (filter (lambda (r) (and (or (eq? g 'all) (eq? (map-pair-group (car r)) g)) (eq? (map-pair-sample? (car r)) (eq? part 'sample)))) rows))
    (unless (null? mine)
      (printf "  ~a ~a ~a ~a (~a)\n" (pad g 15) (pad part 9) (pad (length mine) 7) (count agree? mine) (percent (count agree? mine) (length mine)))))
  ;; an agreement may be both engines refusing: how many are
  (printf "  of the ~a pairs that agree, both engines raise on ~a; the reference raises on ~a of the ~a pairs\n"
          (count agree? rows) (count (lambda (r) (and (agree? r) (equal? (cadr r) "error"))) rows)
          (count (lambda (r) (equal? (cadr r) "error")) rows) (length rows)))

;; ---- the classes of disagreement -----------------------------------------------------------------
;; A Class is (list name head rule): head 'ours | 'reference | 'open; rule : Row -> boolean, read from
;; the sample's disagreements alone. The first class whose rule holds is the row's.
(define (change-of r) (map-pair-change (car r)))
(define (said r rx) (regexp-match? rx (cadddr r)))
(define (result? a) (not (equal? a "error")))
(define classes
  (list
   (list "a FHIRPath expression that names a variable with an underscore: the reference does not read the map" 'reference
         (lambda (r) (and (equal? (cadr r) "error") (said r #rx"expecting a token name"))))
   (list "a text that is no number put into a number's element: this engine wrote it as it stood" 'ours
         (lambda (r) (and (equal? (cadr r) "error") (said r #rx"NumberFormatException") (result? (caddr r)))))
   (list "check and the list mode: this engine picked by the list mode first, the reference checks every element" 'ours
         (lambda (r) (and (equal? (cadr r) "error") (said r #rx"Check condition failed") (result? (caddr r)))))
   (list "a target that names a variable, with nothing after it: this engine copied the source value into it" 'ours
         (lambda (r) (and (equal? (change-of r) "rule removed") (result? (cadr r)) (result? (caddr r)))))
   (list "a value that is no integer, put into an integer element and then replaced: an error here, the last value there" 'open
         (lambda (r) (and (eq? (map-pair-group (car r)) 'changed-source) (equal? (change-of r) "source string")
                          (result? (cadr r)) (equal? (caddr r) "error"))))))
(define (class-of r) (or (for/first ([c (in-list classes)] #:when ((caddr c) r)) (car c)) "unclassified"))
(define (head-of r) (cond [(assoc (class-of r) classes) => cadr] [else 'unread]))

(define (short s n) (if (> (string-length s) n) (string-append (substring s 0 n) "…") s))
(define (shape a) (if (equal? a "error") "error" "a result"))

;; print-sample : dir (listof Row) (or/c string #f) boolean -> void   the disagreements (the sample's,
;; unless all?) by class, change and the shapes of the answers, with the first few of each
(define (print-sample dir rows only [all? #f])
  (define wrong (filter (lambda (r) (and (or all? (map-pair-sample? (car r))) (not (agree? r)))) rows))
  (define groups (group-by (lambda (r) (list (class-of r) (map-pair-group (car r)) (change-of r) (shape (cadr r)) (shape (caddr r)))) wrong))
  (for ([g (in-list (sort groups > #:key length))] #:when (or (not only) (equal? only (class-of (car g)))))
    (define r0 (car g))
    (printf "\n~a pairs [~a] ~a ~a — the reference: ~a; ours: ~a\n" (length g) (class-of r0) (map-pair-group (car r0)) (change-of r0) (shape (cadr r0)) (shape (caddr r0)))
    (for ([r (in-list (take g (min 3 (length g))))])
      (printf "  ~a over ~a\n    reference: ~a\n    ours:      ~a\n" (map-pair-map (car r)) (map-pair-source (car r))
              (if (equal? (cadr r) "error") (short (string-append "error: " (cadddr r)) 260) (short (cadr r) 260))
              (if (equal? (caddr r) "error") (short (string-append "error: " (our-error dir (car r))) 260) (short (caddr r) 260))))))

(define (print-classes rows [held-out-note " (unread)"])
  (define wrong (filter (lambda (r) (not (agree? r))) rows))
  (printf "~a ~a ~a ~a\n" (pad "class" 100) (pad "head" 10) (pad "sample" 8) "held out")
  (for ([n (in-list (append (map car classes) '("unclassified")))])
    (define mine (filter (lambda (r) (equal? (class-of r) n)) wrong))
    (printf "~a ~a ~a ~a\n" (pad n 100) (pad (cond [(assoc n classes) => cadr] [else '-]) 10)
            (pad (count (lambda (r) (map-pair-sample? (car r))) mine) 8) (count (lambda (r) (not (map-pair-sample? (car r)))) mine)))
  (newline)
  (for ([part '(sample held-out all)])
    (define (in-part? r) (or (eq? part 'all) (eq? (map-pair-sample? (car r)) (eq? part 'sample))))
    (define all (filter in-part? rows))
    (define mine (filter in-part? wrong))
    (define (n head) (count (lambda (r) (eq? (head-of r) head)) mine))
    (printf "~a: ~a pairs, ~a differ — the reference's departure ~a, this engine's ~a, open ~a, in no class ~a~a\n"
            part (length all) (length mine) (n 'reference) (n 'ours) (n 'open) (n 'unread) (if (eq? part 'held-out) held-out-note ""))
    (printf "  the same answer, or a difference that is the reference's departure: ~a of ~a (~a)\n"
            (+ (- (length all) (length mine)) (n 'reference)) (length all) (percent (+ (- (length all) (length mine)) (n 'reference)) (length all)))))

(module+ main
  (define args (vector->list (current-command-line-arguments)))
  (define (rows-of dir ref ours) (map-rows (read-pairs dir) (read-answers ref) (read-answers ours) (read-errors ref)))
  (cond
    [(and (= (length args) 2) (equal? (car args) "pairs")) (printf "~a pairs\n" (write-pairs! (cadr args)))]
    [(and (= (length args) 3) (equal? (car args) "ask")) (ask-reference! (cadr args) (caddr args))]
    [(and (= (length args) 3) (equal? (car args) "keep")) (keep-reference! (cadr args) (caddr args))]
    [(and (= (length args) 3) (equal? (car args) "ours")) (keep-ours! (cadr args) (caddr args))]
    [(and (>= (length args) 4) (equal? (car args) "report"))
     (print-agreement "this engine's result is the reference's:" (rows-of (cadr args) (caddr args) (cadddr args)))
     (when (= (length args) 5) (newline) (print-agreement "after:" (rows-of (cadr args) (caddr args) (list-ref args 4))))]
    [(and (>= (length args) 4) (member (car args) '("read" "read-opened")))
     (print-sample (cadr args) (rows-of (cadr args) (caddr args) (cadddr args)) (and (= (length args) 5) (list-ref args 4)) (equal? (car args) "read-opened"))]
    [(and (= (length args) 4) (equal? (car args) "classes")) (print-classes (rows-of (cadr args) (caddr args) (cadddr args)))]
    [(and (= (length args) 5) (equal? (car args) "classes") (equal? (list-ref args 4) "opened"))
     (print-classes (rows-of (cadr args) (caddr args) (cadddr args)) " (read in the second pass)")]
    [else (eprintf "usage: map-reference.rkt pairs DIR | ask DIR JAR | keep DIR FILE | ours DIR FILE | report DIR REF OURS [AFTER] | read DIR REF OURS [CLASS] | classes DIR REF OURS\n")
          (exit 2)]))

(module+ test
  (require rackunit)
  ;; the engine as it is now, over every pair made afresh, held to the reference's kept answers:
  ;; the write-up's agreement as floors, and nothing of the sample left that is this engine's or
  ;; in no class
  (let ([dir (make-temporary-file "map-reference-~a" 'directory)])
    (dynamic-wind
     void
     (lambda ()
       (write-map-materials! dir)
       (define ps (all-map-pairs dir))
       (define ref (read-answers kept-reference))
       (define errors (read-errors kept-reference))
       (define rows (for/list ([p (in-list ps)])
                      (list p (hash-ref ref (map-pair-id p) 'missing) (our-map-answer dir p) (hash-ref errors (map-pair-id p) ""))))
       (check-equal? (length rows) 887)
       (check-false (ormap (lambda (r) (eq? (cadr r) 'missing)) rows))
       (check-true (>= (count agree? (filter (lambda (r) (map-pair-sample? (car r))) rows)) 271))
       (check-true (>= (count agree? (filter (lambda (r) (not (map-pair-sample? (car r)))) rows)) 544))
       (check-equal? (count (lambda (r) (and (map-pair-sample? (car r)) (not (agree? r)) (memq (head-of r) '(ours unread)))) rows) 0))
     (lambda () (delete-directory/files dir))))
  (check-equal? (canonical (hasheq 'b 1.0 'a (list "x" #t))) "{\"a\":[\"x\",true],\"b\":1}")
  (check-equal? (reference-answer (hasheq 'id "1" 'error "x")) "error")
  (check-equal? (reference-answer (hasheq 'id "1" 'result "{\"resourceType\":\"TRight\",\"a\":\"x\"}")) "{\"a\":\"x\",\"resourceType\":\"TRight\"}"))
