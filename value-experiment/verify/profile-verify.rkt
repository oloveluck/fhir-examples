#lang racket/base

;;; profile-verify.rkt — experiment V-profile of value-experiment/PROTOCOL.md: implementations of
;;; "is this resource valid against the profile?" written by independent agents from the profile's
;;; published definition, then each checked and corrected by an agent that has the definition alone
;;; (R), HL7's validator's verdicts for the sample resources (T), or the definition executed as an
;;; oracle on any resource (O) — and held to HL7's validator's verdicts on resources none of them
;;; saw, before and after.
;;;
;;;   racket profile-verify.rkt build OUT [--only id,id] [--parallel 6] [--model M] [--resume]
;;;   racket profile-verify.rkt run OUT [--arms R,T,O] [--only id,id] [--parallel 6] [--model M] [--resume]
;;;   racket profile-verify.rkt score OUT     every implementation, as built and as each session left it
;;;   racket profile-verify.rkt report OUT    the comparison the protocol states
;;;   racket profile-verify.rkt changes OUT   each held-out verdict a session fixed or broke
;;;
;;; Data definitions.
;;; A Start is a string, "<profile's short name>-<i>": the i-th implementation of a profile. Its
;;;   build session's directory is OUT/<start>-B, an arm's check session's OUT/<start>-<arm>.
;;; An Arm is 'R | 'T | 'O.  A Rights is (hash case boolean): held-out cases, right or not.
;;; A Check is verify.rkt's `review` (start profile 'P before after cost belief), so its analysis
;;;   (shares, fixed and broken, the paired bootstrap, the label swap) is the one V-measure uses.

(require racket/file racket/list racket/string racket/math racket/port racket/runtime-path json
         "profile-cases.rkt" "profile-materials.rkt"
         (only-in "verify.rkt" review review-start review-measure review-before review-after review-cost review-belief
                  share-after share-before fixed broken difference bootstrap-difference sign-flip-p)
         (only-in "../analysis.rkt" verdict-of interval)
         (only-in "../../agent-bench/run-agent.rkt" run-item in-parallel audit current-resume? read-json-file write-json-file))

(provide starts start-profile build-prompt check-prompt truthy? case-seconds)

