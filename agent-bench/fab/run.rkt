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
;;;   tables-tools  the same tables, examples and checks, the arm's three commands as the three tools
;;;              of one process (tables-server.rkt) and no shell: the agent has those tools alone and
;;;              a system prompt of one sentence
;;;   rest-tools the general route under that same harness (value-experiment/PROTOCOL.md, A1): a
;;;              plain FHIR REST server and Python as the three tools of one process
;;;              (rest-server.rkt: get, python, answer), no shell, the same system prompt.
;;;              FAB_PREPARED, when set, is what a preparing agent left for it: its PROMPT.md is
;;;              added to the prompt, the directory is on Python's module path
;;; Every arm has the same built-in tools (Bash, Read, Write: `--tools`), and the same closing
;;; instruction; the workspace arms get the reading card (`raco fhir guide data`) where the rest
;;; arm gets its curl lines.
;;; Each agent writes answer.json {"answer", "resources": ["Type/id", …]}; the run writes
;;; agent_results.json in the benchmark's input format for its evaluation_metrics.py (score.sh).

(require racket/cmdline racket/file racket/list racket/string racket/system racket/port racket/runtime-path json
         "../run-agent.rkt")

;; prompt : arm rest-base Question answer-file -> string   (below) is what an agent is given
(provide prompt)

