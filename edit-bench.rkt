#lang racket/base

;;; edit-bench.rkt — one change to a published resource, read and answered in FSH or in FHIR JSON.
;;;
;;;   racket edit-bench.rkt --model '<command>' --out <dir> [--tasks n] [--jobs n] [--arms fsh,fsh-rules,json,json-patch]
;;;
;;; The paired test of a language against the representation it compiles to, for INSTANCES: a
;;; model is shown one resource and asked for one change, stated in words; one arm reads and
;;; writes FSH, one reads FSH and answers with the rules that change, one reads and writes JSON,
;;; one reads JSON and answers with a JSON Patch.
;;; One oracle: the resource the change gives, compared whole.
;;;
;;; A Task is (task id resource change expected): `resource` an example of IPS 2.0.1 or mCODE 4.0.0
;;; that the FSH decompiler and compiler round-trip exactly (narrative left out), `change` a Change,
;;; `expected` the resource after it.
;;; A Change is (change kind words apply): one of
;;;   status    its status set to entered-in-error
;;;   date      its one clinical date moved
;;;   note      a note added after those it has
;;;   quantity  its value's number changed, the unit kept
;;; chosen by rotation among those the resource admits, so the mix does not follow the corpus.
;;;
;;; An Arm is (arm name shown block instructions candidate): how the resource is shown, the code
;;; block asked for, and how an answer becomes a resource.
;;;   fsh        shown as FSH (the decompiler's), the whole instance answered
;;;   fsh-rules  shown as FSH, only the rules that change answered; they are laid over the instance
;;;              (compiled after its own rules: a later assignment replaces, `[+]` appends)
;;;   json       shown as compact JSON, the whole resource answered
;;;   json-patch shown as compact JSON, a JSON Patch (RFC 6902) answered and applied: what JSON has
;;;              for "only what changes"
;;; One round, no feedback: what is measured is reading and writing, not repair.
;;; Recorded per task and arm under --out: prompt, answer, and a results.jsonl line; --resume keeps
;;; what is there. The command answers with Claude Code's JSON, whose tokens are recorded.

(require racket/list racket/string racket/file racket/cmdline racket/match json
         (only-in fhir/r4/schemas)
         (only-in fhir/spec-package spec-package-path)
         (only-in fhir/sd/sd-index current-sd-packages)
         (only-in fhir/package read-package)
         (only-in fhir/serialize/fhir-json fhir-json->string)
         (only-in fsh/decompile fhir->fsh)
         (only-in fsh/compile fsh->fhir fsh-fhir-version)
         (only-in fhir/capability/json-patch apply-json-patch)
         "model.rkt")

(struct task (id resource change expected) #:transparent)
(struct change (kind words apply))
(struct arm (name shown block instructions candidate))

;; ---- changes -------------------------------------------------------------------------------------

(define status-types '("Observation" "Procedure" "MedicationRequest" "MedicationStatement" "MedicationAdministration"
                       "Immunization" "DiagnosticReport" "Specimen" "ServiceRequest"))
(define note-types '("Observation" "Condition" "Procedure" "MedicationRequest" "MedicationStatement" "AllergyIntolerance"
                     "Immunization" "Specimen" "FamilyMemberHistory"))
