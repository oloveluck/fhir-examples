#lang racket/base

;;; bench.rkt — how well does a spec author (a model) turn FHIR prose into a working FSH spec?
;;;
;;; A TASK is a real IG with one profile taken out: the profile's FSH and its example instances are
;;; removed from the IG's own sources, and the prompt gives what the IG publishes ABOUT the profile in
;;; words (its description and purpose, and each constrained element's short / definition / comment
;;; from the published StructureDefinition) — never the constraints themselves (cardinality, types,
;;; bindings, fixed/pattern values, slicing). It does name WHICH elements the profile constrains:
;;; the stand-in for an IG's "key elements" page, and stated as such in every report.
;;;
;;; A CANDIDATE (FSH text: the profile and at least one example) is scored against the published IG,
;;; four ways, all by tools in this repo:
;;;   check     — `fsh check` errors in the candidate (compile, rule-level, its examples vs its profile)
;;;   fidelity  — facet agreement of the compiled profile with the PUBLISHED profile's differential
;;;               (min, max, mustSupport, types + profiles, binding, fixed/pattern, slicing, slices),
;;;               per published element; extra constrained elements are counted separately
;;;   accepts   — the IG's own published examples of that profile, validated against the CANDIDATE's
;;;               profile (a profile that rejects them is wrong)
;;;   conforms  — the candidate's examples, validated against the PUBLISHED profile
;;; Baselines: `oracle` (the IG's own FSH for the profile, through our compiler — the ceiling the
;;; toolchain allows) and `empty`.
;;;
;;; `run` asks a model through any shell command (prompt on stdin, answer on stdout; the answer's
;;; last ```fsh block is the candidate) for up to N rounds: after a round with check errors, the next
;;; prompt carries the previous FSH and the positioned diagnostics — the spec-driven loop, measured.

(require racket/contract racket/list racket/string racket/file racket/port racket/match
         json
         (only-in fhir/diagnostic diagnostic-severity diagnostic-loc diagnostic-message loc-source loc-line loc-column
                  emit-diagnostics)
         (only-in fhir/sd/sd-index current-sd-packages)
         (only-in fhir/spec-package spec-package-path)
         (only-in fhir/conformance/validate validate-issues issue-severity issue-path issue-msg)
         (only-in fhir/serialize/read-json strip-jnum)
         (only-in fhir/package read-package)
         fsh/check
         (only-in "model.rkt" ask extract-block)
         (only-in fsh/project compile-project project-located project-texts find-config fsh-files)
         (only-in fsh/ig-config read-ig-config ig-config-canonical ig-config-dependencies ig-config-fhir-version
                  ig-config-title ig-config-name dependency-packages)
         (only-in fsh/pack pack-package!)
         (only-in fsh/parser/ast fsh-profile? fsh-profile-name fsh-profile-metadata
                  fsh-extension? fsh-valueset? fsh-codesystem? fsh-alias? fsh-alias-name fsh-alias-value
                  fsh-instance? fsh-instance-name fsh-instance-metadata
                  fsh-extension-name fsh-valueset-name fsh-codesystem-name))

(provide
 (contract-out
  [list-tasks  (-> path-string? (listof (list/c string? string? exact-nonnegative-integer?)))]
  [make-task!  (-> path-string? path-string? string? path-string? path?)]
  [score-task  (-> path-string? string? hash?)]
  [run-task!   (->* (path-string? string?) (#:rounds exact-positive-integer? #:timeout (and/c real? positive?)) (listof hash?))]
  ;; a published package by path, file name in fhir-spec, or package name (`hl7.fhir.us.mcode-4.0.0`)
  [published-package (-> string? path?)]))

(define (published-package s)
  (cond [(file-exists? s) (path->complete-path s)]
        [(spec-package-path (if (regexp-match? #rx"[.]tgz$" s) s (string-append s ".tgz")) #:optional? #t) => values]
        [else (raise-user-error 'spec-bench "no package ~a (a path, or a file in fhir-spec)" s)]))

;; ---- tasks ------------------------------------------------------------------------------------------
;; A task directory holds: project/ (the IG minus the profile), prompt.md, task.rktd:
;;   (hash 'ig <dir> 'published <tgz> 'profile <name> 'id <id> 'url <canonical> 'oracle <fsh text>
;;         'removed (names…))

;; list-tasks : ig-dir -> (listof (list profile-name id examples))   the profiles that can be taken
;; out alone: no other local profile derives from them
(define (list-tasks ig)
  (define located (project-located (compile-project ig)))
  (define profiles (for/list ([l (in-list located)] #:when (fsh-profile? (car l))) (car l)))
  (define parents (for/list ([p (in-list profiles)]) (meta p 'parent)))
  (for/list ([p (in-list profiles)]
             #:unless (or (member (fsh-profile-name p) parents) (member (profile-id p) parents)))
    (list (fsh-profile-name p) (profile-id p) (length (instances-of located p)))))

(define (meta e k) (let ([m (assoc k (if (fsh-profile? e) (fsh-profile-metadata e) (fsh-instance-metadata e)))]) (and m (cdr m))))
(define (profile-id p) (or (meta p 'id) (fsh-profile-name p)))
(define (instances-of located p)
  (for/list ([l (in-list located)]
             #:when (and (fsh-instance? (car l)) (member (meta (car l) 'instanceOf) (list (fsh-profile-name p) (profile-id p)))))
    (car l)))

;; make-task! : ig-dir published.tgz profile-name out-dir -> out-dir
(define (make-task! ig published name out)
  (define p (compile-project ig))
  (define located (project-located p))
  (define prof (or (for/first ([l (in-list located)] #:when (and (fsh-profile? (car l)) (equal? (fsh-profile-name (car l)) name))) (car l))
                   (raise-user-error 'spec-bench "no profile named ~a" name)))
  (define removed (cons prof (instances-of located prof)))
  (define cfg (read-ig-config (find-config ig)))
  (define url (format "~a/StructureDefinition/~a" (ig-config-canonical cfg) (profile-id prof)))
  ;; each removed entity's text: from its header to the next entity in the same file
  (define spans (entity-spans located (project-texts p)))
  (define oracle (string-join (for/list ([e (in-list removed)]) (hash-ref spans e)) "\n"))
  (when (directory-exists? out) (delete-directory/files out))
  (make-directory* out)
  (copy-directory/files ig (build-path out "project"))
  (for ([f (in-list (fsh-files (build-path out "project")))])
    (define original (file->string f))
    (define kept (for/fold ([t original]) ([e (in-list removed)]) (string-replace t (hash-ref spans e) "" #:all? #f)))
    (unless (equal? kept original) (call-with-output-file f #:exists 'truncate (lambda (o) (write-string kept o)))))
  (define published-sd (or (for/first ([r (in-list (let-values ([(_m rs _e) (read-package published)]) rs))]
                                       #:when (equal? (hash-ref (cdr r) 'url #f) url))
                             (cdr r))
                           (raise-user-error 'spec-bench "~a is not in ~a" url published)))
  (call-with-output-file (build-path out "prompt.md")
    (lambda (o) (write-string (prompt-text cfg prof url published-sd located removed) o)))
  (call-with-output-file (build-path out "task.rktd")
    (lambda (o) (write (hash 'ig (path->string (path->complete-path ig)) 'published (path->string (path->complete-path published))
                             'profile name 'id (profile-id prof) 'url url 'oracle oracle
                             'removed (map entity-name removed))
                       o)))
  (path->complete-path out))

(define (entity-name e) (if (fsh-profile? e) (fsh-profile-name e) (fsh-instance-name e)))

;; entity-spans : located texts -> (hash entity -> its source text)
(define (entity-spans located texts)
  (define by-file (group-by (lambda (l) (loc-source (cdr l))) located))
  (for*/hash ([ls (in-list by-file)]
              [sorted (in-value (sort ls < #:key (lambda (l) (loc-line (cdr l)))))]
              [(l i) (in-indexed sorted)])
    (define lines (string-split (hash-ref texts (loc-source (cdr l))) "\n" #:trim? #f))
    (define from (sub1 (loc-line (cdr l))))
    (define to (if (< (add1 i) (length sorted)) (sub1 (loc-line (cdr (list-ref sorted (add1 i))))) (length lines)))
    (values (car l) (string-join (take (drop lines from) (- to from)) "\n"))))

;; prompt-text : … -> string   the task in words
(define (prompt-text cfg prof url sd located removed)
  (define (txt e k) (let ([v (hash-ref e k #f)]) (and (string? v) (string-normalize-spaces v))))
  (define elements (hash-ref (hash-ref sd 'differential (hash)) 'element '()))
  (define names
    (for/list ([l (in-list located)] #:unless (memq (car l) removed)
               #:when (or (fsh-profile? (car l)) (fsh-extension? (car l)) (fsh-valueset? (car l)) (fsh-codesystem? (car l))))
      (define e (car l))
      (format "~a ~a" (cond [(fsh-profile? e) "Profile"] [(fsh-extension? e) "Extension"] [(fsh-valueset? e) "ValueSet"] [else "CodeSystem"])
              (cond [(fsh-profile? e) (fsh-profile-name e)] [(fsh-extension? e) (fsh-extension-name e)]
                    [(fsh-valueset? e) (fsh-valueset-name e)] [else (fsh-codesystem-name e)]))))
  (define aliases (for/list ([l (in-list located)] #:when (fsh-alias? (car l)))
                    (format "Alias: ~a = ~a" (fsh-alias-name (car l)) (fsh-alias-value (car l)))))
  (string-append
   (format "# Task: write one FHIR Shorthand (FSH) profile for ~a\n\n" (or (ig-config-title cfg) (ig-config-name cfg) "this IG"))
   (format "The IG targets FHIR ~a and depends on: ~a. Its canonical is ~a.\n\n"
           (ig-config-fhir-version cfg)
           (string-join (for/list ([d (in-list (ig-config-dependencies cfg))]) (format "~a#~a" (car d) (cdr d))) ", ")
           (ig-config-canonical cfg))
   (format "Write `Profile: ~a` with `Id: ~a` (its url will be ~a), and at least one example `Instance` of it "
           (fsh-profile-name prof) (profile-id prof) url)
   "that is valid against it. Use the IG's existing names below where they fit. Reply with ONE ```fsh code block holding all of it.\n\n"
   "## What the IG says about this profile\n\n"
   (format "~a\n\n" (or (txt sd 'description) ""))
   (if (txt sd 'purpose) (format "Purpose: ~a\n\n" (txt sd 'purpose)) "")
   "## The elements it constrains, in the IG's words\n\n"
   "(The IG's published element descriptions; deciding the constraints is the task.)\n\n"
   ;; EVERY element the profile constrains (an element without published text is still named:
   ;; leaving it out hid, e.g., that TumorSize fixes Observation.code)
   (apply string-append
          (for/list ([e (in-list elements)] #:when (pair? (facets e)))
            (format "- `~a`: ~a~a~a\n" (hash-ref e 'id) (or (txt e 'short) "(no description published)")
                    (if (and (txt e 'definition) (not (equal? (txt e 'definition) (txt e 'short)))) (format " — ~a" (txt e 'definition)) "")
                    (if (txt e 'comment) (format " (~a)" (txt e 'comment)) ""))))
   "\n## Names already defined in this IG\n\n"
   (string-join aliases "\n") "\n\n" (string-join names "\n") "\n"))

