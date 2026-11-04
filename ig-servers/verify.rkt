#lang racket/base

;;; verify.rkt — generate a FHIR server from an Implementation Guide, then hold it to the IG.
;;;
;;; The server is fhir-server's `make-ig-server`: everything it does comes from the IG package (its
;;; server CapabilityStatement, SearchParameters, profiles, OperationDefinitions). Every check below
;;; takes its expectations from the IG as well, so none is written by hand:
;;;
;;;   requirements  what the IG's CapabilityStatement asks for and the server does not do (gaps)
;;;   accepted      every example the IG publishes is valid, so every one must load through the
;;;                 server's write validation
;;;   read back     GET returns each example of a type the IG lets clients read as it was written (meta.versionId/lastUpdated aside: the
;;                 server assigns them)
;;;   search        each example is found by each search parameter the IG advertises for its type,
;;;                 queried with the example's own value (the shape a client sends for that type)
;;;   includes      every _include / _revinclude the server's /metadata advertises returns each stored
;;                 resource the example references (or is referenced by) through that parameter
;;   profiles      every profile an example claims resolves (else validation fell back to the base
;;                 type, and `accepted` proved less than it says)
;;   rejected      each example made invalid — an element its profile requires removed, or an
;;;                 element FHIR does not define added — must be refused (422)
;;;
;;; A miss in any of them is a defect in the generated server, in the validator, or (rarely) in
;;; the IG; `verify-ig` returns them all, named, for triage.

(require racket/contract racket/list racket/string racket/file json
         (only-in fhir/spec-package current-package-directories)
         (only-in fhir/http/router handle)
         (only-in fhir/store/fhir-sqlite open-fhir-store close-fhir-store)
         (only-in fhir/store/fhir-engine search-param-name search-param-kind search-param-path)
         (only-in fhir/store/search-index rows-for indexed-kind? token-row? token-row-system token-row-code
                  reference-row? reference-row-target-type reference-row-target-id string-row? string-row-exact
                  date-row? date-row-low date-row-high number-row? number-row-value quantity-row?
                  quantity-row-value quantity-row-system quantity-row-code)
         (only-in fhir/serialize/from-json from-json)
         (only-in fhir/serialize/read-json strip-jnum)
         (only-in fhir/result/result ok? ok-value)
         (only-in fhir/sd/sd-index resolve-sd-raw current-sd-packages)
         (only-in fhir/package read-package)
         (only-in fhirpath/parser/parse parse-fhirpath)
         (only-in fhirpath/eval eval-fhirpath)
         fhir/store/ig-server
         "fetch.rkt")

