#lang racket/base

;;; dsl-sizes.rkt — each language of the family against the FHIR it compiles to, by size.
;;;
;;;   racket dsl-sizes.rkt [--out dir] [--count '<model command>'] [--cap chars]
;;;
;;; A Pair is one artifact stated twice: in its language (`dsl`) and as the JSON that language
;;; compiles to (`json`, written compact and indented). The pairs come from published material:
;;;
;;;   profile     every profile of IPS 2.0.1 and mCODE 4.0.0: the StructureDefinition without its
;;;               snapshot and narrative (what an author states) | FSH, from the decompiler, which
;;;               compiles back to that resource
;;;   instance    their examples, without narrative                | FSH, the same way
;;;   value set   their ValueSets, without narrative and expansion | FSH
;;;   compose     the `compose` of those value sets                | VCL, where VCL can say it
;;;   map         fml's corpus maps: the StructureMap              | the mapping language (fml/print)
;;;   library     cql's corpus libraries: the ELM as JSON, with no annotations or locators | CQL
;;;               without its comments
;;;
;;; Characters are counted for every pair. With `--count`, a sample of each kind (the first
;;; `--cap` characters of indented JSON, pairs in id order) is given to the model command and its
;;; reported input tokens, less those of an empty prompt, are the tokens — the tokenizer the
;;; benchmarks' agents pay in. The command is one that answers with Claude Code's JSON
;;; (`claude -p --output-format json …`).

(require racket/list racket/string racket/file racket/port racket/system racket/cmdline json
         (only-in fhir/r4/schemas)
         (only-in fhir/spec-package spec-package-path)
         (only-in fhir/sd/sd-index current-sd-packages)
         (only-in fhir/package read-package)
         (only-in fhir/serialize/fhir-json fhir-json->string)
         (only-in fhir/result/result ok? ok-value)
         (only-in fsh/decompile fhir->fsh)
         (only-in fsh/compile fsh->fhir fsh-fhir-version)
         (only-in vcl/decompile compose->vcl)
         (only-in fml/parser/parse parse-fml)
         (only-in fml/structuremap fml->structuremap)
         (only-in fml/print fml->text)
         "model.rkt")