;; ---- scoring --------------------------------------------------------------------------------------
(define (read-task dir) (call-with-input-file (build-path dir "task.rktd") read))

;; score-task : task-dir candidate-fsh -> (hash …)
(define (score-task dir candidate)
  (define t (read-task dir))
  (define url (hash-ref t 'url))
  (define work (make-temporary-directory "spec-bench-~a"))
  (define proj (build-path work "project"))
  (copy-directory/files (build-path dir "project") proj)
  (define cand-file (build-path proj "input" "fsh" "zz-candidate.fsh"))
  (make-directory* (build-path proj "input" "fsh"))
  (call-with-output-file cand-file (lambda (o) (write-string candidate o)))
  (define r (check-fsh-project proj))
  (define in-candidate
    (for/list ([d (in-list (check-report-diagnostics r))]
               #:when (let ([l (diagnostic-loc d)]) (and l (string? (loc-source l)) (string-suffix? (loc-source l) "zz-candidate.fsh"))))
      d))
  (define errors (for/sum ([d (in-list (check-report-diagnostics r))]) (if (eq? (diagnostic-severity d) 'error) 1 0)))
  (define artifacts (check-report-artifacts r))
  (define cand-sd (findf (lambda (a) (and (equal? (hash-ref a 'resourceType #f) "StructureDefinition") (equal? (hash-ref a 'url #f) url))) artifacts))
  (define published (hash-ref t 'published))
  (define pub-sd (for/first ([x (in-list (let-values ([(_m rs _e) (read-package published)]) rs))] #:when (equal? (hash-ref (cdr x) 'url #f) url)) (cdr x)))
  (define-values (fid-ok fid-total extra) (fidelity pub-sd cand-sd))
  ;; the packages: the IG's dependencies and core
  (define cfg (read-ig-config (find-config proj)))
  (define-values (deps _missing) (dependency-packages (ig-config-dependencies cfg)))
  (define core (spec-package-path (if (regexp-match? #rx"^4" (ig-config-fhir-version cfg)) "hl7.fhir.r4.core.tgz" "hl7.fhir.r5.core.tgz")))
  (define (claims? js) (let ([m (hash-ref js 'meta #f)]) (and (hash? m) (member url (hash-ref m 'profile '())) #t)))
  (define rejections '())                            ; why examples failed: (file-or-id path message)
  (define (errors-of js [label (hash-ref js 'id "?")])
    (define es (for/list ([i (in-list (validate-issues (strip-jnum js)))] #:when (member (issue-severity i) '("error" "fatal"))) i))
    (for ([i (in-list (take es (min 3 (length es))))])
      (set! rejections (cons (format "~a: ~a ~a" label (issue-path i) (issue-msg i)) rejections)))
    (length es))
  ;; accepts: the IG's published examples of this profile against the candidate's profile
  (define pub-examples (for/list ([x (in-list (let-values ([(_m _r xs) (read-package published)]) xs))] #:when (claims? (cdr x))) (cdr x)))
  (define own (build-path work "candidate.tgz"))
  (pack-package! own cfg artifacts (hash))
  (define accepted
    (if cand-sd
        (parameterize ([current-sd-packages (append (list own) deps (list core))])
          (for/sum ([x (in-list pub-examples)]) (if (zero? (errors-of x)) 1 0)))
        0))
  ;; conforms: the candidate's examples against the published profile
  (define cand-examples (filter (lambda (a) (and (string? (hash-ref a 'resourceType #f)) (not (equal? (hash-ref a 'resourceType) "StructureDefinition")) (claims? a))) artifacts))
  (define conforming
    (parameterize ([current-sd-packages (append (list published) deps (list core))])
      (for/sum ([x (in-list cand-examples)]) (if (zero? (errors-of x (format "candidate ~a" (hash-ref x 'id "?")))) 1 0))))
  (define diag-text (with-output-to-string
                      (lambda () (parameterize ([current-error-port (current-output-port)])
                                   (emit-diagnostics in-candidate #:format 'text
                                                     #:text-of (lambda (s) (and s (hash-ref (check-report-texts r) s #f))))))))
  (delete-directory/files work #:must-exist? #f)
  (hasheq 'task (hash-ref t 'profile)
          'check_errors errors
          'candidate_diagnostics (length in-candidate)
          'profile_compiled (and cand-sd #t)
          'fidelity (list fid-ok fid-total)
          'extra_constrained_elements extra
          'accepts_published_examples (list accepted (length pub-examples))
          'examples_conform_to_published (list conforming (length cand-examples))
          'rejections (reverse rejections)
          'diagnostics_text (string-replace diag-text (path->string proj) "")))

;; ---- fidelity: facets of a differential element -----------------------------------------------------
;; fidelity : published-sd candidate-sd|#f -> (values matched total extra)
(define (fidelity pub cand)
  (define pub-els (if pub (hash-ref (hash-ref pub 'differential (hash)) 'element '()) '()))
  (define cand-els (if cand (for/hash ([e (in-list (hash-ref (hash-ref cand 'differential (hash)) 'element '()))]) (values (hash-ref e 'id) e)) (hash)))
  (define-values (ok total)
    (for*/fold ([ok 0] [total 0]) ([e (in-list pub-els)] [f (in-list (facets e))])
      (define c (hash-ref cand-els (hash-ref e 'id) #f))
      (values (if (and c (member f (facets c))) (add1 ok) ok) (add1 total))))
  (define pub-ids (map (lambda (e) (hash-ref e 'id)) pub-els))
  (define extra (for/sum ([(id e) (in-hash cand-els)]) (if (or (member id pub-ids) (null? (facets e))) 0 1)))
  (values ok total extra))

;; facets : element -> (listof (cons name value))   the constraints, normalised (versions dropped from
;; canonicals, type lists sorted); text (short/definition/comment) is not a constraint
(define (facets e)
  (define (unver u) (if (string? u) (regexp-replace #rx"[|].*$" u "") u))
  (append
   (for/list ([k (in-list '(min max mustSupport sliceName))] #:when (hash-has-key? e k)) (cons k (hash-ref e k)))
   (if (pair? (hash-ref e 'type '()))
       (list (cons 'type (sort (for/list ([t (in-list (hash-ref e 'type))])
                                 (format "~a ~a ~a" (hash-ref t 'code "") (map unver (hash-ref t 'profile '()))
                                         (sort (map unver (hash-ref t 'targetProfile '())) string<?)))
                               string<?)))
       '())
   (let ([b (hash-ref e 'binding #f)])
     (if (and (hash? b) (hash-ref b 'valueSet #f)) (list (cons 'binding (list (hash-ref b 'strength #f) (unver (hash-ref b 'valueSet))))) '()))
   (for/list ([(k v) (in-hash e)] #:when (regexp-match? #rx"^(fixed|pattern)" (symbol->string k))) (cons k v))
   (let ([s (hash-ref e 'slicing #f)])
     (if (hash? s) (list (cons 'slicing (list (hash-ref s 'discriminator '()) (hash-ref s 'rules #f)))) '()))))

;; ---- running a model ---------------------------------------------------------------------------------
;; run-task! : task-dir shell-command [#:rounds n #:timeout s] -> (listof score)
;; Each run gets runs/<stamp>/ with round-N.prompt.md, round-N.answer.txt, round-N.err.txt and
;; round-N.fsh; every round's score (with seconds, exit code, timeout) is appended to results.jsonl.
;; Rounds stop when the candidate checks clean, the model times out or fails, or at `rounds`.
(define (run-task! dir cmd #:rounds [rounds 3] #:timeout [timeout 1200])
  (define base (file->string (build-path dir "prompt.md")))
  (define run-dir (build-path dir "runs" (number->string (current-seconds))))
  (make-directory* run-dir)
  (let loop ([round 1] [prompt base] [acc '()])
    (define (file ext) (build-path run-dir (format "round-~a.~a" round ext)))
    (call-with-output-file (file "prompt.md") (lambda (o) (write-string prompt o)))
    (define-values (code seconds timed-out?) (ask cmd (file "prompt.md") (file "answer.txt") (file "err.txt") timeout))
    (define fsh (extract-block (file->string (file "answer.txt")) "fsh"))
    (call-with-output-file (file "fsh") (lambda (o) (write-string fsh o)))
    (define answered? (and (eqv? code 0) (not timed-out?) (positive? (string-length (string-trim fsh)))))
    (define s (hash-set* (if answered? (score-task dir fsh) (hasheq 'task (hash-ref (read-task dir) 'profile)))
                         'round round 'model_command cmd 'seconds seconds 'exit_code code
                         'timed_out timed-out? 'answered answered? 'run (path->string run-dir)))
    (call-with-output-file (build-path dir "results.jsonl") #:exists 'append
      (lambda (o) (write-json (hash-set s 'candidate fsh) o) (newline o)))
    (define acc* (append acc (list s)))
    (if (or (not answered?) (= round rounds) (zero? (hash-ref s 'candidate_diagnostics)))
        acc*
        (loop (add1 round)
              (string-append base "\n\n## Your previous answer\n\n```fsh\n" fsh "\n```\n\n"
                             "## `fsh check` reported (zz-candidate.fsh is your answer)\n\n```\n" (hash-ref s 'diagnostics_text) "```\n\n"
                             "Fix these and reply with the complete corrected FSH in ONE ```fsh block.\n")
              acc*))))

(module+ test
  (require rackunit)
  ;; facets ignore text and canonical versions
  (check-equal? (facets (hasheq 'id "O.code" 'short "x" 'min 1 'binding (hasheq 'strength "required" 'valueSet "http://v|1.0")))
                (list (cons 'min 1) (cons 'binding (list "required" "http://v"))))
  (define-values (ok total extra)
    (fidelity (hasheq 'differential (hasheq 'element (list (hasheq 'id "O.a" 'min 1 'max "1") (hasheq 'id "O.b" 'mustSupport #t))))
              (hasheq 'differential (hasheq 'element (list (hasheq 'id "O.a" 'min 1) (hasheq 'id "O.c" 'max "0"))))))
  (check-equal? (list ok total extra) '(1 3 1)))
