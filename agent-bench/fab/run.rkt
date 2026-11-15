#lang racket/base

;;; run.rkt — FHIR-AgentBench questions, one headless Claude Code agent per question.
;;;
;;;   racket -l- fhir-examples/agent-bench/fab/run ARM SAMPLE.json OUT_DIR [--model M] [--parallel K] [--limit N]
;;;
;;; Arms (how the agent reaches the data; the instructions are otherwise the same):
;;;   rest       curl against a plain FHIR R4 REST server over the store (serve-store.rkt, FAB_REST)
;;;   workspace  the fhir-mcp workspace verbs (`raco fhir-mcp call …`) over the same store (FAB_STORE)
;;; Each agent writes answer.json {"answer", "resources": ["Type/id", …]}; the run writes
;;; agent_results.json in the benchmark's input format for its evaluation_metrics.py (score.sh).

(require racket/cmdline racket/file racket/list racket/string racket/system json
         "../run-agent.rkt")

(define common #<<EOF
You are answering a question about a patient from a hospital dataset held as FHIR R4 resources (about 930,000 of them: Patient, Encounter, Observation, Condition, Procedure, Medication, MedicationRequest, MedicationAdministration, MedicationDispense, MedicationStatement, Specimen, Location, Organization). The dates are shifted far into the future on purpose.

Question: {question}
Assumption: {assumption}
The patient: Patient/{patient_fhir_id} (the number in the question is that patient's hospital identifier).

Find the answer in the data and note which resources it rests on. Answer as a clinician's assistant would: a value with its unit, a date-time, a name, a count, yes/no — or "none" when the data holds nothing that answers the question (a legitimate answer; do not guess). "Hospital visit", "hospital stay" and "hospital encounter" mean an inpatient hospital admission; "ICU visit" an intensive-care stay; "current hospital visit" one that has not ended at the assumed current time.

When done, write {answer_file}: {"answer": "<your answer>", "resources": ["Type/id", ...the resources the answer rests on]}.

{access}
Use only that access to read the data; you may use python3 or jq to compute over what it returned. Do not look for the benchmark's files or answers.
EOF
  )

(define (access arm rest)
  (if (equal? arm "workspace")
      (string-append "Access: the FHIR workspace in this directory, from the shell:\n"
                     "  raco fhir-mcp call <verb> key=value ...      (verbs: check, query, run, explain, describe, write, apply)\n"
                     "  raco fhir-mcp tools                          the verbs and their arguments\n"
                     "  raco fhir guide workspace                    the guide written for agents (read it first)\n"
                     "The workspace's data is this dataset (a store).")
      (string-append (format "Access: a FHIR R4 REST server, with curl. Base url: ~a\n" rest)
                     (format "  curl -s ~a/metadata                       the types and the search parameters of each\n" rest)
                     (format "  curl -s \"~a/<Type>/<id>\"                  read one resource\n" rest)
                     (format "  curl -s \"~a/<Type>?<param>=<value>&...\"   search: a Bundle (`total`, `entry`, a `next` link when it is a page)\n" rest)
                     "Standard FHIR search applies: _count, _sort (-date descending), _summary=count, date prefixes (date=ge2130-01-01), token system|code, :text, references (patient=Patient/<id>), _include. Read and search are all it offers.")))

;; prompt : arm rest-base question answer-file -> string   the answer file named by its absolute path:
;; agents told "this directory" have written it to a mistyped one
(define (prompt arm rest q answer-file)
  (for/fold ([s (string-replace (string-replace common "{access}" (access arm rest)) "{answer_file}" answer-file)])
            ([k '(question assumption patient_fhir_id)])
    (string-replace s (format "{~a}" k) (hash-ref q k))))

(define (tools arm)
  (append (if (equal? arm "workspace") '("Bash(raco fhir-mcp:*)" "Bash(raco fhir guide:*)") '("Bash(curl:*)"))
          '("Bash(python3:*)" "Bash(jq:*)" "Read" "Write")))

;; resources-by-type : answer -> hash   "Type/id"s as the benchmark's {Type: [ids]}
(define (resources-by-type ans)
  (define refs (if (hash? ans) (hash-ref ans 'resources '()) '()))
  (for/fold ([h (hasheq)]) ([r (in-list (if (list? refs) refs '()))]
                            #:when (and (string? r) (regexp-match? #rx"/" r)))
    (define parts (string-split r "/"))
    (define t (string->symbol (list-ref parts (- (length parts) 2))))
    (hash-update h t (lambda (l) (append l (list (last parts)))) '())))

(define benchmark-files '("FHIR-AgentBench" "final_dataset" "questions_answers" "valid-150.json"))

;; failed-record : question exn -> Record   a question whose run raised (said on stderr)
(define (failed-record q e)
  (hasheq 'id (hash-ref q 'question_id) 'answer (json-null) 'final_message (json-null)
          'error (exn-message e) 'seconds 0 'turns (json-null) 'cost_usd 0 'input_tokens 0 'output_tokens 0))

;; collected-record : dir question -> Record   an item's record as it is on disk, its answer read again
;; (read-answer: also from a mistyped directory)
(define (collected-record dir q)
  (define work (build-path dir (hash-ref q 'question_id)))
  (define rec (read-json-file (build-path work "record.json")))
  (define answer (read-answer work))
  (hash-set* rec 'answer (or answer (json-null))
             'error (if answer (json-null) (hash-ref rec 'error))))

;; agent-results : questions records -> jsexpr   the benchmark's input to evaluation_metrics.py
(define (agent-results qs recs)
  (for/list ([q (in-list qs)] [r (in-list recs)])
    (define ans (hash-ref r 'answer))
    (hasheq 'question_id (hash-ref q 'question_id)
            'question_with_context (hash-ref q 'question)
            'agent_answer (if (hash? ans) (let ([a (hash-ref ans 'answer (json-null))]) (if (string? a) a (jsexpr->string a))) (json-null))
            'agent_fhir_resources (jsexpr->string (resources-by-type ans))
            'error (let ([e (hash-ref r 'error)]) (if (string? e) e ""))
            'trace (hash-ref r 'final_message)
            'usage (hasheq 'input (hash-ref r 'input_tokens) 'output (hash-ref r 'output_tokens)
                           'cost_usd (hash-ref r 'cost_usd) 'seconds (hash-ref r 'seconds) 'turns (hash-ref r 'turns)))))

(module+ main
  (define model "sonnet") (define parallel 4) (define limit #f) (define collect? #f)
  (define-values (arm sample-file out)
    (command-line
     #:once-each
     [("--model") m "model (default sonnet)" (set! model m)]
     [("--parallel") k "agents at a time (default 4)" (set! parallel (string->number k))]
     [("--limit") n "the first N questions" (set! limit (string->number n))]
     [("--collect") "run nothing: rebuild agent_results.json from the run's directories" (set! collect? #t)]
     #:args (arm sample out) (values arm sample out)))
  (unless (member arm '("rest" "workspace")) (raise-user-error 'run "the arm is rest or workspace"))
  (define rest (or (getenv "FAB_REST") "http://localhost:8765"))
  (define qs (let ([all (read-json-file sample-file)]) (if limit (take all (min limit (length all))) all)))
  (define dir (path->complete-path out))
  (make-directory* dir)
  (define (one q)
    (define id (hash-ref q 'question_id))
    (define work (build-path dir id))
    (define (prepare)
      (when (equal? arm "workspace")
        (display-to-file (format "fhirVersion: 4.0.1\ndata: ~a\n" (or (getenv "FAB_STORE") (error 'run "set FAB_STORE")))
                         (build-path work "workspace.yaml"))))
    (define rec (run-item id (prompt arm rest q (path->string (build-path work "answer.json"))) work model (tools arm)
                          #:prepare prepare))
    (void (system* (find-executable-path "pkill") "-f" (format "mcp-daemon.*~a" work)))
    ;; the benchmark's files, and the other questions' directories (an agent's own is its cwd)
    (define others (for/list ([o (in-list qs)] #:unless (equal? (hash-ref o 'question_id) id))
                     (path->string (build-path dir (hash-ref o 'question_id)))))
    (define bad (audit rec (append benchmark-files others)))
    (unless (null? bad) (display-lines-to-file bad (build-path work "AUDIT") #:exists 'truncate))
    (printf "~a ~as $~a ~a~a\n" (substring id 0 8) (hash-ref rec 'seconds) (hash-ref rec 'cost_usd)
            (if (hash? (hash-ref rec 'answer)) "answered" "NO ANSWER") (if (null? bad) "" "  AUDIT"))
    (flush-output)
    rec)
  (define recs
    (if collect?
        (for/list ([q (in-list qs)]) (collected-record dir q))
        (begin
          (write-json-file (build-path dir "run.json") (hasheq 'arm arm 'model model 'questions (length qs)))
          (for/list ([q qs] [r (in-parallel parallel qs one)]) (if (hash? r) r (failed-record q r))))))
  (write-json-file (build-path dir "agent_results.json") (agent-results qs recs))
  (printf "~a answered of ~a; total $~a\n" (count (lambda (r) (hash? (hash-ref r 'answer))) recs) (length recs)
          (/ (round (* 100 (for/sum ([r recs]) (let ([c (hash-ref r 'cost_usd)]) (if (real? c) c 0))))) 100.0)))

(module+ test
  (require rackunit)
  (check-equal? (resources-by-type (hasheq 'resources '("Observation/a" "Encounter/b" "Observation/c" "nope")))
                (hasheq 'Observation '("a" "c") 'Encounter '("b"))))