(define common #<<EOF
You are answering a question about a patient from a hospital dataset held as FHIR R4 resources (about 930,000 of them: Patient, Encounter, Observation, Condition, Procedure, Medication, MedicationRequest, MedicationAdministration, MedicationDispense, MedicationStatement, Specimen, Location, Organization). The dates are shifted far into the future on purpose.

Question: {question}
Assumption: {assumption}
The patient: Patient/{patient_fhir_id} (the number in the question is that patient's hospital identifier).

Find the answer in the data and note which resources it rests on. Answer as a clinician's assistant would: a value with its unit, a date-time, a name, a count, yes/no — or "none" when the data holds nothing that answers the question (a legitimate answer; do not guess). "Hospital visit", "hospital stay" and "hospital encounter" mean an inpatient hospital admission; "ICU visit" an intensive-care stay; "current hospital visit" one that has not ended at the assumed current time.

{written}

{access}
{only}
EOF
  )

;; common-tools : string   the opening for an agent that has the tables' tools alone: the question,
;; the two words the questions use for a stay, and where the answer goes. What the other arms'
;; opening says of FHIR resources and of how to word an answer is not this arm's: the `answer`
;; tool states the answer, and its instructions say what "current" is.
(define common-tools #<<EOF
You are answering a question about a patient from a hospital's records. The dates are shifted far into the future on purpose.

Question: {question}
Assumption: {assumption}

"Hospital visit", "hospital stay" and "hospital encounter" mean an inpatient hospital admission; "ICU visit" an intensive-care stay.

{written}

{access}
{only}
EOF
  )

;; written, only : arm -> string   how the answer file comes to be, and what the agent may use
(define (written arm)
  (if (tools-arm? arm)
      "The `answer` tool writes the answer and the resources it rests on to {answer_file}. Once it is written you are done: end with one short line, no summary."
      "When done, write {answer_file}: {\"answer\": \"<your answer>\", \"resources\": [\"Type/id\", ...the resources the answer rests on]}. Once it is written you are done: end with one short line, no summary."))
(define (only arm)
  (if (tools-arm? arm)
      "Use only those tools to read the data."
      "Use only that access to read the data; you may use python3 or jq to compute over what it returned. Do not look for the benchmark's files or answers."))

;; tables-arm? : arm -> boolean   an arm that answers over the tables
(define (tables-arm? arm) (and (member arm '("tables" "tables-tools")) #t))

;; tools-arm? : arm -> boolean   an arm whose agent has the tools of one process and nothing else
(define (tools-arm? arm) (and (member arm '("tables-tools" "rest-tools")) #t))

;; ---- the tables arms' instructions ------------------------------------------------------------------
;; The same three steps in two wordings (`tools?`): the commands of a shell, or the tools of
;; tables-server.rkt.

;; kinds-list : -> string   the kinds of question, numbered (make-examples.rkt's kinds.md)
(define (kinds-list)
  (string-append "People who compute against this schema write each kind of question's query one way. The kinds (a kind's slots in braces and brackets):\n"
                 (examples-file "kinds.md")))

;; short-kinds-list : -> string   the same list for an agent with the tools, whose every call
;; re-reads it: without what every kind says ("patient {patient}" is P, "of P" is left out) or
;; nearly every one (its time, `[when]`), a slot named by one word. 1.0k tokens where the list
;; is 1.5k; the `kind` tool shows a kind whole.
(define (short-kinds-list)
  (string-append "People who compute against this schema write each kind of question's query one way. The kinds (a kind's slots in braces and brackets; each is asked of one patient, P, and most within a time — \"since 2100\", \"on the last hospital visit\" — which the list leaves out):\n"
                 (string-join (map short-kind (string-split (examples-file "kinds.md") "\n")) "\n")))

;; short-kind : string -> string   one line of kinds.md, shortened
(define (short-kind line)
  (for/fold ([l line])
            ([from+to (in-list '((#rx" \\[when[0-9]*\\]" "")
                                 (#rx" of patient {patient}" "")
                                 (#rx"patient {patient}" "P")
                                 (#rx"{([a-z]+)_name([0-9]*)}" "{\\1\\2}")
                                 (#rx"{vital_value}" "{value}")
                                 (#rx"{drug_route}" "{route}")))])
    (regexp-replace* (car from+to) l (cadr from+to))))

;; step-1 : boolean -> string   picking the kind, looking the names up: with a shell the agent
;; asks the tables for each name; with the tools it gives the names to `kind`, which asks
(define (step-1 tools?)
  (string-append
   "1. Read the example of your question's kind. When none is your question, take the nearest by what is asked for first — a yes/no question's example selects a comparison (`COUNT(*)>0`), a \"when\" or \"list the times\" question's the time column, \"how many\" a count, \"how much\" a sum or the value — and then by what it reads. When no kind's example selects what your question asks for (the name of a test, where the examples give a specimen's or an organism's), the nearest example still gives the conditions and the order, and you select the schema's column that holds what is asked. "
   (if tools?
       "In the same call give `kind`, as `names`, each name your question gives — a lab test, a drug, an output, a care unit, a specimen, a procedure — worded as the question words it: the tables have it as the hospital writes it, capitals included, and the question gives it in lower case, where it can read like ordinary words (\"or urine\" is the output `OR Urine`, not urine outputs). `kind` answers how the tables write each one.\n"
       "In the same command, look up each name your question gives — a lab test, a drug, an output, a care unit, a specimen: the tables have it as the hospital writes it, capitals included, and the question gives it in lower case, where it can read like ordinary words (\"or urine\" is the output `OR Urine`, not urine outputs). Ask for the name exactly as the question words it, case aside: `SELECT DISTINCT drug FROM prescriptions WHERE lower(trim(drug)) = '5% dextrose'`. Use every spelling that returns (`drug IN ('Amlodipine', 'amLODIPine')`); search by pattern (`LIKE`) only when it returns nothing.\n")))

;; step-2 : -> string   the query, written from the example
(define (step-2)
  (string-append
   "2. Copy the example's query whole and change only three things: the patient's number; the names and values (spelled as the tables have them); the time conditions (take out the example's, put in one for each time phrase of your question — \"today\", \"since 09/2116\", \"on the last ICU visit\" — written as the list under the example writes it, on the column the example uses). Change nothing else: not how the visit is chosen, not the SELECT (unless no example selects what is asked, as in step 1), not the ORDER BY or LIMIT, and add no condition of your own. Three readings to keep:\n"
   "   - \"Current\" is what has no end recorded, and only that. A current hospital visit (\"this hospital stay\", \"this admission\", \"since admission\") is `admissions.dischtime IS NULL`; a current ICU stay (\"this ICU encounter\", \"the current ICU visit\") is `icustays.outtime IS NULL`. Time elapsed since an admission (\"how many hours since the patient was admitted\", to the hospital or to the ICU) is asked of the current one. The people who use this schema do not call a visit current once its end is recorded, whatever the assumed current time is.\n"
   "   - \"Last year\", \"in the last year\", \"the previous month\", \"yesterday\" name the calendar year, month or day before the current one (`datetime(x,'start of year') = datetime(<now>,'start of year','-1 year')`), not the twelve months, thirty days or twenty-four hours up to now. Only \"since N years/months/days ago\" counts back from now.\n"
   "   - When a visit or a stay *was* is when it began (`admittime`, `intime`), and the first or last visit is the first or last to begin; its end is asked for as a discharge or a leaving.\n"))

;; step-3 : boolean -> string   the query given to the answer command, and what it says back
(define (step-3 tools?)
  (string-append
   (if tools?
       "3. Give it to `answer`, with `kind` the number of the example you copied. It prints the rows;"
       "3. Run it with `./answer --kind <number> \"SELECT …\"` (the number of the example you copied). It prints the rows;")
   " states the answer as the people who use this schema state one — the value alone (`61.7`, `-1`, `2133-12-31 02:00:00`, `EW EMER.`), every row's value in the order returned when there are several, `yes`/`no` for a comparison, and \"none: nothing on record\" when the query returns no row, a null or a count of 0; finds the resources the answer rests on (the rows of the query's table that meet its conditions, each row's `fhir_id` columns); and writes both to the answer file. Each `note:` it prints names something to look at again: a shape that is not the example's, a phrase of your question (\"today\", \"this hospital stay\", \"daily\") with no condition for it, a name the question does not give or one it gives that the query leaves out, a first or last row with no value, a value selected where the question asks whether something is so, a time selected where it does not ask when. Unless a note is plainly mistaken, correct the query and run it again. When it says `NOT written`, there is no answer file yet: correct the query and run it again. When it ends with `done:`, the answer stands and the session ends there. Otherwise you are done: do not rewrite the file, do not add a unit, a date or an explanation, and do not look for another reading of the question that would return something. "
   (if tools?
       "(Only when the answer it states is not what the rows say, give the same query once more with the answer said, as `say`.)"
       "(Only when the answer it states is not what the rows say, run the same query once more with the answer said: `./answer --kind <number> --say \"<the answer>\" \"SELECT …\"`.)")))

;; next-steps : -> string   the schema, and steps 2 and 3, for an agent with the tools: said by
;; the `kind` tool with the first example it shows (tables-workspace! writes it to
;; examples/next.md). The first call picks a kind and gives the names, which needs neither.
(define (next-steps)
  (string-append (schema-lines) "\n\n"
                 "What to do next (steps 2 and 3). Write a query whole, a condition that occurs twice written out twice.\n"
                 (step-2) (step-3 #t)))

(define (access arm rest)
  (case arm
    [("workspace")
     (string-append "Access: the FHIR workspace in this directory, from the shell. Its data is this dataset (a store).\n\n"
                    (reading-card))]
    [("tables")
     (string-append
      "Access: the dataset as the tables of a relational schema, in this directory's workspace (the tables are defined over the FHIR data):\n"
      "  raco fhir-mcp call query language=sql text=\"SELECT …\"      one SQLite statement; rows come back as JSON\n"
      "  ./kind <number> [<number> …]                               how a kind of question is answered (below)\n"
      "  ./answer --kind <number> \"SELECT …\"                        the query that answers the question: its rows, the answer, the resources behind it — written to the answer file\n"
      "Each command line is checked before it runs, and only plain ones pass: these three commands and `cat`/`grep` on the examples, several joined by `;`. A shell variable (`C=…`), `$(…)`, a here-document or a script is refused and costs you the turn. Write the whole query inside the quotes, a condition that occurs twice written out twice.\n\n"
      (tables-schema) "\n\n"
      (kinds-list) "\n\n"
      "`./kind <number>` shows a kind: a question or two of that kind, what each assumes, the query that answers it, and then how each time phrase is written in such a query.\n\n"
      "Work like this:\n"
      (step-1 #f) (step-2) (step-3 #f))]
    [("tables-tools")
     ;; what the first call needs: the tools, the kinds, how to pick one and which names to
     ;; give. The schema, and how to write the query and give it to `answer`, come with the
     ;; example (`next-steps`, which the `kind` tool says once): in the prompt they were read
     ;; again in every call
     (string-append
      ;; what each tool does is its definition's to say: said here as well it was read four
      ;; times a question
      "Access: the dataset as the tables of a relational schema (the tables are defined over the FHIR data), through your three tools: `kind`, `answer` and `sql`.\n\n"
      (short-kinds-list) "\n\n"
      "Work like this:\n"
      (step-1 #t)
      "2 and 3. Write your query from the example and give it to `answer`: `kind` says how, and gives the schema, with the first example it shows. Do as it says there.")]
    [("rest-tools")
     (string-append
      "Access: a FHIR R4 REST server, through your three tools: `get`, `python` and `answer`.\n"
      "  metadata                      the types and the search parameters of each\n"
      "  <Type>/<id>                   read one resource\n"
      "  <Type>?<param>=<value>&...    search: a Bundle (`total`, `entry`, a `next` link when it is a page)\n"
      "Standard FHIR search applies: _count, _sort (-date descending), _summary=count, date prefixes (date=ge2130-01-01), token system|code, :text, references (patient=Patient/<id>), _include. Read and search are all the server offers."
      (prepared-prompt))]
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
  (for/fold ([s (string-replace (for/fold ([s (if (equal? arm "tables-tools") common-tools common)]) ([part (list (cons "{written}" (written arm)) (cons "{only}" (only arm))
                                                                    (cons "{access}" (access arm rest)))])
                                  (string-replace s (car part) (cdr part)))
                                "{answer_file}" answer-file)])
            ([k '(question assumption patient_fhir_id)])
    (string-replace s (format "{~a}" k) (hash-ref q k))))

;; ---- the `rest-tools` arm ----------------------------------------------------------------------
;; prepared-dir : -> (or/c #f string)   what a preparing agent left for the general route
;; (FAB_PREPARED): notes, Python modules, and PROMPT.md, its words to the question agents
(define (prepared-dir)
  (define d (getenv "FAB_PREPARED"))
  (and d (not (string=? d "")) (path->string (path->complete-path d))))

;; prepared-prompt : -> string   PROMPT.md of the prepared directory, to follow the access text
(define (prepared-prompt)
  (define d (prepared-dir))
  (define f (and d (build-path d "PROMPT.md")))
  (if (and f (file-exists? f)) (string-append "\n\n" (string-trim (file->string f))) ""))

;; rest-mcp : dir string -> string   an MCP configuration: rest-server.rkt over the question's
;; directory and the FHIR server
(define-runtime-path rest-server "rest-server.rkt")
(define (rest-mcp work rest)
  (jsexpr->string
   (hasheq 'mcpServers
           (hasheq 'rest (hasheq 'command "racket"
                                 'args (append (list (path->string rest-server) (path->string (path->complete-path work)) rest)
                                               (let ([d (prepared-dir)]) (if d (list d) '()))))))))

;; ---- the `tables` arm ---------------------------------------------------------------------------
;; tables-schema : -> string   the schema's tables and columns (schema.md's table), for the prompt
(define-runtime-path schema-file "schema.md")
(define (tables-schema)
  (string-append "The schema (a time is text, `YYYY-MM-DD HH:MM:SS`; an identifier an integer):\n"
                 (string-join (filter (lambda (l) (regexp-match? #rx"^[|]" l)) (file->lines schema-file)) "\n")))

;; schema-lines : -> string   the same schema a line a table (schema-lines.md), for an agent
;; with the tools: 0.8k tokens where the table is 1.5k (its pipes and backticks, and a meaning
;; said for every column, where most columns' names say theirs)
(define-runtime-path schema-lines-file "schema-lines.md")
(define (schema-lines) (string-trim (file->string schema-lines-file)))

;; schema-columns : string -> (listof (cons string (listof string)))   the tables and their
;; columns a schema text names, as written: the table's rows, or the lines
(define (schema-columns text)
  (define rows
    (for/fold ([acc '()]) ([l (in-list (string-split text "\n"))])
      (cond
        [(regexp-match #rx"^[|] *(`[a-z_]+`)? *[|]([^|]*)[|]" l)
         => (lambda (m)
              (define cols (regexp-match* #rx"`([a-z_]+)`" (caddr m) #:match-select cadr))
              (cond [(cadr m) (cons (cons (substring (cadr m) 1 (sub1 (string-length (cadr m)))) cols) acc)]
                    [(pair? acc) (cons (cons (caar acc) (append (cdar acc) cols)) (cdr acc))]
                    [else acc]))]
        [(regexp-match #rx"^([a-z_]+): (.*)$" l)
         => (lambda (m)
              (define without-notes (regexp-replace* #rx" [(][^()]*[)]" (caddr m) ""))
              (cons (cons (cadr m) (map string-trim (string-split without-notes ","))) acc))]
        [else acc])))
  (reverse rows))

;; examples-dir : -> path   what make-examples wrote (FAB_EXAMPLES): kinds.md, phrases.md, <n>.md
(define (examples-dir) (or (getenv "FAB_EXAMPLES") (error 'run "set FAB_EXAMPLES to the directory make-examples wrote")))
(define (examples-file name) (string-trim (file->string (build-path (examples-dir) name))))

;; kind-script : string   `./kind N…`: each kind's examples, then how a time phrase is written
(define kind-script
  (string-append
   "#!/bin/sh\n"
   "for n in \"$@\"; do if [ -f \"examples/$n.md\" ]; then cat \"examples/$n.md\"; echo; else echo \"there is no kind $n\"; fi; done\n"
   "echo 'How a time phrase is written in such a query (with your column and your current time in place of the ones shown):'\n"
   "cat examples/phrases.md; echo\n"))

;; tables-workspace! : dir question -> void   the question's workspace: the tables the setup agent defined
;; (FAB_TABLES: its views and `.sql` files), the rows it already computed (a link to its kept
;; views: a view over the Observations takes minutes to compute), the worked examples with
;; the checks read from the train split (query-checks.rkt), the question (for those checks),
;; `./answer` (answer.rkt: the query run, the answer and its resources written) and `./kind` (the
;; examples of the kinds asked for, then the time phrases once: in the prompt they were in every
;; turn's context, and after each example they came once for each kind read)
(define (tables-workspace! work q [arm "tables"])
  (define from (or (getenv "FAB_TABLES") (error 'run "set FAB_TABLES to the workspace setup-tables wrote")))
  (for ([f (in-list (directory-list from))]
        #:when (regexp-match? #rx"[.](view[.]json|sql|yaml)$" (path->string f)))
    (copy-file (build-path from f) (build-path work f) #t))
  (make-directory* (build-path work "examples"))
  (for ([f (in-list (directory-list (examples-dir)))] #:when (regexp-match? #rx"^([0-9]+|phrases)[.]md$" (path->string f)))
    (copy-file (build-path (examples-dir) f) (build-path work "examples" f) #t))
  (for ([name (in-list '("checks.json" "phrases.json"))] #:when (file-exists? (build-path (examples-dir) name)))
    (copy-file (build-path (examples-dir) name) (build-path work "examples" name) #t))
  ;; what the `kind` tool says with the first example it shows
  (when (equal? arm "tables-tools")
    (display-to-file (next-steps) (build-path work "examples" "next.md") #:exists 'truncate))
  (call-with-output-file (build-path work "question.json") #:exists 'truncate
    (lambda (o) (write-json (hasheq 'question (hash-ref q 'question) 'assumption (hash-ref q 'assumption "")) o)))
  (display-to-file "#!/bin/sh\nexec racket -l- fhir-examples/agent-bench/fab/answer \"$@\"\n" (build-path work "answer") #:exists 'truncate)
  (file-or-directory-permissions (build-path work "answer") #o755)
  (display-to-file kind-script (build-path work "kind") #:exists 'truncate)
  (file-or-directory-permissions (build-path work "kind") #o755)
  (make-directory* (build-path work ".fhir-mcp"))
  (make-file-or-directory-link (path->complete-path (build-path from ".fhir-mcp" "views.db")) (build-path work ".fhir-mcp" "views.db")))

(define (tools arm)
  (append (case arm
            [("workspace") '("Bash(raco fhir-mcp:*)" "Bash(raco fhir guide:*)")]
            [("tables") '("Bash(raco fhir-mcp:*)" "Bash(./answer:*)" "Bash(./kind:*)" "Bash(cat:*)" "Bash(grep:*)")]
            [("tables-tools") '("mcp__tables")]
            [("rest-tools") '("mcp__rest")]
            [("mcp") '("mcp__fhir" "Bash(raco fhir guide:*)")]
            [else '("Bash(curl:*)")])
          (if (tools-arm? arm) '() '("Bash(python3:*)" "Bash(jq:*)"))
          (if (or (tables-arm? arm) (tools-arm? arm)) '() '("Read" "Write"))))

;; stop-settings : arm -> string   Claude Code settings whose one hook ends a tables session when
;; `./answer` (the `answer` tool) says it is done (stop-when-answered.sh): three in four sessions had nothing left to
;; do then but be asked again, with the whole conversation, and say so
(define-runtime-path stop-hook "stop-when-answered.sh")
(define (stop-settings arm)
  (jsexpr->string
   (hasheq 'hooks (hasheq 'PostToolUse (list (hasheq 'matcher (case arm [("tables-tools") "mcp__tables__answer"] [("rest-tools") "mcp__rest__answer"] [else "Bash"])
                                                      'hooks (list (hasheq 'type "command" 'command (path->string stop-hook)))))))))

;; builtin : arm -> (listof string)   the built-in tools an arm's agent has at all. Each tool's
;; definition is in every turn's context (Read and Write: about 950 tokens a turn), and the tables
;; arm needs neither: `./answer` writes the answer file, `cat` reads an example.
(define (builtin arm)
  (case arm
    [("tables") '("Bash")]
    [("tables-tools" "rest-tools") '()]
    [else builtin-tools]))

;; tables-mcp : dir -> string   an MCP configuration: tables-server.rkt (the file beside this
;; one, so a copy of the harness runs its own) over the question's workspace
(define-runtime-path tables-server "tables-server.rkt")
(define (tables-mcp work)
  (jsexpr->string
   (hasheq 'mcpServers
           (hasheq 'tables (hasheq 'command "racket"
                                   'args (list (path->string tables-server) (path->string (path->complete-path work))))))))

;; tools-system : string   the system prompt of an agent that has the three tools and nothing else,
;; in place of the runtime's own (about 1.5k tokens in every call, about working in a code base)
(define tools-system
  "You answer one question about a hospital's records with the tools you are given, following the instructions you are given with it.")


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
  (unless (member arm '("rest" "rest-tools" "workspace" "mcp" "tables" "tables-tools"))
    (raise-user-error 'run "the arm is rest, rest-tools, workspace, mcp, tables or tables-tools"))
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
      (when (tables-arm? arm) (tables-workspace! work q arm)))
    (define rec (run-item id (lambda (real) (prompt arm rest q (path->string (build-path real "answer.json")))) work model (tools arm)
                          #:prepare prepare #:builtin (builtin arm)
                          #:settings (and (or (tables-arm? arm) (tools-arm? arm)) (stop-settings arm))
                          #:mcp (case arm [("mcp") (workspace-mcp work)] [("tables-tools") (tables-mcp work)]
                                  [("rest-tools") (rest-mcp work rest)] [else #f])
                          #:system (and (tools-arm? arm) tools-system)))
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
                (hasheq 'Observation '("a" "c") 'Encounter '("b")))
  ;; the general route under the tools' harness: the question as the other FHIR arms get it, the
  ;; server through three tools, the answer written by one of them, no shell and no files
  (let* ([q (hasheq 'question "Q?" 'assumption "A." 'patient_fhir_id "p1")]
         [text (prompt "rest-tools" "http://localhost:8765" q "/w/answer.json")])
    (check-regexp-match #rx"^You are answering a question about a patient from a hospital dataset held as FHIR R4 resources" text)
    (check-regexp-match #rx"The `answer` tool writes the answer and the resources it rests on to /w/answer.json" text)
    (check-regexp-match #rx"through your three tools: `get`, `python` and `answer`" text)
    (check-regexp-match #rx"Use only those tools to read the data.$" text)
    (check-false (regexp-match? #rx"curl|jq" text)))
  (check-equal? (tools "rest-tools") '("mcp__rest"))
  (check-equal? (builtin "rest-tools") '())
  (check-regexp-match #rx"mcp__rest__answer" (stop-settings "rest-tools"))
  (check-regexp-match #rx"mcp__tables__answer" (stop-settings "tables-tools"))
  ;; with the tools the names go to `kind`, and the schema comes with the first example; with a
  ;; shell the agent asks the tables for each name
  (check-regexp-match #rx"give `kind`, as `names`, each name your question gives" (step-1 #t))
  (check-false (regexp-match? #rx"SELECT DISTINCT drug" (step-1 #t)))
  (check-regexp-match #rx"SELECT DISTINCT drug FROM prescriptions WHERE lower[(]trim[(]drug[)][)] = '5% dextrose'" (step-1 #f))
  (check-regexp-match #rx"^The schema [(].*\npatients: subject_id, gender [(]`M` or `F`[)]\n.*

What to do next [(]steps 2 and 3[)]" (next-steps))
  ;; the two writings of the schema name the same tables and columns
  (check-equal? (schema-columns (schema-lines)) (schema-columns (tables-schema)))
  (check-equal? (length (schema-columns (tables-schema))) 15)
  (check-equal? (car (schema-columns "| `patients` | `subject_id` | the patient's number |\n| | `gender` | `M` or `F` |"))
                '("patients" "subject_id" "gender"))
  ;; the kinds as the tools arm's prompt lists them
  (check-equal? (short-kind "1. When was the [first/last] time that the {vital_name} of patient {patient} was [less/greater] than {vital_value} [when]?")
                "1. When was the [first/last] time that the {vital} was [less/greater] than {value}?")
  (check-equal? (short-kind "13. When was patient {patient}'s [first/last] {spec_name} microbiology test [when]?")
                "13. When was P's [first/last] {spec} microbiology test?")
  (check-equal? (short-kind "2. Has patient {patient} been prescribed {drug_name1}, {drug_name2}, or {drug_name3} [when]?")
                "2. Has P been prescribed {drug1}, {drug2}, or {drug3}?")
  (check-equal? (short-kind "15. What was the name of the drug that patient {patient} was [first/last] prescribed via {drug_route} route [when]?")
                "15. What was the name of the drug that P was [first/last] prescribed via {route} route?")
  ;; step 3 says what each note is about before the query is written: left out, five sessions
  ;; in 150 more wrote what a note then held (a time where the question asks whether)
  (check-regexp-match #rx"a time selected where it does not ask when" (step-3 #t)))