(provide
 (struct-out report) (struct-out tally)
 (contract-out
  ;; verify-ig : package-file [#:capability id] -> report
  [verify-ig (->* (path-string?) (#:capability (or/c string? #f)) report?)]
  [report->jsexpr (-> report? jsexpr?)]))

;; A Tally is (tally checked failures kinds): failures a list of (list what why …) for triage;
;; kinds, where the checks come in kinds, counts them by kind.
(struct tally (checked failures kinds) #:transparent)
(define (plain-tally checked failures) (tally checked failures (hash)))
;; A Report is one IG's results.
(struct report (ig version capability types gaps profiles accepted read-back search includes rejected) #:transparent)

(define (verify-ig tgz #:capability [capability #f])
  (parameterize ([current-package-directories (list (packages-dir))])
    (define db (make-temporary-file "ig-verify-~a.db"))
    (define store (open-fhir-store db))
    (define srv (make-ig-server store tgz #:capability capability))
    (define plan (ig-server-plan srv))
    (define app (ig-server-app srv))
    (define (go method path [q '()] [body ""]) (call-with-values (lambda () (handle app method path q body)) list))
    (define examples (served-examples tgz plan))
    ;; accepted: through the server's own loader (examples + the IG's ValueSets and CodeSystems)
    (define-values (loaded rejected) (load-ig-examples! srv))
    (define accepted (plain-tally (+ loaded (length rejected)) rejected))
    (define rejected-files (map car rejected))
    (define live (filter (lambda (ex) (not (member (car ex) rejected-files))) examples))
    (define read-back (check-read-back go (filter (lambda (ex) (declares? plan (hash-ref (cdr ex) 'resourceType) "read")) live)))
    (define search (check-search go live plan (ig-server-catalog srv)))
    (define includes (check-includes go live (ig-server-catalog srv)))
    (define profiles (check-profiles srv examples))
    (define refused (check-rejections srv live))          ; last: an accepted mutation overwrites
    (close-fhir-store store)
    (delete-file db)
    (report (ig-plan-name plan) (ig-plan-version plan) (or capability (hash-ref (ig-plan-ig-cs plan) 'id #f))
            (length (ig-plan-resources plan)) (map gap->list (ig-server-gaps srv))
            profiles accepted read-back search includes refused)))

;; declares? : plan type interaction -> boolean
(define (declares? plan type code)
  (for/or ([r (in-list (ig-plan-resources plan))])
    (and (equal? (ig-resource-type r) type) (assoc code (ig-resource-interactions r)) #t)))

;; served-examples : tgz plan -> (listof (cons file jsexpr))   the examples of a type the server serves
(define (served-examples tgz plan)
  (define types (map ig-resource-type (ig-plan-resources plan)))
  (define-values (_m _r exs) (read-package tgz))
  (for/list ([ex (in-list exs)]
             #:when (member (hash-ref (cdr ex) 'resourceType #f) types)
             #:when (string? (hash-ref (cdr ex) 'id #f)))
    (cons (car ex) (strip-jnum (cdr ex)))))

(define (type+id js) (format "~a/~a" (hash-ref js 'resourceType) (hash-ref js 'id)))

;; ---- read back ----------------------------------------------------------------------------------

(define (check-read-back go examples)
  (define failures
    (for*/list ([ex (in-list examples)]
                [r (in-value (go "GET" (string-append "/" (type+id (cdr ex)))))]
                [diff (in-value (if (= (car r) 200) (difference (without-version-meta (cdr ex)) (without-version-meta (cadr r)) "")
                                    (format "GET answered ~a" (car r))))]
                #:when diff)
      (list (type+id (cdr ex)) diff)))
  (plain-tally (length examples) failures))

(define (without-version-meta js)
  (define m (hash-ref js 'meta #f))
  (cond [(not (hash? m)) js]
        [else (define m2 (hash-remove (hash-remove m 'versionId) 'lastUpdated))
              (if (zero? (hash-count m2)) (hash-remove js 'meta) (hash-set js 'meta m2))]))

;; difference : jsexpr jsexpr path -> (or/c #f string)   the first place two documents differ
(define (difference a b path)
  (cond
    [(and (hash? a) (hash? b))
     (or (for/or ([k (in-list (sort (remove-duplicates (append (hash-keys a) (hash-keys b))) symbol<?))])
           (define p (format "~a.~a" path k))
           (cond [(not (hash-has-key? a k)) (format "~a added" p)]
                 [(not (hash-has-key? b k)) (format "~a lost" p)]
                 [else (difference (hash-ref a k) (hash-ref b k) p)])))]
    [(and (list? a) (list? b))
     (if (= (length a) (length b))
         (for/or ([x (in-list a)] [y (in-list b)] [i (in-naturals)]) (difference x y (format "~a[~a]" path i)))
         (format "~a: ~a items written, ~a read" path (length a) (length b)))]
    [(and (number? a) (number? b)) (and (not (= a b)) (format "~a: ~a written, ~a read" path a b))]
    [(equal? a b) #f]
    [else (format "~a: ~s written, ~s read" path a b)]))

;; ---- search -------------------------------------------------------------------------------------

;; probe-values : Row -> (listof query-value)   what a client sends to find this value
(define (probe-values row)
  (cond
    [(token-row? row) (list (if (token-row-system row)
                                (string-append (token-row-system row) "|" (token-row-code row))
                                (token-row-code row)))]
    [(reference-row? row) (list (if (reference-row-target-type row)
                                    (string-append (reference-row-target-type row) "/" (reference-row-target-id row))
                                    (reference-row-target-id row)))]
    [(string-row? row) (list (string-row-exact row))]
    [(date-row? row) (list (string-append "le" (date-row-low row)) (string-append "ge" (date-row-high row)))]
    [(number-row? row) (list (number->string (number-row-value row)))]
    [(quantity-row? row) (list (format "~a|~a|~a" (quantity-row-value row)
                                       (or (quantity-row-system row) "") (or (quantity-row-code row) "")))]
    [else '()]))

;; check-search : go examples plan catalog -> tally   one probe per (example, advertised parameter,
;; value shape) on the types that declare search-type (SDC lists parameters on types that do not);
;; a parameter the server cannot execute is a gap already, not counted here
(define (check-search go examples plan catalog)
  (define advertised
    (for/hash ([r (in-list (ig-plan-resources plan))] #:when (assoc "search-type" (ig-resource-interactions r)))
      (values (ig-resource-type r) (map car (ig-resource-search-params r)))))
  (define results
    (for*/list ([ex (in-list examples)]
                [js (in-value (cdr ex))]
                [type (in-value (hash-ref js 'resourceType))]
                [node (in-value (let ([n (from-json js #:lenient? #t)]) (and (ok? n) (ok-value n))))]
                #:when node
                [sp (in-list (hash-ref catalog (string->symbol type) '()))]
                #:when (member (search-param-name sp) (hash-ref advertised type '()))
                #:unless (equal? (search-param-name sp) "_lastUpdated")      ; the server assigns it
                #:when (indexed-kind? (search-param-kind sp))
                [items (in-value (with-handlers ([exn:fail? (lambda (_) '())])
                                   (eval-fhirpath (parse-fhirpath (search-param-path sp)) (list node) #:strict? #f)))]
                [row (in-value (let ([rs (rows-for (search-param-kind sp) items)]) (and (pair? rs) (car rs))))]
                #:when row
                [v (in-list (probe-values row))])
      (define r (go "GET" (string-append "/" type) (list (cons (string->symbol (search-param-name sp)) v))))
      (define found? (and (= (car r) 200)
                          (for/or ([e (in-list (hash-ref (cadr r) 'entry '()))])
                            (equal? (hash-ref (hash-ref e 'resource (hasheq)) 'id #f) (hash-ref js 'id)))))
      (and (not found?) (list (type+id js) (format "~a=~a" (search-param-name sp) v)
                              (if (= (car r) 200) "not in the results" (format "answered ~a" (car r)))))))
  (plain-tally (length results) (filter values results)))

;; ---- includes -----------------------------------------------------------------------------------

;; references : catalog jsexpr param-name -> (listof "Type/id")   what the example references
;; through a reference parameter (`*`: through any)
(define (references catalog js param)
  (define node (let ([n (from-json js #:lenient? #t)]) (and (ok? n) (ok-value n))))
  (remove-duplicates
   (for*/list ([sp (in-list (if node (hash-ref catalog (string->symbol (hash-ref js 'resourceType)) '()) '()))]
               #:when (eq? (search-param-kind sp) 'reference)
               #:when (or (equal? param "*") (equal? (search-param-name sp) param))
               [items (in-value (with-handlers ([exn:fail? (lambda (_) '())])
                                  (eval-fhirpath (parse-fhirpath (search-param-path sp)) (list node) #:strict? #f)))]
               [row (in-list (rows-for 'reference items))]
               #:when (reference-row-target-type row))
     (format "~a/~a" (reference-row-target-type row) (reference-row-target-id row)))))

;; check-includes : go examples catalog -> tally   one probe per (example, advertised include)
(define (check-includes go examples catalog)
  (define md (cadr (go "GET" "/metadata")))
  (define stored (for/hash ([ex (in-list examples)]) (values (type+id (cdr ex)) (cdr ex))))
  (define (included r) (for/list ([e (in-list (hash-ref (cadr r) 'entry '()))]
                                  #:when (equal? (hash-ref (hash-ref e 'search (hasheq)) 'mode #f) "include"))
                         (type+id (hash-ref e 'resource))))
  (define results
    (for*/list ([res (in-list (hash-ref (car (hash-ref md 'rest)) 'resource '()))]
                [k (in-list '(searchInclude searchRevInclude))]
                [v (in-list (hash-ref res k '()))]
                [parts (in-value (string-split v ":"))]
                #:when (<= 2 (length parts) 3)
                [ex (in-list examples)]
                #:when (equal? (hash-ref (cdr ex) 'resourceType) (hash-ref res 'type)))
      (define js (cdr ex))
      (define me (type+id js))
      (define expected
        (if (eq? k 'searchInclude)
            (for/list ([t (in-list (references catalog js (cadr parts)))]
                       #:when (hash-ref stored t #f)
                       #:when (or (= (length parts) 2) (regexp-match? (pregexp (string-append "^" (caddr parts) "/")) t)))
              t)
            (for/list ([(t other) (in-hash stored)]
                       #:when (equal? (hash-ref other 'resourceType) (car parts))
                       #:when (member me (references catalog other (cadr parts))))
              t)))
      (define r (go "GET" (string-append "/" (hash-ref js 'resourceType))
                    (list (cons '_id (hash-ref js 'id)) (cons (if (eq? k 'searchInclude) '_include '_revinclude) v))))
      (define missing (if (= (car r) 200) (remove* (included r) expected) expected))
      (and (pair? missing) (list me v (format "missing ~a" (string-join missing ", "))))))
  (plain-tally (length results) (filter values results)))

;; ---- profiles -----------------------------------------------------------------------------------

(define (check-profiles srv examples)
  (define results
    (parameterize ([current-sd-packages (ig-server-sd-packages srv)])
      (for*/list ([ex (in-list examples)]
                  [m (in-value (hash-ref (cdr ex) 'meta #f))]
                  [url (in-list (if (hash? m) (hash-ref m 'profile '()) '()))])
        (and (not (resolve-sd-raw (car (string-split url "|"))))
             (list (type+id (cdr ex)) url "does not resolve")))))
  (plain-tally (length results) (filter values results)))

;; ---- rejections ---------------------------------------------------------------------------------

;; mutations : jsexpr -> (listof (cons description jsexpr))   invalid versions of a valid example,
;; each from a top-level element of a claimed profile's snapshot that the example carries:
;;   required (min >= 1)         removed
;;   max 1 on a repeating field  its first item repeated
;;   fixed[x] / pattern[x]       replaced by a value that differs from it
;;   date / dateTime / instant   given a value that is not one
;; plus one element FHIR does not define
(define (mutations js)
  (define type (hash-ref js 'resourceType))
  (define claimed (let ([m (hash-ref js 'meta #f)]) (if (hash? m) (hash-ref m 'profile '()) '())))
  (define elements                                   ; (listof (list name choice? element))
    (remove-duplicates
     (for*/list ([url (in-list claimed)]
                 [sd (in-value (resolve-sd-raw (car (string-split url "|"))))] #:when sd
                 [e (in-list (hash-ref (hash-ref sd 'snapshot (hasheq)) 'element '()))]
                 [m (in-value (regexp-match (pregexp (format "^~a[.]([a-zA-Z]+)(\\[x\\])?$" (regexp-quote type)))
                                            (hash-ref e 'id "")))]
                 #:when m
                 #:unless (equal? (cadr m) "meta"))         ; it carries the profile claim itself
       (list (cadr m) (and (caddr m) #t) e))))
  (append
   (for*/list ([x (in-list elements)]
               #:when (>= (hash-ref (caddr x) 'min 0) 1)
               [keys (in-value (present-keys js (car x) (cadr x)))]
               #:when (pair? keys))
     (cons (format "without ~a (min ~a)" (car x) (hash-ref (caddr x) 'min))
           (for/fold ([h js]) ([k (in-list keys)]) (hash-remove h k))))
   (for*/list ([x (in-list elements)]
               #:when (equal? (hash-ref (caddr x) 'max #f) "1")
               [v (in-value (hash-ref js (string->symbol (car x)) #f))]
               #:when (and (list? v) (pair? v)))
     (cons (format "~a repeated (max 1)" (car x)) (hash-set js (string->symbol (car x)) (list (car v) (car v)))))
   (for*/list ([x (in-list elements)]
               #:unless (cadr x)
               [k (in-value (for/first ([k (in-list (hash-keys (caddr x)))]
                                        #:when (regexp-match? #rx"^(fixed|pattern)[A-Z]" (symbol->string k)))
                              k))]
               #:when k
               [v (in-value (hash-ref js (string->symbol (car x)) #f))]
               #:when v
               [bad (in-value (unlike (hash-ref (caddr x) k)))]
               #:when bad)
     (cons (format "~a not its ~a" (car x) k)
           (hash-set js (string->symbol (car x)) (if (list? v) (list bad) bad))))
   (for*/list ([x (in-list elements)]
               #:unless (cadr x)
               #:when (for/or ([t (in-list (hash-ref (caddr x) 'type '()))])
                        (member (hash-ref t 'code #f) '("date" "dateTime" "instant")))
               #:when (string? (hash-ref js (string->symbol (car x)) #f)))
     (cons (format "~a not a date" (car x)) (hash-set js (string->symbol (car x)) "the 3rd of May")))
   (list (cons "with an undefined element" (hash-set js 'notAnElement #t)))))

;; unlike : fixed-or-pattern value -> (or/c jsexpr #f)   a value of the same shape that differs
(define (unlike v)
  (cond
    [(string? v) (string-append v "-not")]
    [(boolean? v) (not v)]
    [(and (hash? v) (hash-has-key? v 'coding))
     (hasheq 'coding (list (hasheq 'system "http://example.org/not" 'code "not")))]
    [(and (hash? v) (hash-has-key? v 'system)) (hash-set (hash-set v 'system "http://example.org/not") 'code "not")]
    [else #f]))

;; present-keys : jsexpr name choice? -> (listof symbol)   the JSON keys that carry the element,
;; its `_` companion included (an extension-only primitive is present too)
(define (present-keys js name choice?)
  (for/list ([k (in-list (hash-keys js))]
             #:when (let ([s (regexp-replace #rx"^_" (symbol->string k) "")])
                      (if choice?
                          (regexp-match? (pregexp (format "^~a[A-Z]" (regexp-quote name))) s)
                          (equal? s name))))
    k))

(define (check-rejections srv examples)
  (define results
    (parameterize ([current-sd-packages (ig-server-sd-packages srv)])
      (for*/list ([ex (in-list examples)] [m (in-list (mutations (cdr ex)))])
        (define r (ig-server-put! srv (cdr m)))
        (list (mutation-kind (car m)) (and (eq? r 'ok) (list (type+id (cdr ex)) (car m) "accepted"))))))
  (tally (length results) (filter values (map cadr results))
               (for/fold ([h (hash)]) ([r (in-list results)]) (hash-update h (car r) add1 0))))

(define (mutation-kind d)
  (cond [(regexp-match? #rx"^without" d) "required removed"] [(regexp-match? #rx"repeated" d) "max exceeded"]
        [(regexp-match? #rx"not its" d) "fixed/pattern broken"] [(regexp-match? #rx"not a date" d) "bad date"]
        [else "undefined element"]))

;; ---- reporting ----------------------------------------------------------------------------------

(define (tally->jsexpr t)
  (hasheq 'checked (tally-checked t) 'failed (length (tally-failures t))
          'kinds (for/hasheq ([(k v) (in-hash (tally-kinds t))]) (values (string->symbol k) v))
          'failures (for/list ([f (in-list (tally-failures t))])
                      (if (pair? f) (map (lambda (x) (format "~a" x)) (if (list? f) f (list (car f) (cdr f)))) (format "~a" f)))))

(define (report->jsexpr r)
  (hasheq 'ig (report-ig r) 'version (report-version r) 'capability (report-capability r)
          'resourceTypes (report-types r)
          'gaps (for/list ([g (in-list (report-gaps r))]) (map (lambda (x) (format "~a" x)) g))
          'accepted (tally->jsexpr (report-accepted r))
          'profiles (tally->jsexpr (report-profiles r))
          'readBack (tally->jsexpr (report-read-back r))
          'search (tally->jsexpr (report-search r))
          'includes (tally->jsexpr (report-includes r))
          'rejected (tally->jsexpr (report-rejected r))))