(define date-elements '(effectiveDateTime onsetDateTime performedDateTime occurrenceDateTime authoredOn recordedDate issued))
(define note-text "Reviewed with the patient on 2024-02-29.")

;; changes-of : resource -> (listof Change)   the changes a resource admits
(define (changes-of j)
  (define type (hash-ref j 'resourceType))
  (filter
   values
   (list
    (and (member type status-types) (string? (hash-ref j 'status #f)) (not (equal? (hash-ref j 'status) "entered-in-error"))
         (change "status" "Set its status to entered-in-error." (lambda (j) (hash-set j 'status "entered-in-error"))))
    (for/first ([e (in-list date-elements)] #:when (string? (hash-ref j e #f)))
      (define new (if (<= (string-length (hash-ref j e)) 10) "2024-02-29" "2024-02-29T10:30:00Z"))
      (change "date" (format "Change its `~a` to ~a." e new) (lambda (j) (hash-set j e new))))
    (and (member type note-types)
         (change "note" (format "Add a note with exactly this text, after any notes it has: ~a" note-text)
                 (lambda (j) (hash-set j 'note (append (hash-ref j 'note '()) (list (hasheq 'text note-text)))))))
    (and (hash? (hash-ref j 'valueQuantity #f)) (hash-ref (hash-ref j 'valueQuantity) 'value #f)
         (change "quantity" "Change the number of its value to 42.5; keep the unit."
                 (lambda (j) (hash-set j 'valueQuantity (hash-set (hash-ref j 'valueQuantity) 'value 42.5))))))))

;; ---- tasks ---------------------------------------------------------------------------------------

;; comparable : jsexpr -> jsexpr   numbers as exact, so 42.5 read from JSON equals 42.5 compiled
(define (comparable j)
  (cond [(hash? j) (for/hasheq ([(k v) (in-hash j)]) (values k (comparable v)))]
        [(list? j) (map comparable j)]
        [(real? j) (inexact->exact j)]
        [else j]))

;; compiled : fsh-text id -> resource | #f   the resource of that id the text compiles to
(define (compiled text id)
  (define rs (with-handlers ([exn:fail? (lambda (_) '())]) (fsh->fhir text)))
  (findf (lambda (r) (equal? (hash-ref r 'id #f) id)) rs))

;; tasks-from : (listof tgz) n -> (listof Task)   n tasks over the packages' examples, kinds in rotation
(define (tasks-from packages n)
  (define candidates
    (for*/list ([tgz (in-list packages)]
                [e (in-list (let-values ([(_m _r examples) (read-package tgz)]) examples))]
                #:unless (member (hash-ref (cdr e) 'resourceType #f) '("Bundle" "ImplementationGuide"))
                #:when (pair? (changes-of (cdr e))))
      (hash-remove (cdr e) 'text)))
  (define sorted (sort (remove-duplicates candidates #:key (lambda (j) (hash-ref j 'id ""))) string<?
                       #:key (lambda (j) (hash-ref j 'id ""))))
  ;; spread over the corpus: every k-th, then only those the languages round-trip
  (define step (max 1 (quotient (length sorted) (* 2 n))))
  (define spread (for/list ([j (in-list sorted)] [i (in-naturals)] #:when (zero? (modulo i step))) j))
  (define kinds '("status" "date" "note" "quantity"))
  (let loop ([js spread] [i 0] [acc '()])
    (cond [(or (null? js) (= (length acc) n)) (reverse acc)]
          [else
           (define j (car js))
           (define cs (changes-of j))
           (define wanted (list-ref kinds (modulo i (length kinds))))
           (define c (or (findf (lambda (c) (equal? (change-kind c) wanted)) cs) (car cs)))
           (define text (with-handlers ([exn:fail? (lambda (_) #f)]) (fhir->fsh j)))
           (define expected ((change-apply c) j))
           ;; the task is fair only when FSH can say both the resource and its changed form
           (define fair? (and text
                              (equal? (comparable (compiled text (hash-ref j 'id))) (comparable j))
                              (let ([t2 (with-handlers ([exn:fail? (lambda (_) #f)]) (fhir->fsh expected))])
                                (and t2 (equal? (comparable (compiled t2 (hash-ref j 'id))) (comparable expected))))))
           (if fair?
               (loop (cdr js) (add1 i) (cons (task (hash-ref j 'id) j c expected) acc))
               (loop (cdr js) i acc))])))

;; ---- arms ----------------------------------------------------------------------------------------

(define (fsh-shown j) (fhir->fsh j))

(define arms
  (list
   (arm "fsh" fsh-shown "fsh"
        "Below is a FHIR resource written in FHIR Shorthand (FSH). Reply with the whole updated instance, in FSH, in ONE ```fsh code block."
        (lambda (t answer) (compiled answer (task-id t))))
   (arm "fsh-rules" fsh-shown "fsh"
        (string-append "Below is a FHIR resource written in FHIR Shorthand (FSH). Reply with ONLY the FSH rules that change it "
                       "(lines starting with `*`), in ONE ```fsh code block. They are applied after the instance's own rules: "
                       "a rule assigning an element replaces its value, and `[+]` adds an entry to a list.")
        (lambda (t answer)
          (compiled (if (regexp-match? #px"(?m:^Instance:)" answer)
                        answer
                        (string-append (fsh-shown (task-resource t)) "\n" answer))
                    (task-id t))))
   (arm "json" (lambda (j) (fhir-json->string j)) "json"
        "Below is a FHIR resource as JSON. Reply with the whole updated resource, as JSON, in ONE ```json code block."
        (lambda (t answer) (with-handlers ([exn:fail? (lambda (_) #f)])
                             (let ([j (string->jsexpr answer)]) (and (hash? j) j)))))
   (arm "json-patch" (lambda (j) (fhir-json->string j)) "json"
        (string-append "Below is a FHIR resource as JSON. Reply with ONLY a JSON Patch (RFC 6902: a JSON array of operations) "
                       "that changes it, in ONE ```json code block.")
        (lambda (t answer) (with-handlers ([exn:fail? (lambda (_) #f)])
                             (let ([ops (string->jsexpr answer)])
                               (and (list? ops) (apply-json-patch (task-resource t) ops))))))))

;; prompt : Task Arm -> string
(define (prompt t a)
  (format "~a\n\nMake this one change and nothing else: ~a\n\n```~a\n~a\n```\n"
          (arm-instructions a) (change-words (task-change t)) (arm-block a) ((arm-shown a) (task-resource t))))

;; ---- running and scoring -------------------------------------------------------------------------

;; usage : answer-file -> (values text tokens)   Claude Code's JSON unwrapped: the result and its tokens
(define (usage file)
  (define js (with-handlers ([exn:fail? (lambda (_) #f)]) (string->jsexpr (file->string file))))
  (define u (and (hash? js) (hash-ref js 'usage #f)))
  (define (n k) (let ([v (and (hash? u) (hash-ref u k 0))]) (if (real? v) v 0)))
  (define details (let ([d (and (hash? u) (hash-ref u 'output_tokens_details #f))]) (if (hash? d) d (hasheq))))
  (values (if (and (hash? js) (string? (hash-ref js 'result #f))) (hash-ref js 'result) "")
          (hasheq 'input (+ (n 'input_tokens) (n 'cache_read_input_tokens) (n 'cache_creation_input_tokens))
                  'output (n 'output_tokens)
                  'thinking (let ([v (hash-ref details 'thinking_tokens 0)]) (if (real? v) v 0)))))

;; first-difference : jsexpr jsexpr [path] -> string | #f   where two values first differ
(define (first-difference a b [path ""])
  (cond [(equal? a b) #f]
        [(and (hash? a) (hash? b))
         (or (for/or ([k (in-list (sort (remove-duplicates (append (hash-keys a) (hash-keys b))) symbol<?))])
               (cond [(not (hash-has-key? b k)) (format "~a.~a missing" path k)]
                     [(not (hash-has-key? a k)) (format "~a.~a added" path k)]
                     [else (first-difference (hash-ref a k) (hash-ref b k) (format "~a.~a" path k))]))
             path)]
        [(and (list? a) (list? b) (= (length a) (length b)))
         (for/or ([x (in-list a)] [y (in-list b)] [i (in-naturals)]) (first-difference x y (format "~a[~a]" path i)))]
        [else (format "~a: expected ~a, got ~a" path (jsexpr->string a) (if (void? b) "nothing" (jsexpr->string b)))]))

;; ask-one : command dir Task Arm -> void   the model's answer to one task in one arm, in files
(define (ask-one cmd dir t a)
  (define (f ext) (build-path dir (format "~a.~a~a" (task-id t) (arm-name a) ext)))
  (unless (and (file-exists? (f ".answer.json")) (positive? (file-size (f ".answer.json"))))
    (display-to-file (prompt t a) (f ".prompt.md") #:exists 'truncate)
    (ask cmd (f ".prompt.md") (f ".answer.json") (f ".err.txt") 600)
    (void)))

;; scored : dir Task Arm baseline -> hash
(define (scored dir t a baseline)
  (define file (build-path dir (format "~a.~a.answer.json" (task-id t) (arm-name a))))
  (define-values (text tokens) (usage file))
  (define block (extract-block text (arm-block a)))
  (define got ((arm-candidate a) t block))
  (define diff (if got (first-difference (comparable (task-expected t)) (comparable got)) "no resource in the answer"))
  (hasheq 'task (task-id t) 'arm (arm-name a) 'kind (change-kind (task-change t))
          'correct (not diff) 'difference (or diff "")
          'prompt_tokens (max 0 (- (hash-ref tokens 'input) baseline))
          'output_tokens (hash-ref tokens 'output) 'thinking_tokens (hash-ref tokens 'thinking)
          'answer_chars (string-length block)))

;; in-parallel : (listof (-> any)) jobs -> void
(define (in-parallel thunks jobs)
  (define queue (make-channel))
  (define workers (for/list ([_ (in-range jobs)])
                    (thread (lambda () (let loop () (define t (channel-get queue)) (when t (t) (loop)))))))
  (for ([t (in-list thunks)]) (channel-put queue t))
  (for ([_ (in-list workers)]) (channel-put queue #f))
  (for-each thread-wait workers))

(define (mean xs) (if (null? xs) 0 (/ (apply + xs) (length xs))))
(define (one x) (number->string (/ (round (* 10.0 x)) 10.0)))

;; report : (listof hash) (listof string) -> void
(define (report rows arm-names)
  (define (of name) (filter (lambda (r) (equal? (hash-ref r 'arm) name)) rows))
  (printf "| arm | correct | prompt tokens / task | answer tokens / task | thinking tokens / task | answer chars / task |\n|---|---|---|---|---|---|\n")
  (for ([name (in-list arm-names)])
    (define mine (of name))
    (printf "| ~a | ~a/~a | ~a | ~a | ~a | ~a |\n" name (count (lambda (r) (hash-ref r 'correct)) mine) (length mine)
            (one (mean (map (lambda (r) (hash-ref r 'prompt_tokens)) mine)))
            (one (mean (map (lambda (r) (- (hash-ref r 'output_tokens) (hash-ref r 'thinking_tokens))) mine)))
            (one (mean (map (lambda (r) (hash-ref r 'thinking_tokens)) mine)))
            (one (mean (map (lambda (r) (hash-ref r 'answer_chars)) mine)))))
  (printf "\n| change | ~a |\n|---|~a\n" (string-join arm-names " | ") (string-join (map (lambda (_) "---|") arm-names) ""))
  (for ([kind (in-list (remove-duplicates (map (lambda (r) (hash-ref r 'kind)) rows)))])
    (printf "| ~a | ~a |\n" kind
            (string-join (for/list ([name (in-list arm-names)])
                           (define mine (filter (lambda (r) (equal? (hash-ref r 'kind) kind)) (of name)))
                           (format "~a/~a" (count (lambda (r) (hash-ref r 'correct)) mine) (length mine)))
                         " | ")))
  (define wrong (filter (lambda (r) (not (hash-ref r 'correct))) rows))
  (unless (null? wrong)
    (printf "\nWrong answers:\n\n")
    (for ([r (in-list wrong)])
      (printf "- ~a, ~a (~a): ~a\n" (hash-ref r 'arm) (hash-ref r 'task) (hash-ref r 'kind) (hash-ref r 'difference)))))

(module+ main
  (define model (make-parameter #f))
  (define out (make-parameter #f))
  (define n (make-parameter 60))
  (define jobs (make-parameter 6))
  (define chosen (make-parameter '("fsh" "fsh-rules" "json" "json-patch")))
  (command-line #:program "edit-bench"
                #:once-each
                [("--model") c "the model command (answers with Claude Code's JSON)" (model c)]
                [("--out") d "the directory of the run (kept: a second run resumes it)" (out d)]
                [("--tasks") k "how many tasks" (n (string->number k))]
                [("--jobs") k "how many answers are asked for at once" (jobs (string->number k))]
                [("--arms") s "arms, comma-separated" (chosen (string-split s ","))])
  (unless (and (model) (out)) (raise-user-error 'edit-bench "--model and --out are required"))
  (make-directory* (out))
  (define packages (list (spec-package-path "hl7.fhir.uv.ips.tgz") (spec-package-path "hl7.fhir.us.mcode-4.0.0.tgz")))
  (parameterize ([current-sd-packages (append packages (list (spec-package-path "hl7.fhir.us.core-6.1.0.tgz")
                                                             (spec-package-path "hl7.fhir.r4.core.tgz")))]
                 [fsh-fhir-version "4.0.1"])
    (define tasks (tasks-from packages (n)))
    (define mine (filter (lambda (a) (member (arm-name a) (chosen))) arms))
    (eprintf "~a tasks, ~a arms\n" (length tasks) (length mine))
    ;; the tokens of an empty prompt, taken off every prompt's
    (define base-file (build-path (out) "baseline.answer.json"))
    (unless (file-exists? base-file)
      (display-to-file "Reply with the single word OK." (build-path (out) "baseline.prompt.md") #:exists 'truncate)
      (ask (model) (build-path (out) "baseline.prompt.md") base-file (build-path (out) "baseline.err.txt") 600))
    (define-values (_t base) (usage base-file))
    (in-parallel (for*/list ([t (in-list tasks)] [a (in-list mine)]) (lambda () (ask-one (model) (out) t a))) (jobs))
    (define rows (for*/list ([t (in-list tasks)] [a (in-list mine)]) (scored (out) t a (hash-ref base 'input))))
    (call-with-output-file (build-path (out) "results.jsonl") #:exists 'truncate
      (lambda (o) (for ([r (in-list rows)]) (write-json r o) (newline o))))
    (report rows (map arm-name mine))))

(module+ test
  (require rackunit)
  (define obs (hasheq 'resourceType "Observation" 'id "o1" 'status "final" 'effectiveDateTime "2020-01-01"
                      'valueQuantity (hasheq 'value 1.5 'unit "cm")))
  (check-equal? (map change-kind (changes-of obs)) '("status" "date" "note" "quantity"))
  (check-equal? (hash-ref ((change-apply (second (changes-of obs))) obs) 'effectiveDateTime) "2024-02-29")
  (check-equal? (hash-ref ((change-apply (third (changes-of obs))) obs) 'note) (list (hasheq 'text note-text)))
  (check-false (first-difference (comparable obs) (comparable (hash-set obs 'valueQuantity (hasheq 'value 3/2 'unit "cm")))))
  (check-equal? (first-difference obs (hash-set obs 'status "amended")) ".status: expected \"final\", got \"amended\"")
  (check-equal? (first-difference obs (hash-remove obs 'status)) ".status missing")
  (check-equal? (map change-kind (changes-of (hasheq 'resourceType "Patient" 'id "p"))) '()))
