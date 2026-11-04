#lang racket/base

;;; fetch.rkt — an IG package and its dependencies, from the FHIR package registry, into packages/.
;;;
;;; A package is <name>-<version>.tgz, checked against the registry's shasum. Dependencies are
;;; followed transitively; a version pattern (`3.3.x`) resolves to the newest matching release.
;;; FHIR core packages are not fetched (fhir-spec has them), nor are the terminology and extensions
;;; packages, VSAC's included (the generated server does not read them: what they define is validated
;;; fail-open). A dependency the registry cannot supply is reported and left out.
;;; Every package fetched is recorded in packages.lock (name version shasum), which is committed;
;;; the tarballs are not.

(require racket/contract racket/list racket/string racket/file racket/port racket/runtime-path json
         net/url file/sha1
         (only-in fhir/package read-package))

(provide
 (contract-out
  [packages-dir (-> path?)]
  ;; fetch-ig! : name version -> path   the IG's package, its dependencies alongside
  [fetch-ig! (-> string? string? path?)]))

(define-runtime-path here ".")
(define (packages-dir) (simplify-path (build-path here "packages")))
(define registry "https://packages.fhir.org")

(define skipped #px"^hl7[.]fhir[.]r[0-9]+b?[.](core|examples)$|^hl7[.]terminology|^us[.]nlm[.]vsac|[.]extensions|^hl7[.]fhir[.]uv[.](tools|xver)")

;; registry-entry : name -> jsexpr   the registry's document for a package (every version)
(define (registry-entry name)
  (call/input-url (string->url (format "~a/~a" registry name)) get-pure-port read-json))

;; resolve-version : jsexpr pattern -> version   exact, or the newest release matching x/* parts
(define (resolve-version entry pattern)
  (define versions (map symbol->string (hash-keys (hash-ref entry 'versions))))
  (cond
    [(member pattern versions) pattern]
    [else
     (define rx (pregexp (string-append "^" (string-join (for/list ([p (in-list (string-split pattern "."))])
                                                           (if (member p '("x" "X" "*")) "[0-9]+" (regexp-quote p)))
                                                         "[.]")
                                        "$")))
     (define ms (filter (lambda (v) (regexp-match? rx v)) versions))
     (when (null? ms) (raise-user-error 'fetch "~a: no release matches ~a" (hash-ref entry 'name) pattern))
     (last (sort ms version<?))]))

(define (version<? a b)
  (let loop ([as (string-split a ".")] [bs (string-split b ".")])
    (cond [(null? bs) #f] [(null? as) #t]
          [else (define x (string->number (car as))) (define y (string->number (car bs)))
                (cond [(and x y (not (= x y))) (< x y)]
                      [(and (not (and x y)) (not (equal? (car as) (car bs)))) (string<? (car as) (car bs))]
                      [else (loop (cdr as) (cdr bs))])])))

;; local-package : name pattern -> (or/c path #f)   already fetched: the newest match in packages/
(define (local-package name pattern)
  (define rx (pregexp (string-append "^" (regexp-quote name) "-("
                                     (string-join (for/list ([p (in-list (string-split pattern "."))])
                                                    (if (member p '("x" "X" "*")) "[0-9]+" (regexp-quote p)))
                                                  "[.]")
                                     ")[.]tgz$")))
  (define found
    (if (directory-exists? (packages-dir))
        (for*/list ([f (in-list (directory-list (packages-dir)))]
                    [m (in-value (regexp-match rx (path->string f)))] #:when m)
          (cons (cadr m) (build-path (packages-dir) f)))
        '()))
  (and (pair? found) (cdr (last (sort found version<? #:key car)))))

;; fetch-package! : name pattern -> path   one package, verified against the registry's shasum
;; (the registry is asked only for what packages/ does not already hold)
(define (fetch-package! name pattern)
  (or (local-package name pattern) (download-package! name pattern)))

(define (download-package! name pattern)
  (define entry (registry-entry name))
  (define version (resolve-version entry pattern))
  (define file (build-path (packages-dir) (format "~a-~a.tgz" name version)))
  (unless (file-exists? file)
    (define dist (hash-ref (hash-ref (hash-ref entry 'versions) (string->symbol version)) 'dist))
    (define bytes (call/input-url (string->url (hash-ref dist 'tarball)) get-pure-port port->bytes))
    (define sum (sha1 (open-input-bytes bytes)))
    (unless (equal? sum (hash-ref dist 'shasum))
      (raise-user-error 'fetch "~a ~a: shasum ~a, the registry says ~a" name version sum (hash-ref dist 'shasum)))
    (make-directory* (packages-dir))
    (call-with-output-file file (lambda (o) (write-bytes bytes o)))
    (record-lock! name version sum)
    (printf "  fetched ~a ~a\n" name version))
  file)

(define (dependencies-of file)
  (define-values (m _r _e) (read-package file #:select (lambda (_) #f)))
  (define ds (and m (hash-ref m 'dependencies #f)))
  (if (hash? ds) (for/list ([(k v) (in-hash ds)]) (cons (symbol->string k) v)) '()))

(define (fetch-ig! name version)
  (let loop ([todo (list (cons name version))] [seen '()] [first-file #f])
    (cond
      [(null? todo) first-file]
      [(or (member (car todo) seen) (regexp-match? skipped (caar todo))) (loop (cdr todo) seen first-file)]
      [else
       (define f (with-handlers ([exn:fail? (lambda (e) (if first-file
                                                                 (begin (eprintf "  left out: ~a\n" (exn-message e)) #f)
                                                                 (raise e)))])
                   (fetch-package! (caar todo) (cdar todo))))
       (loop (append (cdr todo) (if f (dependencies-of f) '())) (cons (car todo) seen) (or first-file f))])))

;; ---- packages.lock ------------------------------------------------------------------------------

(define lock-file (build-path here "packages.lock"))
(define (record-lock! name version sum)
  (define old (if (file-exists? lock-file) (file->value lock-file) '()))
  (define new (sort (remove-duplicates (cons (list name version sum) old)) string<? #:key (lambda (e) (format "~a ~a" (car e) (cadr e)))))
  (with-output-to-file lock-file #:exists 'truncate
    (lambda () (printf "(\n") (for ([e (in-list new)]) (printf " ~s\n" e)) (printf ")\n"))))

(module+ test
  (require rackunit)
  (check-true (version<? "3.3.2" "3.3.10"))
  (check-equal? (resolve-version (hasheq 'name "x" 'versions (hasheq '|3.3.2| 1 '|3.3.10| 1 '|3.4.0| 1)) "3.3.x") "3.3.10")
  (check-true (regexp-match? skipped "hl7.fhir.uv.extensions.r4"))
  (check-false (regexp-match? skipped "hl7.fhir.us.core.v311")))