(define arms '(R T O))
(define-runtime-path bridge "call-valid.py")
(define-runtime-path try-script "profile-try.py")

;; ---- the implementations ---------------------------------------------------------------------------
(define implementers 5)
;; starts : -> (listof Start)
(define (starts)
  (for*/list ([p (in-list (profiles))] [i (in-range 1 (add1 implementers))]) (format "~a-~a" (short-name p) i)))
;; start-profile : Start -> Profile
(define (start-profile s) (string-append "us-core-" (regexp-replace #rx"-[0-9]+$" s "")))

(define (build-id s) (string-append s "-B"))
(define (check-id s arm) (format "~a-~a" s arm))

;; ---- a session's directory and prompt ---------------------------------------------------------------
(define listing
  (string-append
   "- PROFILE.md: the profile, what is in spec/, and what valid means\n"
   "- spec/: the profile's published definition and the definitions it rests on (FHIR JSON)\n"
   "- CONTRACT.md: the function's contract\n"
   "- sample/: FHIR resources — one of the profile's published examples and copies of it with one change each. Some are "
   "valid and some are not~a\n"
   "- try.py: `python3 try.py` runs validator.py over sample/ and prints its verdict for each resource; "
   "`python3 try.py --cases DIR` does so for the .json files of another directory\n"))

(define closing
  (string-append
   "Use only this directory and Python 3's standard library. Read nothing outside it, not the source of any installed "
   "software either: what you are given is what there is. No network, no packages.\n\n"))

;; build-prompt : Profile -> string
(define (build-prompt p)
  (string-append
   (format "Write validator.py: one Python function that says whether a FHIR resource is valid against the profile ~a.\n\n"
           (hash-ref (profile-definition p) 'title (hash-ref (profile-definition p) 'name)))
   "In this directory:\n"
   (format listing "; which is not said")
   "\nvalidator.py will be run on other resources than the sample's — other published examples of the profile, and copies "
   "of them changed in the same ways — and judged by whether each of its verdicts is HL7's validator's.\n\n"
   closing
   "When validator.py is written and you have tried it, end with one short line."))

;; arm-sentence : Arm -> string   what the arm adds, as its file is listed
(define (arm-sentence arm)
  (case arm
    [(R) ""]
    [(T) "- expected.json: HL7's validator's verdict (true: valid) for each resource of sample/\n"]
    [(O) (string-append
          "- oracle.rkt: `racket oracle.rkt` holds each resource of sample/ to the profile's published definition and prints "
          "valid or invalid for it; `racket oracle.rkt FILE.json …` or `racket oracle.rkt DIR` does so for other resources\n")]))

;; check-prompt : Profile Arm -> string   the same for every arm but for the line that names what
;; the arm adds
(define (check-prompt p arm)
  (string-append
   "This directory holds validator.py, written by someone else: one Python function that says whether a FHIR resource is "
   (format "valid against the profile ~a. Check it, and correct every error you find in it.\n\n"
           (hash-ref (profile-definition p) 'title (hash-ref (profile-definition p) 'name)))
   "In this directory:\n"
   "- validator.py: the implementation to check\n"
   (format listing (if (eq? arm 'R) "; which is not said" ""))
   (arm-sentence arm)
   "\nYou may write further resources (FHIR JSON files like the sample's) to test with. validator.py will be run on other "
   "resources than the sample's — other published examples of the profile, and copies of them changed in the same ways — "
   "and judged by whether each of its verdicts is HL7's validator's.\n\n"
   closing
   "When you are done, write the file verdict.json: {\"correct\": true} if you believe validator.py now gives the right "
   "verdict for every such resource, {\"correct\": false} if you believe errors remain. Then end with one short line."))

;; prepare-task! : Profile dir -> void   what an implementer is given
(define (prepare-task! p dir)
  (make-directory* dir)
  (display-to-file (profile-text p) (build-path dir "PROFILE.md") #:exists 'truncate)
  (display-to-file contract-text (build-path dir "CONTRACT.md") #:exists 'truncate)
  (write-spec! p (build-path dir "spec"))
  (write-sample! p (build-path dir "sample"))
  (copy-file try-script (build-path dir "try.py") #t))

;; prepare-check! : dir Start Arm dir -> void   the implementer's material, the implementation as
;; its build session left it, and what the arm adds
(define (prepare-check! out s arm dir)
  (define p (start-profile s))
  (prepare-task! p dir)
  (copy-file (build-path out (build-id s) "validator.py") (build-path dir "validator.py") #t)
  (case arm
    [(T) (define t (truth p))
         (write-json-file (build-path dir "expected.json")
                          (for/hasheq ([n (in-list (sample-names p))]) (values (string->symbol (car n)) (hash-ref t (cdr n)))))]
    [(O) (display-to-file
          (string-append
           "#lang racket/base\n"
           ";; The profile's published definition, executed.\n"
           ";;   racket oracle.rkt                 valid or invalid, for each resource of sample/\n"
           ";;   racket oracle.rkt FILE.json …     for the files named\n"
           ";;   racket oracle.rkt DIR             for the .json files of DIR\n"
           "(require (lib \"fhir-examples/value-experiment/verify/profile-oracle.rkt\"))\n"
           (format "(oracle-main ~s)\n" p))
          (build-path dir "oracle.rkt") #:exists 'truncate)]
    [else (void)]))

;; ---- run ----------------------------------------------------------------------------------------------
(define builtin '("Bash" "Read" "Write" "Edit" "Glob" "Grep"))
;; allowed : (or/c Arm 'B) -> (listof string)   Python and files for everyone; the oracle's one command for O
(define (allowed arm)
  (append '("Bash(python3:*)" "Bash(ls:*)" "Bash(cat:*)" "Bash(head:*)" "Bash(tail:*)" "Bash(grep:*)" "Bash(wc:*)"
            "Bash(mkdir:*)" "Bash(cp:*)" "Bash(diff:*)" "Read" "Write" "Edit" "Glob" "Grep")
          (if (eq? arm 'O) '("Bash(racket oracle.rkt:*)") '())))
;; what a session's commands must not name: the network, where the material came from, HL7's
;; validator, and any use of the toolkit but the oracle's own command
(define forbidden '("urllib" "requests" "socket" "pip " "curl" "wget" "git clone" "github" "/home/" "/usr/" "/root/"
                    "fhir-spec" "fhir-examples" "racket -" "raco " "collection-path" "validator_cli" "java "))

;; session-turns : how many model turns a session is given, building or checking, in every arm
(define session-turns 60)

;; run-one! : dir Start (or/c Arm 'B) model -> void
(define (run-one! out s arm model)
  (define p (start-profile s))
  (define id (if (eq? arm 'B) (build-id s) (check-id s arm)))
  (define work (build-path out id))
  (define rec
    (run-item id (if (eq? arm 'B) (build-prompt p) (check-prompt p arm)) work model (allowed arm)
              #:prepare (lambda () (if (eq? arm 'B) (prepare-task! p work) (prepare-check! out s arm work)))
              #:builtin builtin #:timeout 3000 #:max-turns session-turns))
  (define bad (audit rec forbidden))
  (unless (null? bad) (display-lines-to-file bad (build-path work "AUDIT") #:exists 'truncate))
  (printf "~a ~as in ~a out ~a turns ~a~a~a~a\n" id (hash-ref rec 'seconds) (hash-ref rec 'input_tokens)
          (hash-ref rec 'output_tokens) (hash-ref rec 'turns)
          (if (file-exists? (build-path work "validator.py")) "" "  no validator.py")
          (if (or (eq? arm 'B) (file-exists? (build-path work "verdict.json"))) "" "  no verdict")
          (if (null? bad) "" "  AUDIT"))
  (flush-output))

;; ---- score: everything that decides a result is here, in Racket ------------------------------------
;; case-seconds : how long an implementation is given for one resource
(define case-seconds (make-parameter 20))

;; truthy? : jsexpr -> boolean   Python's truth of what `valid` returned, as JSON
(define (truthy? v)
  (not (or (eq? v #f) (eq? v (json-null)) (equal? v 0) (equal? v 0.0) (equal? v "") (equal? v '()) (and (hash? v) (zero? (hash-count v))))))

;; start-bridge : dir output-port -> (values subprocess input-port output-port (or/c #f string))
;; an implementation loaded, in its own directory (it may read spec/); the string is why it did not load
(define (start-bridge dir log)
  (define-values (proc from to _e)
    (parameterize ([current-directory dir])
      (subprocess #f #f log (find-executable-path "python3") "-X" "utf8" (path->string bridge) "validator.py")))
  (define first (sync/timeout 60 (read-line-evt from 'linefeed)))
  (define said (and (string? first) (with-handlers ([exn:fail? (lambda (_) #f)]) (string->jsexpr first))))
  (values proc from to
          (cond [(and (hash? said) (hash-ref said 'loaded #f)) #f]
                [(hash? said) (hash-ref said 'error "validator.py did not load")]
                [else "validator.py did not load in a minute"])))

(define (stop-bridge! proc from to)
  (subprocess-kill proc #t)
  (close-input-port from)
  (with-handlers ([exn:fail? void]) (close-output-port to)))

;; call-valid : dir (listof (cons name jsexpr)) path -> (hash name jsexpr)   what the implementation
;; says of each resource: a hasheq of 'answer or 'error. A resource that takes too long, or on which
;; the process ends, is an error, and the implementation is started again for the rest.
(define (call-valid dir cases log-file)
  (define log (open-output-file log-file #:exists 'truncate))
  (define (one-line from) (sync/timeout (case-seconds) (read-line-evt from 'linefeed)))
  (begin0
    (let loop ([cases cases] [results (hash)] [bridge #f])
      (cond
        [(null? cases) (when bridge (apply stop-bridge! bridge)) results]
        [(not bridge)
         (define-values (proc from to why) (start-bridge dir log))
         (cond [why (stop-bridge! proc from to)
                    (for/fold ([r results]) ([c (in-list cases)]) (hash-set r (car c) (hasheq 'error why)))]
               [else (loop cases results (list proc from to))])]
        [else
         (define-values (proc from to) (apply values bridge))
         (define c (car cases))
         (define line
           (with-handlers ([exn:fail? (lambda (_) eof)])
             (write-json (cdr c) to) (newline to) (flush-output to)
             (one-line from)))
         (cond [(string? line)
                (loop (cdr cases)
                      (hash-set results (car c) (with-handlers ([exn:fail? (lambda (_) (hasheq 'error "an answer that is not JSON"))])
                                                  (let ([v (string->jsexpr line)]) (if (hash? v) v (hasheq 'error "an answer that is not an object")))))
                      bridge)]
               [else
                (stop-bridge! proc from to)
                (loop (cdr cases)
                      (hash-set results (car c)
                                (hasheq 'error (if line "the implementation's process ended"
                                                   (format "more than ~a seconds for one resource" (case-seconds)))))
                      #f)])]))
    (close-output-port log)))

;; score-one! : dir id Profile -> void   the directory's validator.py over every case of its profile,
;; each verdict set against HL7's validator's; an error is a wrong verdict
(define (score-one! out id p)
  (define work (build-path out id))
  (define t (truth p))
  (define said
    (if (file-exists? (build-path work "validator.py"))
        (call-valid work (cases p) (build-path work "score.log"))
        (for/hash ([c (in-list (cases p))]) (values (car c) (hasheq 'error "no validator.py")))))
  (write-json-file
   (build-path work "score.json")
   (hasheq 'profile p
           'cases (for/hasheq ([c (in-list (cases p))])
                    (define a (hash-ref said (car c)))
                    (define error (hash-ref a 'error #f))
                    (values (string->symbol (car c))
                            (hasheq 'sample (and (sample-case? p (car c)) #t)
                                    'expected (hash-ref t (car c))
                                    'said (if error (format "ERROR ~a" error) (truthy? (hash-ref a 'answer #f)))
                                    'right (and (not error) (eq? (truthy? (hash-ref a 'answer #f)) (hash-ref t (car c))))))))))

;; score! : dir -> void   every build and every check session there is
(define (score! out)
  (void
   (in-parallel 6
                (for*/list ([s (in-list (starts))] [arm (in-list (cons 'B arms))]
                            [id (in-value (if (eq? arm 'B) (build-id s) (check-id s arm)))]
                            #:when (directory-exists? (build-path out id)))
                  (list out id (start-profile s)))
                (lambda (job) (apply score-one! job)))))

;; rights : path -> Rights   a score.json's held-out cases
(define (rights file)
  (for/hash ([(c v) (in-hash (hash-ref (read-json-file file) 'cases))] #:unless (hash-ref v 'sample))
    (values (symbol->string c) (and (hash-ref v 'right) #t))))

;; belief-of : dir -> boolean | 'none   what a session's verdict.json says
(define (belief-of dir)
  (define f (build-path dir "verdict.json"))
  (define v (and (file-exists? f) (with-handlers ([exn:fail? (lambda (_) #f)]) (read-json-file f))))
  (if (and (hash? v) (boolean? (hash-ref v 'correct 'none))) (hash-ref v 'correct) 'none))

;; session-cost : dir -> (hasheq symbol real)
(define (session-cost dir)
  (define rec (read-json-file (build-path dir "record.json")))
  (for/hasheq ([k (in-list '(input_tokens output_tokens seconds turns))])
    (values k (let ([v (hash-ref rec k 0)]) (if (real? v) v 0)))))

;; read-checks : dir -> (listof Check)   a scored run: the starts that were built and scored
(define (read-checks out)
  (for/list ([s (in-list (starts))] #:when (file-exists? (build-path out (build-id s) "score.json")))
    (define run (filter (lambda (arm) (file-exists? (build-path out (check-id s arm) "score.json"))) arms))
    (review s (start-profile s) 'P
            (rights (build-path out (build-id s) "score.json"))
            (for/hash ([arm (in-list run)]) (values arm (rights (build-path out (check-id s arm) "score.json"))))
            (for/hash ([arm (in-list (cons 'B run))])
              (values arm (session-cost (build-path out (if (eq? arm 'B) (build-id s) (check-id s arm))))))
            (for/hash ([arm (in-list run)]) (values arm (belief-of (build-path out (check-id s arm))))))))

;; ---- report ----------------------------------------------------------------------------------------
(define (mean xs) (if (null? xs) 0 (/ (apply + xs) (length xs))))
(define (perfect? rights) (for/and ([(c r) (in-hash rights)]) r))
(define (percent x) (format "~a%" (/ (round (* 1000.0 x)) 10.0)))
(define (points x) (format "~a~a" (if (negative? x) "" "+") (/ (round (* 1000.0 x)) 10.0)))
(define (thousands x) (format "~ak" (/ (round (/ x 100.0)) 10.0)))
(define arm-name (hash 'B "build" 'R "read (R)" 'T "tested (T)" 'O "oracle (O)"))
(define (padded s n) (string-append s (make-string (max 1 (- n (string-length s))) #\space)))

;; oracle-ceiling : (listof Profile) -> (cons natural natural)   on the held-out cases of those
;; profiles, how many the oracle itself gets as HL7's validator does, and how many there are
(define (oracle-ceiling ps)
  (define rows (filter (lambda (r) (and (member (car r) ps) (held-out? r))) (agreement)))
  (cons (count agree? rows) (length rows)))

(define (report all)
  (define checks (filter (lambda (c) (for/and ([arm (in-list arms)]) (hash-has-key? (review-after c) arm))) all))
  (define ps (remove-duplicates (map review-measure checks)))
  (define ceiling (oracle-ceiling ps))
  (printf "implementations built: ~a; checked in every arm: ~a, of ~a profiles; held-out cases: ~a\n"
          (length all) (length checks) (length ps)
          (for/sum ([p (in-list ps)]) (hash-count (review-before (findf (lambda (c) (equal? (review-measure c) p)) checks)))))
  (printf "the oracle itself, on those held-out cases: ~a of ~a as HL7's validator (~a)\n\n"
          (car ceiling) (cdr ceiling) (percent (/ (car ceiling) (cdr ceiling))))
  (printf "right on the held-out cases            as built   after R    after T    after O\n")
  (define (row label group)
    (printf "  ~a ~a     ~a      ~a      ~a\n" (padded label 36) (percent (share-before group))
            (percent (share-after group 'R)) (percent (share-after group 'T)) (percent (share-after group 'O))))
  (row "all" checks)
  (for ([p (in-list ps)]) (row (short-name p) (filter (lambda (c) (equal? (review-measure c) p)) checks)))
  (newline)
  (for ([arm (in-list arms)])
    (define f (fixed checks arm))
    (define b (broken checks arm))
    (printf "~a: of ~a verdicts wrong as built, ~a right after (~a); of ~a right as built, ~a wrong after\n"
            (hash-ref arm-name arm) (cdr f) (car f) (if (zero? (cdr f)) "-" (percent (/ (car f) (cdr f)))) (cdr b) (car b)))
  (printf "implementations right on every held-out case: as built ~a; after R ~a, T ~a, O ~a (of ~a)\n"
          (count (lambda (c) (perfect? (review-before c))) checks)
          (count (lambda (c) (perfect? (hash-ref (review-after c) 'R))) checks)
          (count (lambda (c) (perfect? (hash-ref (review-after c) 'T))) checks)
          (count (lambda (c) (perfect? (hash-ref (review-after c) 'O))) checks) (length checks))
  (newline)
  (for ([arm (in-list arms)])
    (define said (filter (lambda (c) (eq? (hash-ref (review-belief c) arm) #t)) checks))
    (define doubted (filter (lambda (c) (eq? (hash-ref (review-belief c) arm) #f)) checks))
    (printf "~a: said the implementation is right ~a times, and it was right on every held-out case ~a times; said errors remain ~a times (they did ~a times); no verdict ~a\n"
            (hash-ref arm-name arm) (length said) (count (lambda (c) (perfect? (hash-ref (review-after c) arm))) said)
            (length doubted) (count (lambda (c) (not (perfect? (hash-ref (review-after c) arm)))) doubted)
            (- (length checks) (length said) (length doubted))))
  (newline)
  (define (compare a b)
    (define d (difference checks a b))
    (define ci (bootstrap-difference checks a b))
    (printf "~a − ~a = ~a points (95% interval ~a to ~a; label swap p = ~a)\n" a b
            (points d) (points (car ci)) (points (cdr ci)) (exact->inexact (/ (round (* 10000 (sign-flip-p checks a b))) 10000)))
    (values d ci))
  (define-values (d ci) (compare 'O 'R))
  (call-with-values (lambda () (compare 'O 'T)) void)
  (call-with-values (lambda () (compare 'T 'R)) void)
  (newline)
  (for ([arm (in-list (cons 'B arms))])
    (define (m key) (mean (map (lambda (c) (hash-ref (hash-ref (review-cost c) arm) key)) checks)))
    (printf "a session, ~a: ~a input and ~a output tokens, ~a turns, ~a s\n" (hash-ref arm-name arm)
            (thousands (m 'input_tokens)) (thousands (m 'output_tokens)) (exact->inexact (/ (round (* 10 (m 'turns))) 10)) (exact-round (m 'seconds))))
  (printf "\nverdict (O against R)   ~a\n"
          (case (verdict-of d (interval (car ci) (cdr ci)) #f)
            [(more-right) "the oracle's checkers leave implementations right more often (the protocol's \"significant value\")"]
            [(worse) "the oracle's checkers leave implementations right less often"]
            [else "no difference shown"])))

;; changes : (listof Check) -> void   each held-out verdict some session fixed or broke
(define (changes checks)
  (for* ([c (in-list checks)] [k (in-list (sort (hash-keys (review-before c)) string<?))])
    (define before (hash-ref (review-before c) k))
    (define after (for/list ([arm (in-list arms)] #:when (hash-has-key? (review-after c) arm)) (cons arm (hash-ref (hash-ref (review-after c) arm) k))))
    (unless (andmap (lambda (a) (eq? (cdr a) before)) after)
      (printf "~a ~a: ~a as built; ~a\n" (review-start c) k (if before "right" "wrong")
              (string-join (for/list ([a (in-list after)]) (format "~a ~a" (car a) (if (cdr a) "right" "wrong"))) ", ")))))

;; ---- command line ---------------------------------------------------------------------------------------
(module+ main
  (define usage "profile-verify.rkt build|run|score|report|changes OUT [options]")
  (define args (vector->list (current-command-line-arguments)))
  (define (option name default)
    (define at (member name args))
    (if (and at (pair? (cdr at))) (cadr at) default))
  (when (< (length args) 2) (raise-user-error 'profile-verify usage))
  (define out (path->complete-path (cadr args)))
  (define only (let ([o (option "--only" #f)]) (and o (string-split o ","))))
  (define (wanted) (filter (lambda (s) (or (not only) (member s only))) (starts)))
  (define (sessions jobs)
    (current-resume? (and (member "--resume" args) #t))
    (make-directory* out)
    (void (in-parallel (string->number (option "--parallel" "6")) jobs
                       (lambda (job) (run-one! out (car job) (cadr job) (option "--model" "sonnet"))))))
  (case (car args)
    [("build") (sessions (for/list ([s (in-list (wanted))]) (list s 'B)))]
    [("run")
     (define wanted-arms (map string->symbol (string-split (option "--arms" "R,T,O") ",")))
     (sessions (for*/list ([s (in-list (wanted))] #:when (file-exists? (build-path out (build-id s) "validator.py"))
                           [arm (in-list wanted-arms)])
                 (list s arm)))]
    [("score") (score! out)
               (for ([c (in-list (read-checks out))])
                 (printf "~a as built ~a~a\n" (review-start c) (percent (share-before (list c)))
                         (string-join (for/list ([arm (in-list arms)] #:when (hash-has-key? (review-after c) arm))
                                        (format ", ~a ~a" arm (percent (share-after (list c) arm))))
                                      "")))]
    [("report") (report (read-checks out))]
    [("changes") (changes (read-checks out))]
    [else (raise-user-error 'profile-verify usage)]))

(module+ test
  (require rackunit)
  ;; thirty implementations, five a profile
  (check-equal? (length (starts)) 30)
  (check-equal? (start-profile "patient-3") "us-core-patient")
  (check-equal? (start-profile "condition-problems-health-concerns-5") "us-core-condition-problems-health-concerns")
  (check-not-false (member (start-profile (car (starts))) (profiles)))
  ;; Python's truth of a JSON value
  (check-equal? (map truthy? (list #t #f (json-null) 0 1 "" "no" '() '(0) (hasheq) (hasheq 'a 1))) '(#t #f #f #f #t #f #t #f #t #f #t))
  ;; the arms' prompts differ in the lines that name what the arm adds, and in nothing else
  (define p "us-core-patient")
  (define (lines arm) (string-split (check-prompt p arm) "\n"))
  (check-equal? (length (lines 'T)) (add1 (length (lines 'R))))
  (check-equal? (length (lines 'O)) (add1 (length (lines 'R))))
  (check-equal? (filter (lambda (l) (not (member l (lines 'R)))) (lines 'T))
                (filter (lambda (l) (regexp-match? #rx"expected.json|Some are valid" l)) (lines 'T)))
  (check-equal? (length (filter (lambda (l) (not (member l (lines 'R)))) (lines 'O))) 2)
  (check-regexp-match #rx"racket oracle.rkt" (check-prompt p 'O))
  (check-false (regexp-match? #rx"oracle|expected" (check-prompt p 'R)))
  (check-false (regexp-match? #rx"oracle|expected|someone else" (build-prompt p)))
  ;; a scored implementation: one that answers by a rule, one that raises, one that does not load
  (define dir (make-temporary-file "score-~a" 'directory))
  (define (scored id text)
    (make-directory* (build-path dir id))
    (display-to-file text (build-path dir id "validator.py"))
    (score-one! dir id p)
    (hash-ref (read-json-file (build-path dir id "score.json")) 'cases))
  (define yes (scored "yes" "def valid(resource):\n    return True\n"))
  (define t (truth p))
  (check-equal? (hash-count yes) (length (cases p)))
  (check-equal? (for/sum ([(k v) (in-hash yes)]) (if (hash-ref v 'right) 1 0)) (count values (hash-values t)) "always valid: right where HL7 says valid")
  (define raises (scored "raises" "def valid(resource):\n    raise ValueError('no')\n"))
  (check-equal? (for/sum ([(k v) (in-hash raises)]) (if (hash-ref v 'right) 1 0)) 0)
  (check-regexp-match #rx"^ERROR ValueError: no" (hash-ref (car (hash-values raises)) 'said))
  (define broken (scored "broken" "def valid(resource)\n"))
  (check-regexp-match #rx"did not load" (hash-ref (car (hash-values broken)) 'said))
  (define reads (scored "reads" (string-append "import json, os\n"
                                               "P = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'spec', 'profile.json')))\n"
                                               "def valid(resource):\n    return resource.get('resourceType') == P['type']\n")))
  (check-regexp-match #rx"did not load" (hash-ref (car (hash-values reads)) 'said) "no spec/ beside it here")
  (check-equal? (hash-count (rights (build-path dir "yes" "score.json"))) (count (lambda (c) (not (sample-case? p (car c)))) (cases p)))
  (delete-directory/files dir))