;; A Pair is (pair kind id dsl json) — json a jsexpr
(struct pair* (kind id dsl json) #:transparent)

;; ---- the pairs -----------------------------------------------------------------------------------

;; stated : resource -> resource   what an author states: no narrative, snapshot or expansion
(define (stated j) (for/fold ([j j]) ([k (in-list '(text snapshot expansion))]) (hash-remove j k)))

;; attempt : (-> a) -> a | #f
(define (attempt thunk) (with-handlers ([exn:fail? (lambda (_) #f)]) (thunk)))

;; package-pairs : tgz -> (listof Pair)   profiles, instances, value sets and composes of a package
(define (package-pairs tgz)
  (define-values (_m resources examples) (read-package tgz))
  (define (fsh-pair kind j) (let ([t (attempt (lambda () (fhir->fsh j)))]) (and t (pair* kind (hash-ref j 'id "?") t j))))
  (append
   (for/list ([e (in-list resources)]
              #:when (and (equal? (hash-ref (cdr e) 'resourceType #f) "StructureDefinition")
                          (equal? (hash-ref (cdr e) 'derivation #f) "constraint")))
     (fsh-pair "profile" (stated (cdr e))))
   (for/list ([e (in-list examples)] #:unless (member (hash-ref (cdr e) 'resourceType #f) '("Bundle" "ImplementationGuide")))
     (fsh-pair "instance" (stated (cdr e))))
   (for/list ([e (in-list resources)] #:when (equal? (hash-ref (cdr e) 'resourceType #f) "ValueSet"))
     (fsh-pair "value set (FSH)" (stated (cdr e))))
   (for/list ([e (in-list resources)]
              #:when (and (equal? (hash-ref (cdr e) 'resourceType #f) "ValueSet") (hash-ref (cdr e) 'compose #f)))
     (define c (hash-ref (cdr e) 'compose))
     (define t (attempt (lambda () (compose->vcl c))))
     (and t (pair* "compose (VCL)" (hash-ref (cdr e) 'id "?") t c)))))

;; map-pairs : dir -> (listof Pair)   every .map of a directory that parses
(define (map-pairs dir)
  (for/list ([f (in-list (sort (map path->string (directory-list dir)) string<?))] #:when (regexp-match? #rx"[.]map$" f))
    (define r (attempt (lambda () (parse-fml (file->string (build-path dir f))))))
    (and r (ok? r)
         (let ([m (ok-value r)])
           (attempt (lambda () (pair* "map (FML)" f (fml->text m) (fml->structuremap m))))))))

;; without-comments : cql text -> text   ELM keeps no comment, so the CQL is counted without them
(define (without-comments t)
  (string-join (filter (lambda (l) (not (regexp-match? #px"^\\s*$" l)))
                       (string-split (regexp-replace* #px"(?m:[ \t]*//.*$)" (regexp-replace* #px"(?s:/[*].*?[*]/)" t "") "") "\n"))
               "\n"))

;; library-pairs : dir -> (listof Pair)   each .cql of a corpus package with the ELM `raco cql` gives
(define (library-pairs dir)
  (for/list ([f (in-list (sort (map path->string (directory-list dir)) string<?))] #:when (regexp-match? #rx"[.]cql$" f))
    (define out (open-output-string))
    (define ok? (parameterize ([current-output-port out] [current-error-port (open-output-nowhere)])
                  (system* (find-executable-path "raco") "cql" (path->string (build-path dir f)) "--libraries" (path->string dir))))
    (define elm (and ok? (attempt (lambda () (string->jsexpr (get-output-string out))))))
    (and (hash? elm) (pair* "library (CQL)" f (without-comments (file->string (build-path dir f))) elm))))

;; ---- what the language can carry for an instance ---------------------------------------------------

;; aliased : (listof fsh-text) -> (listof fsh-text)   every code system url the texts write more than
;; once named by an Alias, the aliases declared once ahead of the texts (a workspace's alias table)
(define (aliased texts)
  (define rx #px"(?<=[ (=])(https?://[^\\s#\"|()]+)(?=[|#])")
  (define found (append-map (lambda (t) (regexp-match* rx t)) texts))
  (define counts (for/fold ([h (hash)]) ([u (in-list found)]) (hash-update h u add1 0)))
  (define urls (sort (for/list ([(u n) (in-hash counts)] #:when (> n 1)) u) string<?))
  (define names
    (for/fold ([acc '()] #:result (reverse acc)) ([u (in-list urls)])
      (define seg (car (string-split (last (string-split u "/")) ".")))
      (define base (let ([b (regexp-replace* #px"[^A-Za-z0-9_-]" seg "")]) (if (string=? b "") "cs" b)))
      (define name (let loop ([n 1]) (let ([c (if (= n 1) (string-append "$" base) (format "$~a~a" base n))])
                                       (if (member c (map cdr acc)) (loop (add1 n)) c))))
      (cons (cons u name) acc)))
  (define (rename t)
    (for/fold ([t t]) ([p (in-list names)])
      (regexp-replace* (pregexp (string-append "(?<=[ (=])" (regexp-quote (car p)) "(?=[|#])")) t (regexp-replace-quote (cdr p)))))
  (cons (string-join (for/list ([p (in-list names)]) (format "Alias: ~a = ~a" (cdr p) (car p))) "\n") (map rename texts)))

;; of-its-profile : resource fsh-text (url -> name | #f) (url -> (listof (cons path slice))) -> fsh-text
;; the instance as an instance OF the one profile it claims, stated with what is its own: entries
;; named by the profile's slices, a lone `[0]` left unwritten, and no rule the compiler writes by
;; itself from the profile (its fixed and required values, meta.profile). Every step is kept only
;; when the text still compiles to exactly the resource, so the answer is the resource.
(define (of-its-profile j text profile-name profile-slices)
  (define (compiles-to-it? ls)
    (define rs (attempt (lambda () (fsh->fhir (string-join ls "\n")))))
    (and (pair? rs) (ormap (lambda (r) (equal? r j)) rs)))
  ;; keep-if : lines lines -> lines   the new lines when they still say the resource
  (define (keep-if new old) (if (and (not (equal? new old)) (compiles-to-it? new)) new old))
  (define (rewrite ls from to) (for/list ([l (in-list ls)]) (string-replace l from to)))
  (define profiles (hash-ref (hash-ref j 'meta (hasheq)) 'profile '()))
  (define name (and (= (length profiles) 1) (profile-name (car profiles))))
  (define started
    (and name
         (for/list ([l (in-list (string-split text "\n"))] #:unless (regexp-match? #rx"^[*] meta[.]profile" l))
           (if (regexp-match? #rx"^InstanceOf:" l) (string-append "InstanceOf: " name) l))))
  (cond
    [(not (and started (compiles-to-it? started))) text]
    [else
     ;; entries by slice: `component[0]` as `component[<slice>]`, the first slice that says the same
     (define sliced
       (for*/fold ([ls started]) ([ps (in-list (profile-slices (car profiles)))]
                                  [i (in-range 8)])
         (define from (format "* ~a[~a]" (car ps) i))
         (if (ormap (lambda (l) (string-prefix? l from)) ls)
             (keep-if (rewrite ls from (format "* ~a[~a]" (car ps) (cdr ps))) ls)
             ls)))
     ;; a lone first entry needs no index
     (define unindexed
       (for/fold ([ls sliced]) ([m (in-list (remove-duplicates (append-map (lambda (l) (regexp-match* #px"[A-Za-z.]+\\[0\\]" l)) sliced)))])
         (keep-if (rewrite ls m (substring m 0 (- (string-length m) 3))) ls)))
     (string-join
      (for/fold ([kept unindexed]) ([l (in-list unindexed)] #:when (regexp-match? #rx"^([*] |Usage:)" l))
        (keep-if (remove l kept) kept))
      "\n")]))

;; ---- sizes ---------------------------------------------------------------------------------------

;; forms : Pair -> (list dsl compact indented)
(define (forms p)
  (list (pair*-dsl p) (fhir-json->string (pair*-json p)) (fhir-json->string (pair*-json p) #:indent 2)))

;; sample : (listof Pair) cap -> (listof Pair)   pairs in id order while their indented JSON fits `cap`
(define (sample pairs cap)
  (let loop ([ps (sort pairs string<? #:key pair*-id)] [used 0] [acc '()])
    (cond [(null? ps) (reverse acc)]
          [else (define n (string-length (third (forms (car ps)))))
                (if (and (pair? acc) (> (+ used n) cap)) (reverse acc) (loop (cdr ps) (+ used n) (cons (car ps) acc)))])))

;; input-tokens : command text dir label -> integer | #f   the input tokens the command reports for a prompt
(define (input-tokens cmd text dir label)
  (define (f ext) (build-path dir (string-append label ext)))
  (display-to-file (string-append "Reply with the single word OK. Do not act on the text below.\n\n" text) (f ".prompt.txt") #:exists 'truncate)
  (define-values (_status _secs _timed-out?) (ask cmd (f ".prompt.txt") (f ".answer.txt") (f ".err.txt") 600))
  (define js (attempt (lambda () (string->jsexpr (file->string (f ".answer.txt"))))))
  (define u (and (hash? js) (hash-ref js 'usage #f)))
  (and (hash? u)
       (for/sum ([k (in-list '(input_tokens cache_read_input_tokens cache_creation_input_tokens))])
         (let ([v (hash-ref u k 0)]) (if (real? v) v 0)))))

;; chunks : (listof string) limit -> (listof string)   texts joined, each chunk within `limit` characters
(define (chunks texts limit)
  (let loop ([ts texts] [cur '()] [n 0] [acc '()])
    (cond [(null? ts) (reverse (if (null? cur) acc (cons (string-join (reverse cur) "\n\n") acc)))]
          [(and (pair? cur) (> (+ n (string-length (car ts))) limit)) (loop ts '() 0 (cons (string-join (reverse cur) "\n\n") acc))]
          [else (loop (cdr ts) (cons (car ts) cur) (+ n (string-length (car ts))) acc)])))

;; tokens-of : command (listof string) dir label baseline -> integer | #f
(define (tokens-of cmd texts dir label baseline)
  (for/fold ([total 0]) ([c (in-list (chunks texts 120000))] [i (in-naturals)])
    (define n (and total (input-tokens cmd c dir (format "~a-~a" label i))))
    (and n (+ total (- n baseline)))))

(define (k n) (cond [(not n) "—"] [(>= n 10000) (format "~ak" (round (/ n 1000)))] [else (format "~ak" (/ (round (/ n 100.0)) 10.0))]))
(define (ratio a b) (if (and a b (positive? b)) (format "~a%" (round (* 100.0 (/ a b)))) "—"))
(define (slug s) (regexp-replace* #px"[^a-z]+" (string-downcase s) "-"))

(module+ main
  (define out (make-parameter #f))
  (define count-command (make-parameter #f))
  (define cap (make-parameter 90000))
  (command-line #:program "dsl-sizes"
                #:once-each
                [("--out") d "where the counted prompts and answers are kept" (out d)]
                [("--count") c "a model command that reports its input tokens as Claude Code's JSON" (count-command c)]
                [("--cap") n "characters of indented JSON sampled per kind for the token count" (cap (string->number n))])
  (define dir (or (out) (make-temporary-directory "dsl-sizes-~a")))
  (make-directory* dir)
  (define mcode (spec-package-path "hl7.fhir.us.mcode-4.0.0.tgz"))
  (define ips (spec-package-path "hl7.fhir.uv.ips.tgz"))
  (define core (spec-package-path "hl7.fhir.r4.core.tgz"))
  (define cql-root (collection-path "cql"))
  (define contexts (list ips mcode (spec-package-path "hl7.fhir.us.core-6.1.0.tgz") core))
  ;; profile-name : url -> name | #f   a profile of the two guides by its canonical
  (define profile-name
    (let ([names (for*/hash ([tgz (in-list (list ips mcode))]
                             [e (in-list (let-values ([(_m rs _e) (read-package tgz)]) rs))]
                             #:when (equal? (hash-ref (cdr e) 'resourceType #f) "StructureDefinition"))
                   (values (hash-ref (cdr e) 'url) (hash-ref (cdr e) 'name)))])
      (lambda (url) (hash-ref names (car (string-split url "|")) #f))))
  ;; profile-slices : url -> (listof (cons path slice))   the slices a profile's snapshot names, by
  ;; their element's path under the resource (`component` . `tumorLongestDimension`)
  (define profile-slices
    (let ([slices (for*/hash ([tgz (in-list (list ips mcode))]
                              [e (in-list (let-values ([(_m rs _e) (read-package tgz)]) rs))]
                              #:when (equal? (hash-ref (cdr e) 'resourceType #f) "StructureDefinition"))
                    (values (hash-ref (cdr e) 'url)
                            (for/list ([el (in-list (hash-ref (hash-ref (cdr e) 'snapshot (hasheq)) 'element '()))]
                                       #:when (and (hash-ref el 'sliceName #f)
                                                   (not (regexp-match? #rx":.*[.:]|\\[x\\]" (hash-ref el 'id "")))))
                              (cons (string-join (cdr (string-split (hash-ref el 'path) ".")) ".") (hash-ref el 'sliceName)))))])
      (lambda (url) (hash-ref slices (car (string-split url "|")) '()))))
  (define pairs
    (filter values
            (append
             (parameterize ([current-sd-packages (list ips mcode (spec-package-path "hl7.fhir.us.core-6.1.0.tgz") core)])
               (append (package-pairs ips) (package-pairs mcode)))
             (map-pairs (build-path (collection-path "fml") "tests" "vendor" "matchbox"))
             (append* (for/list ([p (in-list '("fhir.cqf.common-4.0.1" "hl7.fhir.us.cqfmeasures-5.0.0" "hl7.fhir.uv.cql-2.0.0"))])
                        (library-pairs (build-path cql-root "tests" "vendor" "elm-corpus" p)))))))
  (define kinds (remove-duplicates (map pair*-kind pairs)))
  (define baseline (and (count-command) (input-tokens (count-command) "" dir "baseline")))
  (printf "| artifact | pairs | language, chars | JSON compact | JSON indented | language / compact | / indented |")
  (when baseline (printf " sampled | language, tokens | JSON compact | JSON indented | language / compact | / indented |"))
  (printf "\n|---|---|---|---|---|---|---|~a\n" (if baseline "---|---|---|---|---|---|" ""))
  (for ([kind (in-list kinds)])
    (define mine (filter (lambda (p) (equal? (pair*-kind p) kind)) pairs))
    (define (total ps i) (for/sum ([p (in-list ps)]) (string-length (list-ref (forms p) i))))
    (printf "| ~a | ~a | ~a | ~a | ~a | ~a | ~a |" kind (length mine) (k (total mine 0)) (k (total mine 1)) (k (total mine 2))
            (ratio (total mine 0) (total mine 1)) (ratio (total mine 0) (total mine 2)))
    (when baseline
      (define s (sample mine (cap)))
      (define ts (for/list ([i (in-range 3)] [name (in-list '("dsl" "compact" "indented"))])
                   (tokens-of (count-command) (map (lambda (p) (list-ref (forms p) i)) s) dir (format "~a-~a" (slug kind) name) baseline)))
      (printf " ~a | ~a | ~a | ~a | ~a | ~a |" (length s) (k (first ts)) (k (second ts)) (k (third ts))
              (ratio (first ts) (second ts)) (ratio (first ts) (third ts))))
    (newline)
    (flush-output))
  ;; the sampled instances again, with what the language can carry
  (define instances (sample (filter (lambda (p) (equal? (pair*-kind p) "instance")) pairs) (cap)))
  (define plain (map pair*-dsl instances))
  (define own (parameterize ([current-sd-packages contexts] [fsh-fhir-version "4.0.1"])
                (for/list ([p (in-list instances)]) (of-its-profile (pair*-json p) (pair*-dsl p) profile-name profile-slices))))
  (define variants
    (list (cons "FSH as decompiled" plain)
          (cons "FSH, code systems aliased once" (aliased plain))
          (cons "FSH, an instance of its profile (entries by slice, what the profile fixes left out)" own)
          (cons "FSH, of its profile and aliased" (aliased own))
          (cons "JSON compact" (map (lambda (p) (second (forms p))) instances))
          (cons "JSON indented" (map (lambda (p) (third (forms p))) instances))))
  (printf "\nThe ~a sampled instances (~a stated as instances of their profile):\n\n| form | chars |~a\n|---|---|~a\n"
          (length instances) (count (lambda (a b) (not (equal? a b))) plain own)
          (if baseline " tokens | of compact JSON | of indented JSON |" "") (if baseline "---|---|---|" ""))
  (define counted
    (for/list ([v (in-list variants)])
      (list (car v) (for/sum ([t (in-list (cdr v))]) (string-length t))
            (and baseline (tokens-of (count-command) (cdr v) dir (string-append "instances-" (slug (car v))) baseline)))))
  (define (tokens-named n) (third (assoc n counted)))
  (for ([c (in-list counted)])
    (printf "| ~a | ~a |~a\n" (first c) (k (second c))
            (if baseline (format " ~a | ~a | ~a |" (k (third c)) (ratio (third c) (tokens-named "JSON compact")) (ratio (third c) (tokens-named "JSON indented"))) ""))))

(module+ test
  (require rackunit)
  (check-equal? (without-comments "// a\nlibrary X /* y\n z */ version '1'\n\ndefine A: 1 // one\n") "library X  version '1'\ndefine A: 1")
  (check-equal? (chunks '("aaaa" "bbbb" "cc") 9) '("aaaa\n\nbbbb" "cc"))
  (check-equal? (map pair*-id (sample (list (pair* "k" "b" "x" (hasheq 'a 1)) (pair* "k" "a" "x" (hasheq 'a 1))) 5)) '("a"))
  (check-equal? (ratio 1 4) "25.0%")
  (check-equal? (aliased (list "* code = http://loinc.org#1\n* value = http://loinc.org#2" "* code = http://x.org/cs#3"))
                (list "Alias: $loinc = http://loinc.org" "* code = $loinc#1\n* value = $loinc#2" "* code = http://x.org/cs#3")))
