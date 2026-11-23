#lang racket/base

;;; map-cases.rkt — the pairs of H's second part (value-experiment/PROTOCOL.md, "the mapping language
;;; held to the validator's StructureMap engine"): the FHIR mapping tutorial's maps over its sources,
;;; and both changed in one small way. The rules are the protocol's.
;;;
;;; Data definitions.
;;; A MapPair is (map-pair id group step base change map url source sample?):
;;;   id      a string, its place in the list
;;;   group   'published | 'changed-source | 'changed-map
;;;   step    the tutorial step ("step5"), whose logical models type the pair
;;;   base    the published map it is, or was changed from ("step5/step5.map")
;;;   change  what was changed, in a word ("" for a published pair): "source remove", "mode first" …
;;;   map     the map's text, a file relative to the work directory
;;;   url     the map's url (a changed map has one of its own)
;;;   source  the source, a JSON file relative to the work directory
;;;   sample? whether its disagreements may be read
;;; A Change is (cons label text): what was done, and the changed text (or a changed jsexpr).

(require racket/file racket/list racket/string racket/path json file/sha1)

(provide (struct-out map-pair) all-map-pairs write-map-materials! sample-map? map-url source-changes map-changes
         pair->jsexpr jsexpr->pair)

(struct map-pair (id group step base change map url source sample?) #:transparent)

(define tutorial (build-path (collection-path "fml") "tests" "vendor" "matchbox" "tutorial"))

;; steps : -> (listof string)   the tutorial's steps, in number order
(define (steps)
  (sort (for/list ([d (in-list (directory-list tutorial))] #:when (directory-exists? (build-path tutorial d "map"))) (path->string d))
        < #:key (lambda (s) (string->number (regexp-replace #rx"^step" s "")))))

(define (files-of step sub rx)
  (sort (for/list ([f (in-list (directory-list (build-path tutorial step sub)))] #:when (regexp-match? rx (path->string f))) (path->string f))
        string<?))

;; sample-map? : string -> boolean   a third of the maps: the first byte of the SHA-1 of "<step>/<file>" divisible by three
(define (sample-map? base)
  (zero? (modulo (bytes-ref (sha1-bytes (open-input-bytes (string->bytes/utf-8 base))) 0) 3)))

;; map-url : string -> (or/c string #f)   the url a map's text declares, in either header form
(define (map-url text)
  (cond [(regexp-match #px"(?m:^\\s*///\\s*url\\s*=\\s*['\"]([^'\"]+)['\"])" text) => cadr]
        [(regexp-match #px"(?m:^\\s*map\\s+\"([^\"]+)\")" text) => cadr]
        [else #f]))

;; with-url : string string -> string   the map's text with its url replaced (the first place it stands)
(define (with-url text new)
  (define old (map-url text))
  (if old (string-replace text old new #:all? #f) text))

;; ---- one change to a source ------------------------------------------------------------------------
;; places : jsexpr -> (listof (cons path value))   every value, with the keys and indexes that lead to it
(define (places j [path '()])
  (cond [(hash? j) (append* (for/list ([k (in-list (sort (hash-keys j) symbol<?))] #:unless (eq? k 'resourceType))
                              (define p (append path (list k)))
                              (cons (cons p (hash-ref j k)) (places (hash-ref j k) p))))]
        [(list? j) (append* (for/list ([x (in-list j)] [i (in-naturals)])
                              (define p (append path (list i)))
                              (cons (cons p x) (places x p))))]
        [else '()]))
(define (replaced j path f)
  (cond [(null? path) (f j)]
        [(hash? j) (hash-set j (car path) (replaced (hash-ref j (car path)) (cdr path) f))]
        [else (for/list ([x (in-list j)] [i (in-naturals)]) (if (= i (car path)) (replaced x (cdr path) f) x))]))

;; source-changes : jsexpr -> (listof Change)   every single change of the catalogue: a key removed, a
;; string replaced by another, a number raised by one, a list's first entry given twice, a list reversed
(define (source-changes j)
  (define here (places j))
  (append
   (for/list ([pl (in-list here)] #:when (symbol? (last (car pl))))
     (cons "source remove" (replaced j (drop-right (car pl) 1) (lambda (o) (hash-remove o (last (car pl)))))))
   (for/list ([pl (in-list here)] #:when (string? (cdr pl)))
     (cons "source string" (replaced j (car pl) (lambda (_) "changed"))))
   (for/list ([pl (in-list here)] #:when (and (real? (cdr pl)) (not (boolean? (cdr pl)))))
     (cons "source number" (replaced j (car pl) add1)))
   (for/list ([pl (in-list here)] #:when (and (list? (cdr pl)) (pair? (cdr pl))))
     (cons "source twice" (replaced j (car pl) (lambda (l) (cons (car l) l)))))
   (for/list ([pl (in-list here)] #:when (and (list? (cdr pl)) (pair? (cdr pl)) (pair? (cdr (cdr pl)))))
     (cons "source reversed" (replaced j (car pl) reverse)))))

;; ---- one change to a map ---------------------------------------------------------------------------
(define list-modes '("first" "last" "not_first" "not_last" "only_one"))
(define source-rx #px"^(\\s*)([A-Za-z_][A-Za-z0-9_]*(?:\\.[A-Za-z_][A-Za-z0-9_]*)?)(?:\\s+(first|last|not_first|not_last|only_one))?(\\s+as\\s+([A-Za-z_][A-Za-z0-9_]*))")
(define target-rx #px"(=\\s*)([A-Za-z_][A-Za-z0-9_]*)(\\s*(?:,|\"|then\\b|;))")

;; map-changes : string -> (listof Change)   every single change of the catalogue to one rule of a
;; map: the rule removed; a list mode put on its source or replaced; a `where` added; the value its
;; target is given replaced by a transform of it. A rule is a line that holds `->`.
(define (map-changes text)
  (define lines (string-split text "\n" #:trim? #f))
  (define (with-line i new) (string-join (for/list ([l (in-list lines)] [k (in-naturals)]) (if (= k i) new l)) "\n"))
  (define (without-line i) (string-join (for/list ([l (in-list lines)] [k (in-naturals)] #:unless (= k i)) l) "\n"))
  (append*
   (for/list ([l (in-list lines)] [i (in-naturals)] #:when (regexp-match? #rx"->" l))
     (define arrow (car (regexp-match-positions #rx"->" l)))
     (define before (substring l 0 (car arrow)))
     (define after (substring l (car arrow)))
     (define src (regexp-match source-rx before))
     (define tgt (regexp-match target-rx after))
     (append
      ;; the rule removed, when it is whole on its line
      (if (regexp-match? #px";\\s*(//.*)?$" l) (list (cons "rule removed" (without-line i))) '())
      ;; a list mode put on the source, or replaced
      (if src
          (for/list ([m (in-list list-modes)] #:unless (equal? m (cadddr src)))
            (cons (format "mode ~a" m)
                  (with-line i (string-append (regexp-replace source-rx before (format "\\1\\2 ~a\\4" m)) after))))
          '())
      ;; a where added to the source
      (if (and src (not (regexp-match? #rx"where" before)))
          (let ([v (list-ref src 5)])
            (for/list ([w (in-list (list (cons "where true" "(true)") (cons "where false" "(false)")
                                         (cons "where exists" (format "(~a.exists())" v))
                                         (cons "where length" (format "(~a.toString().length() > 5)" v))))])
              (cons (car w) (with-line i (string-append (regexp-replace source-rx before (format "\\0 where ~a" (regexp-replace-quote (cdr w)))) after)))))
          '())
      ;; the value the target is given, replaced by a transform of it
      (if tgt
          (let ([v (caddr tgt)])
            (for/list ([t (in-list (list (cons "transform copy" (format "copy(~a)" v))
                                         (cons "transform truncate" (format "truncate(~a, 3)" v))
                                         (cons "transform append" (format "append(~a, 'x')" v))
                                         (cons "transform cast string" (format "cast(~a, 'string')" v))
                                         (cons "transform cast integer" (format "cast(~a, 'integer')" v))
                                         (cons "transform evaluate" (format "evaluate(~a, $this.toString().length())" v))
                                         (cons "transform expression" (format "(~a.toString().upper())" v))))])
              (cons (car t) (with-line i (string-append before (regexp-replace target-rx after (format "\\1~a\\3" (regexp-replace-quote (cdr t)))))))))
          '())))))

;; ---- the materials and the pairs -------------------------------------------------------------------
;; A Made is (list group step base change map-file url source-file): a pair before it has its id.
;; made : dir boolean -> (listof Made)   every pair; with write? the files they name are written under dir
(define (made dir write?)
  (define (put! rel content)
    (when write?
      (define f (build-path dir rel))
      (make-directory* (path-only f))
      (call-with-output-file f #:exists 'truncate (lambda (o) (if (string? content) (write-string content o) (write-json content o)))))
    (path->string rel))
  (append*
   (for/list ([step (in-list (steps))])
     (when write?
       (for ([f (in-list (files-of step "logical" #rx"[.]json$"))])
         (make-directory* (build-path dir step "logical"))
         (copy-file (build-path tutorial step "logical" f) (build-path dir step "logical" f) #t)))
     (define maps
       (for/list ([f (in-list (files-of step "map" #rx"[.]map$"))])
         (define text (file->string (build-path tutorial step "map" f)))
         (list (format "~a/~a" step f) text (put! (build-path step "map" f) text))))
     (define sources
       (for/list ([f (in-list (files-of step "source" #rx"[.]json$"))])
         (define j (call-with-input-file (build-path tutorial step "source" f) read-json))
         (list f j (put! (build-path step "source" f) j))))
     (append
      (for*/list ([m (in-list maps)] [s (in-list sources)])
        (list 'published step (car m) "" (caddr m) (map-url (cadr m)) (caddr s)))
      (for*/list ([s (in-list sources)] [c (in-list (source-changes (cadr s)))]
                  [file (in-value (put! (build-path step "source" (format "~a~~~a.json" (regexp-replace #rx"[.]json$" (car s) "") (equal-hash-code* (cdr c)))) (cdr c)))]
                  [m (in-list maps)])
        (list 'changed-source step (car m) (car c) (caddr m) (map-url (cadr m)) file))
      (for*/list ([m (in-list maps)] [c (in-list (map-changes (cadr m)))] [s (in-list sources)])
        (define tag (equal-hash-code* (cdr c)))
        (define url (format "~a-c~a" (map-url (cadr m)) tag))
        (list 'changed-map step (car m) (car c)
              (put! (build-path step "map" (format "~a~~~a.map" (regexp-replace #rx"^.*/|[.]map$" (car m) "") tag)) (with-url (cdr c) url))
              url (caddr s)))))))

;; equal-hash-code* : any -> string   a short name for a changed text or value, the same in every run
(define (equal-hash-code* v)
  (substring (sha1 (open-input-bytes (string->bytes/utf-8 (if (string? v) v (jsexpr->string v))))) 0 10))

;; write-map-materials! : dir -> void
(define (write-map-materials! dir) (void (made dir #t)))

;; all-map-pairs : dir -> (listof MapPair)   every pair, in a fixed order
(define (all-map-pairs dir)
  (for/list ([m (in-list (made dir #f))] [i (in-naturals)])
    (map-pair (number->string i) (car m) (cadr m) (caddr m) (cadddr m) (list-ref m 4) (list-ref m 5) (list-ref m 6)
              (sample-map? (caddr m)))))

(define (pair->jsexpr p)
  (hasheq 'id (map-pair-id p) 'group (symbol->string (map-pair-group p)) 'step (map-pair-step p) 'base (map-pair-base p)
          'change (map-pair-change p) 'map (map-pair-map p) 'url (map-pair-url p) 'source (map-pair-source p) 'sample (map-pair-sample? p)))
(define (jsexpr->pair j)
  (map-pair (hash-ref j 'id) (string->symbol (hash-ref j 'group)) (hash-ref j 'step) (hash-ref j 'base) (hash-ref j 'change)
            (hash-ref j 'map) (hash-ref j 'url) (hash-ref j 'source) (hash-ref j 'sample)))

(module+ test
  (require rackunit)
  (check-equal? (map-url "/// url = 'http://x/a'\n/// name = 'a'\n") "http://x/a")
  (check-equal? (map-url "map \"http://x/b\" = \"b\"\n") "http://x/b")
  (define m "/// url = 'http://x/a'\ngroup g(source src : L, target tgt : R) {\n  src.a as a -> tgt.a = a \"r\";\n}\n")
  (define cs (map-changes m))
  (check-equal? (length cs) (+ 1 5 4 7))
  (check-not-false (member "  src.a first as a -> tgt.a = a \"r\";" (string-split (cdr (assoc "mode first" cs)) "\n")))
  (check-not-false (member "  src.a as a where (false) -> tgt.a = a \"r\";" (string-split (cdr (assoc "where false" cs)) "\n")))
  (check-not-false (member "  src.a as a -> tgt.a = truncate(a, 3) \"r\";" (string-split (cdr (assoc "transform truncate" cs)) "\n")))
  (check-equal? (map car (source-changes (hasheq 'resourceType "T" 'a "x" 'b (list 1 2))))
                '("source remove" "source remove" "source string" "source number" "source number" "source twice" "source reversed"))
  (check-equal? (length (steps)) 13))
