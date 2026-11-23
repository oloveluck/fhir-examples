#lang racket/base

;;; fsh-cases.rkt — the pairs of H's third part (value-experiment/PROTOCOL.md, "the FSH compiler
;;; held to SUSHI"): whole FSH texts, published and changed in one small way. The rules are the
;;; protocol's.
;;;
;;; Data definitions.
;;; An FshPair is (fsh-pair id group corpus base change file sample?):
;;;   id      a string, its place in the list
;;;   group   'published | 'changed
;;;   corpus  "importer" (SUSHI's own importer test inputs) | "golden" (fsh's golden corpus) | "guide"
;;;   base    the published text it is, or was changed from ("importer/FSHImporter.Alias.test.ts: should …")
;;;   change  what was changed, in a word ("" for a published text): "rule removed", "card 1..1" …
;;;   file    the text, a file relative to the work directory
;;;   sample? whether its disagreements may be read
;;; A Change is (cons label text).

(require racket/file racket/list racket/string racket/path json file/sha1)

(provide (struct-out fsh-pair) all-fsh-pairs write-fsh-materials! sample-text? text-changes
         pair->jsexpr jsexpr->pair)

(struct fsh-pair (id group corpus base change file sample?) #:transparent)

(define fsh-root (collection-path "fsh"))
(define importer-cases (build-path fsh-root "tests" "vendor" "sushi-importer" "cases.json"))
(define golden-dir (build-path fsh-root "tests" "vendor" "golden"))
(define guide-file (build-path fsh-root "guide.md"))

;; published-texts : -> (listof (list corpus name text))   every published text, in a fixed order
(define (published-texts)
  (append
   (for/list ([c (in-list (call-with-input-file importer-cases read-json))])
     (list "importer" (format "~a: ~a" (hash-ref c 'file) (hash-ref c 'name)) (hash-ref c 'input)))
   (for/list ([f (in-list (sort (map path->string (directory-list golden-dir)) string<?))] #:when (regexp-match? #rx"[.]fsh$" f))
     (list "golden" f (file->string (build-path golden-dir f))))
   (for/list ([b (in-list (regexp-match* #px"```fsh\n(.*?)```" (file->string guide-file) #:match-select cadr))] [i (in-naturals 1)])
     (list "guide" (format "block ~a" i) b))))

;; sample-text? : string -> boolean   a third of the published texts: the first byte of the SHA-1
;; of "<corpus>/<name>" divisible by three
(define (sample-text? base)
  (zero? (modulo (bytes-ref (sha1-bytes (open-input-bytes (string->bytes/utf-8 base))) 0) 3)))

;; ---- one change to a text ------------------------------------------------------------------------
(define rule-rx #px"^\\s*\\*\\s")
(define cardinality-rx #px"(?<![\\w.])(\\d+)[.][.](\\d+|[*])(?![\\w.])")
(define cardinalities '("1..1" "0..1" "1..*" "0..*"))
(define strengths '("required" "extensible" "preferred" "example"))

;; line-changes : string -> (listof (cons label string))   one rule line, changed in each way that applies
(define (line-changes line)
  (append
   ;; a cardinality replaced by each of the four it is not
   (cond [(regexp-match cardinality-rx line)
          => (lambda (m)
               (for/list ([c (in-list cardinalities)] #:unless (equal? c (car m)))
                 (cons (string-append "card " c) (regexp-replace cardinality-rx line c))))]
         [else '()])
   ;; a flag added where the rule states a cardinality and no flag; removed where it has MS
   (cond [(regexp-match? #px"\\sMS(\\s|$)" line) (list (cons "flag removed" (regexp-replace #px"\\sMS(?=\\s|$)" line "")))]
         [(and (regexp-match? cardinality-rx line) (not (regexp-match? #px"\\s(SU|TU|N|D|[?]!)(\\s|$)" line)))
          (list (cons "flag added" (string-append (string-trim line #:left? #f) " MS")))]
         [else '()])
   ;; a binding's strength replaced by the next one
   (cond [(regexp-match #px"[(](required|extensible|preferred|example)[)]" line)
          => (lambda (m)
               (define next (list-ref strengths (modulo (add1 (index-of strengths (cadr m))) 4)))
               (list (cons (string-append "strength " next) (string-replace line (car m) (string-append "(" next ")") #:all? #f))))]
         [else '()])
   ;; (exactly) added to an assignment, or removed from it
   (cond [(regexp-match? #px"\\s=\\s.*[(]exactly[)]\\s*$" line) (list (cons "exactly removed" (regexp-replace #px"\\s*[(]exactly[)]\\s*$" line "")))]
         [(regexp-match? #px"\\s=\\s" line) (list (cons "exactly added" (string-append (string-trim line #:left? #f) " (exactly)")))]
         [else '()])
   ;; an assigned code, text or number replaced by another of its kind
   (cond [(regexp-match? #px"\\s=\\s+[^\\s\"#]*#[^\\s\"]+" line)
          (list (cons "value code" (regexp-replace #px"(\\s=\\s+[^\\s\"#]*#)[^\\s\"]+" line "\\1changed")))]
         [(regexp-match? #px"\\s=\\s+\"[^\"]*\"" line)
          (list (cons "value text" (regexp-replace #px"(\\s=\\s+)\"[^\"]*\"" line "\\1\"changed\"")))]
         [(regexp-match #px"\\s=\\s+(-?\\d+)(\\s*([(]exactly[)])?\\s*)$" line)
          => (lambda (m)
               (list (cons "value number"
                           (regexp-replace #px"(\\s=\\s+)-?\\d+" line
                                           (lambda (all before) (string-append before (number->string (add1 (string->number (cadr m))))))))))]
         [else '()])))

;; text-changes : string -> (listof Change)   the text with one rule line removed, or changed
(define (text-changes text)
  (define lines (string-split text "\n" #:trim? #f))
  (define (with-line i new) ; new = #f removes the line
    (string-join (append (take lines i) (if new (list new) '()) (drop lines (add1 i))) "\n"))
  (append*
   (for/list ([line (in-list lines)] [i (in-naturals)] #:when (regexp-match? rule-rx line))
     (cons (cons "rule removed" (with-line i #f))
           (for/list ([c (in-list (line-changes line))]) (cons (car c) (with-line i (cdr c))))))))

;; ---- the materials and the pairs -------------------------------------------------------------------
;; A Made is (list group corpus base change file).
;; made : dir boolean -> (listof Made)   every pair; with write? the texts are written under dir
(define (made dir write?)
  (define (put! rel text)
    (when write?
      (define f (build-path dir rel))
      (make-directory* (path-only f))
      (call-with-output-file f #:exists 'truncate (lambda (o) (write-string text o))))
    (path->string rel))
  (append*
   (for/list ([p (in-list (published-texts))] [n (in-naturals)])
     (define-values (corpus name text) (apply values p))
     (define base (format "~a/~a" corpus name))
     (cons (list 'published corpus base "" (put! (build-path "texts" (format "~a.fsh" n)) text))
           (for/list ([c (in-list (text-changes text))] [k (in-naturals)])
             (list 'changed corpus base (car c) (put! (build-path "texts" (format "~a~~~a.fsh" n k)) (cdr c))))))))

(define (write-fsh-materials! dir) (void (made dir #t)))

;; all-fsh-pairs : dir -> (listof FshPair)   every pair, in a fixed order
(define (all-fsh-pairs dir)
  (for/list ([m (in-list (made dir #f))] [i (in-naturals)])
    (fsh-pair (number->string i) (car m) (cadr m) (caddr m) (cadddr m) (list-ref m 4) (sample-text? (caddr m)))))

(define (pair->jsexpr p)
  (hasheq 'id (fsh-pair-id p) 'group (symbol->string (fsh-pair-group p)) 'corpus (fsh-pair-corpus p) 'base (fsh-pair-base p)
          'change (fsh-pair-change p) 'file (fsh-pair-file p) 'sample (fsh-pair-sample? p)))
(define (jsexpr->pair j)
  (fsh-pair (hash-ref j 'id) (string->symbol (hash-ref j 'group)) (hash-ref j 'corpus) (hash-ref j 'base) (hash-ref j 'change)
            (hash-ref j 'file) (hash-ref j 'sample)))

(module+ test
  (require rackunit)
  (define t "Profile: P\nParent: Patient\n* name 1..* MS\n* gender = #female\n* birthDate 0..1\n* maritalStatus from VS (required)\n* active = true\n* multipleBirthInteger = 2\n* name.family = \"Lee\" (exactly)\n")
  (define cs (text-changes t))
  (define (changed label) (for/list ([c (in-list cs)] #:when (equal? (car c) label)) (cdr c)))
  (define (has-line? text line) (and (member line (string-split text "\n")) #t))
  (check-equal? (length (changed "rule removed")) 7)
  (check-true (has-line? (car (changed "card 1..1")) "* name 1..1 MS"))
  (check-true (has-line? (car (changed "flag removed")) "* name 1..*"))
  (check-true (has-line? (car (changed "flag added")) "* birthDate 0..1 MS"))
  (check-true (has-line? (car (changed "strength extensible")) "* maritalStatus from VS (extensible)"))
  (check-true (has-line? (car (changed "value code")) "* gender = #changed"))
  (check-true (has-line? (car (changed "exactly added")) "* gender = #female (exactly)"))
  (check-true (has-line? (car (changed "exactly removed")) "* name.family = \"Lee\""))
  (check-true (has-line? (car (changed "value text")) "* name.family = \"changed\" (exactly)"))
  (check-true (has-line? (car (changed "value number")) "* multipleBirthInteger = 3"))
  ;; a cardinality is replaced by the three it is not
  (check-equal? (length (filter (lambda (c) (regexp-match? #rx"^card " (car c))) cs)) 6)
  (check-true (>= (length (published-texts)) 539)))
