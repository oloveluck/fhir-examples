#lang racket/base

;;; run.rkt — FHIR-AgentBench questions, one headless Claude Code agent per question.
;;;
;;;   racket -l- fhir-examples/agent-bench/fab/run ARM SAMPLE.json OUT_DIR [--model M] [--parallel K] [--limit N]
;;;
;;; Arms (how the agent reaches the data; the instructions are otherwise the same):
;;;   rest       curl against a plain FHIR R4 REST server over the store (serve-store.rkt, FAB_REST)
;;;   workspace  the fhir-mcp workspace verbs (`raco fhir-mcp call …`) over the same store (FAB_STORE)
;;;   mcp        the same verbs as MCP tools (`raco fhir-mcp` as the agent's MCP server)
;;;   tables     the benchmark's relational schema, defined over the store by an agent beforehand
;;;              (setup-tables.rkt; FAB_TABLES is that workspace): the question is answered in SQL
;;;              over those tables, from the worked example of its kind (FAB_EXAMPLES, a directory made
;;;              by make-examples.rkt from the train split)
;;; Every arm has the same built-in tools (Bash, Read, Write: `--tools`), and the same closing
;;; instruction; the workspace arms get the reading card (`raco fhir guide data`) where the rest
;;; arm gets its curl lines.
;;; Each agent writes answer.json {"answer", "resources": ["Type/id", …]}; the run writes
;;; agent_results.json in the benchmark's input format for its evaluation_metrics.py (score.sh).

(require racket/cmdline racket/file racket/list racket/string racket/system racket/port racket/runtime-path json
         "../run-agent.rkt")

(define common #<<EOF
You are answering a question about a patient from a hospital dataset held as FHIR R4 resources (about 930,000 of them: Patient, Encounter, Observation, Condition, Procedure, Medication, MedicationRequest, MedicationAdministration, MedicationDispense, MedicationStatement, Specimen, Location, Organization). The dates are shifted far into the future on purpose.

Question: {question}
Assumption: {assumption}
The patient: Patient/{patient_fhir_id} (the number in the question is that patient's hospital identifier).

Find the answer in the data and note which resources it rests on. Answer as a clinician's assistant would: a value with its unit, a date-time, a name, a count, yes/no — or "none" when the data holds nothing that answers the question (a legitimate answer; do not guess). "Hospital visit", "hospital stay" and "hospital encounter" mean an inpatient hospital admission; "ICU visit" an intensive-care stay; "current hospital visit" one that has not ended at the assumed current time.

When done, write {answer_file}: {"answer": "<your answer>", "resources": ["Type/id", ...the resources the answer rests on]}. Once it is written you are done: end with one short line, no summary.

{access}
Use only that access to read the data; you may use python3 or jq to compute over what it returned. Do not look for the benchmark's files or answers.
EOF
  )

(define (access arm rest)
  (case arm
    [("workspace")
     (string-append "Access: the FHIR workspace in this directory, from the shell. Its data is this dataset (a store).\n\n"
                    (reading-card))]
    [("tables")
     (string-append
      "Access: the dataset as the tables of a relational schema, in this directory's workspace (the tables are defined over the FHIR data):\n"
      "  raco fhir-mcp call query language=sql text=\"SELECT …\"      one SQLite statement; rows come back as JSON\n"
      "  ./answer --kind <number> \"SELECT …\"                        the query that answers the question: its rows, the answer, the resources behind it — written to the answer file\\n"
      "Each command line is checked before it runs, and only plain ones pass: these two commands and `cat`/`grep` on the examples, several joined by `;`. A shell variable (`C=…`), `$(…)`, a here-document or a script is refused and costs you the turn. Write the whole query inside the quotes, a condition that occurs twice written out twice.\n\n"
      (tables-schema) "\n\n"
      "People who compute against this schema write each kind of question's query one way. The kinds (a kind's slots in braces and brackets):\n"
      (examples-file "kinds.md") "\n\n"
      "`cat examples/<number>.md` shows a kind: a question or two of that kind, what each assumes, and the query that answers it.\n\n"
      "How a time phrase is written in such a query (with your column and your current time in place of the ones shown):\n"
      (examples-file "phrases.md") "\n\n"
      "Work like this:\n"
      "1. Read the example of your question's kind. When none is your question, take the nearest by what is asked for first — a yes/no question's example selects a comparison (`COUNT(*)>0`), a \"when\" or \"list the times\" question's the time column, \"how many\" a count, \"how much\" a sum or the value — and then by what it reads. In the same command, look up each name your question gives — a lab test, a drug, an output, a care unit, a specimen: the tables have it as the hospital writes it, capitals included, and the question gives it in lower case, where it can read like ordinary words (\"or urine\" is the output `OR Urine`, not urine outputs). Ask for the name exactly as the question words it, case aside: `SELECT DISTINCT drug FROM prescriptions WHERE lower(trim(drug)) = '5% dextrose'`. Use every spelling that returns (`drug IN ('Amlodipine', 'amLODIPine')`); search by pattern (`LIKE`) only when it returns nothing.\n"
      "2. Copy the example's query whole and change only three things: the patient's number; the names and values (spelled as the tables have them); the time conditions (take out the example's, put in one for each time phrase of your question — \"today\", \"since 09/2116\", \"on the last ICU visit\" — written as the list above writes it, on the column the example uses). Change nothing else: not how the visit is chosen, not the SELECT, not the ORDER BY or LIMIT, and add no condition of your own. Two readings to keep:\n"
      "   - \"Current\" is what has no end recorded, and only that. A current hospital visit (\"this hospital stay\", \"this admission\", \"since admission\") is `admissions.dischtime IS NULL`; a current ICU stay (\"this ICU encounter\", \"the current ICU visit\") is `icustays.outtime IS NULL`. Time elapsed since an admission (\"how many hours since the patient was admitted\", to the hospital or to the ICU) is asked of the current one. The people who use this schema do not call a visit current once its end is recorded, whatever the assumed current time is.\n"
      "   - \"Last year\", \"in the last year\", \"the previous month\", \"yesterday\" name the calendar year, month or day before the current one (`datetime(x,'start of year') = datetime(<now>,'start of year','-1 year')`), not the twelve months, thirty days or twenty-four hours up to now. Only \"since N years/months/days ago\" counts back from now.\n"
      "3. Run it with `./answer --kind <number> \"SELECT …\"` (the number of the example you copied). It prints the rows; states the answer as the people who use this schema state one — the value alone (`61.7`, `-1`, `2133-12-31 02:00:00`, `EW EMER.`), every row's value in the order returned when there are several, `yes`/`no` for a comparison, and \"none: nothing on record\" when the query returns no row, a null or a count of 0; finds the resources the answer rests on (the rows of the query's table that meet its conditions, each row's `fhir_id` columns); and writes both to the answer file. Each `note:` it prints names something to look at again: a shape that is not the example's, a phrase of your question (\"today\", \"this hospital stay\", \"daily\") with no condition for it, a name the question does not give or one it gives that the query leaves out, a first or last row with no value, a value selected where the question asks whether something is so. Unless a note is plainly mistaken, correct the query and run it again. When it says `NOT written`, there is no answer file yet: correct the query and run it again. Otherwise you are done: do not rewrite the file, do not add a unit, a date or an explanation, and do not look for another reading of the question that would return something. (Only when the answer it states is not what the rows say, write the file yourself.)")]
    [("mcp")
     (string-append "Access: the FHIR workspace's tools (mcp__fhir__…: query, describe, explain, run, check, …), over this dataset. "
                    "The card below writes a call as the shell does: `describe ref=X as=fsh` is the describe tool with ref and as.\n\n"
                    (reading-card))]
    [else
      (string-append (format "Access: a FHIR R4 REST server, with curl. Base url: ~a\n" rest)
                     (format "  curl -s ~a/metadata                       the types and the search parameters of each\n" rest)
                     (format "  curl -s \"~a/<Type>/<id>\"                  read one resource\n" rest)
                     (format "  curl -s \"~a/<Type>?<param>=<value>&...\"   search: a Bundle (`total`, `entry`, a `next` link when it is a page)\n" rest)
                     "Standard FHIR search applies: _count, _sort (-date descending), _summary=count, date prefixes (date=ge2130-01-01), token system|code, :text, references (patient=Patient/<id>), _include. Read and search are all it offers.")]))

;; prompt : arm rest-base question answer-file -> string   the answer file named by its absolute path:
;; agents told "this directory" have written it to a mistyped one
(define (prompt arm rest q answer-file)
  (for/fold ([s (string-replace (string-replace common "{access}" (access arm rest)) "{answer_file}" answer-file)])
            ([k '(question assumption patient_fhir_id)])
    (string-replace s (format "{~a}" k) (hash-ref q k))))

;; ---- the `tables` arm ---------------------------------------------------------------------------
;; tables-schema : -> string   the schema's tables and columns (schema.md's table), for the prompt
(define-runtime-path schema-file "schema.md")
(define (tables-schema)
  (string-append "The schema (a time is text, `YYYY-MM-DD HH:MM:SS`; an identifier an integer):\n"
                 (string-join (filter (lambda (l) (regexp-match? #rx"^[|]" l)) (file->lines schema-file)) "\n")))

;; examples-dir : -> path   what make-examples wrote (FAB_EXAMPLES): kinds.md, phrases.md, <n>.md
(define (examples-dir) (or (getenv "FAB_EXAMPLES") (error 'run "set FAB_EXAMPLES to the directory make-examples wrote")))
(define (examples-file name) (string-trim (file->string (build-path (examples-dir) name))))

;; tables-workspace! : dir question -> void   the question's workspace: the tables the setup agent defined
;; (FAB_TABLES: its views and `.sql` files), the rows it already computed (a link to its kept
;; views: a view over the Observations takes minutes to compute), the worked examples with
;; the checks read from the train split (query-checks.rkt), the question (for those checks), and
;; `./answer` (answer.rkt: the query run, the answer and its resources written)
(define (tables-workspace! work q)
  (define from (or (getenv "FAB_TABLES") (error 'run "set FAB_TABLES to the workspace setup-tables wrote")))
  (for ([f (in-list (directory-list from))]
        #:when (regexp-match? #rx"[.](view[.]json|sql|yaml)$" (path->string f)))
    (copy-file (build-path from f) (build-path work f) #t))
  (make-directory* (build-path work "examples"))
  (for ([f (in-list (directory-list (examples-dir)))] #:when (regexp-match? #rx"^[0-9]+[.]md$" (path->string f)))
    (copy-file (build-path (examples-dir) f) (build-path work "examples" f) #t))
  (when (file-exists? (build-path (examples-dir) "checks.json"))
    (copy-file (build-path (examples-dir) "checks.json") (build-path work "examples" "checks.json") #t))
  (call-with-output-file (build-path work "question.json") #:exists 'truncate
    (lambda (o) (write-json (hasheq 'question (hash-ref q 'question) 'assumption (hash-ref q 'assumption "")) o)))
  (display-to-file "#!/bin/sh\nexec racket -l- fhir-examples/agent-bench/fab/answer \"$@\"\n" (build-path work "answer") #:exists 'truncate)
  (file-or-directory-permissions (build-path work "answer") #o755)
  (make-directory* (build-path work ".fhir-mcp"))
  (make-file-or-directory-link (path->complete-path (build-path from ".fhir-mcp" "views.db")) (build-path work ".fhir-mcp" "views.db")))

(define (tools arm)
  (append (case arm
            [("workspace") '("Bash(raco fhir-mcp:*)" "Bash(raco fhir guide:*)")]
            [("tables") '("Bash(raco fhir-mcp:*)" "Bash(./answer:*)" "Bash(cat:*)" "Bash(grep:*)")]
            [("mcp") '("mcp__fhir" "Bash(raco fhir guide:*)")]
            [else '("Bash(curl:*)")])
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
     [("--resume") "skip the items that already have a record (a killed run, resumed)" (current-resume? #t)]
     #:args (arm sample out) (values arm sample out)))
  (unless (member arm '("rest" "workspace" "mcp" "tables")) (raise-user-error 'run "the arm is rest, workspace, mcp or tables"))
  (define rest (or (getenv "FAB_REST") "http://localhost:8765"))
  (define qs (let ([all (read-json-file sample-file)]) (if limit (take all (min limit (length all))) all)))
  (define dir (path->complete-path out))
  (make-directory* dir)
  (define (one q)
    (define id (hash-ref q 'question_id))
    (define work (build-path dir id))
    (define (prepare)
      (when (member arm '("workspace" "mcp"))
        (display-to-file (format "fhirVersion: 4.0.1\ndata: ~a\n" (or (getenv "FAB_STORE") (error 'run "set FAB_STORE")))
                         (build-path work "workspace.yaml")))
      (when (equal? arm "tables") (tables-workspace! work q)))
    (define rec (run-item id (lambda (real) (prompt arm rest q (path->string (build-path real "answer.json")))) work model (tools arm)
                          #:prepare prepare #:builtin builtin-tools #:mcp (and (equal? arm "mcp") (workspace-mcp work))))
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
          (write-json-file (build-path dir "run.json") (hasheq 'arm arm 'model model 'questions (length qs) 'harness 2))
          (for/list ([q qs] [r (in-parallel parallel qs one)]) (if (hash? r) r (failed-record q r))))))
  (write-json-file (build-path dir "agent_results.json") (agent-results qs recs))
  (printf "~a answered of ~a; total $~a\n" (count (lambda (r) (hash? (hash-ref r 'answer))) recs) (length recs)
          (/ (round (* 100 (for/sum ([r recs]) (let ([c (hash-ref r 'cost_usd)]) (if (real? c) c 0))))) 100.0)))

(module+ test
  (require rackunit)
  (check-equal? (resources-by-type (hasheq 'resources '("Observation/a" "Encounter/b" "Observation/c" "nope")))
                (hasheq 'Observation '("a" "c") 'Encounter '("b"))))
