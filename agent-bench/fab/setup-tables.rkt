#lang racket/base

;;; setup-tables.rkt — one agent, given FHIR-AgentBench's relational schema and the FHIR store,
;;; defines the schema's tables in a workspace.
;;;
;;;   racket -l- fhir-examples/agent-bench/fab/setup-tables [--model M] [--timeout SECONDS] [--max-turns N] OUT_DIR
;;;   racket -l- fhir-examples/agent-bench/fab/setup-tables --amend FROM_WORKSPACE "<what to change>" OUT_DIR
;;;       a second agent, in a copy of a workspace the first one wrote, makes one stated change
;;;       and holds the tables to the same queries
;;;
;;; The benchmark's answers are SQL over MIMIC-IV's tables (schema.md); its agents get the same data
;;; as FHIR. This stage is the step between: an agent that has the schema and the workspace's guides
;;; writes ViewDefinitions (`*.view.json`) and tables over them (`*.sql`) until the benchmark's own
;;; train-split queries, asked of the workspace unchanged, give the benchmark's answers
;;; (check-tables.rkt, which it runs as `./check`). What it wrote is OUT_DIR/workspace; record.json
;;; there has what the session cost and every command it ran.
;;;
;;; The question agents (run.rkt, arm `tables`) then answer over a copy of that workspace.
;;;
;;;   FAB_STORE: the store (a fhir-server SQLite file of MIMIC-IV on FHIR)
;;;   FAB_REPO:  a checkout of github.com/glee4810/FHIR-AgentBench

(require racket/cmdline racket/file racket/string racket/runtime-path json
         "../run-agent.rkt")

(define-runtime-path schema-file "schema.md")

(define task #<<EOF
You are setting up a FHIR workspace so that a relational schema can be queried directly.

The data is a hospital dataset held as FHIR R4 resources in this directory's workspace (a store of about 930,000 resources: Patient, Encounter, Observation, Condition, Procedure, Medication, MedicationRequest, Specimen, Location and more). Other people compute against the relational schema below. Your job: define every table of that schema over the FHIR data, as files in this directory, so that a query written for the schema runs as it stands.

How: read `raco fhir guide tables` first (the two kinds of file, the steps, what goes wrong), then `raco fhir guide sql-on-fhir` for ViewDefinitions and `raco fhir guide data` for looking at the store. Every `raco fhir-mcp call …` runs in this directory.

How you know a table is right: `./check` asks this workspace queries that were written for the schema and compares each answer with the known one.
  ./check --table labevents --show 5     the queries whose main table is labevents; the first 5 failures of each kind, with the query, the expected answer and yours
  ./check --limit 300                    the first 300 queries of every table
  ./check                                all of them (several minutes)
Work one table at a time, smallest first (patients, admissions, icustays, transfers, then the others). A query usually reads several tables: `admissions` is in nearly all of them.

Time: a view over a few thousand resources is computed in seconds. A view over the Observations (more than 800,000) takes about three minutes the first time it is used and each time its text changes, so decide its columns before you run it, and keep renames, casts and joins in the `.sql` files, which cost nothing to change. Give such a command a timeout of 10 minutes.

Stop when every table is defined and the failures that remain are ones the FHIR data cannot answer (say which, and why). Do not change `check` or look for the queries' answers anywhere but in what `./check` prints.

When done, write {answer_file}: {"tables": ["<each table you defined>"], "passing": "<n>/<m> as the last full ./check printed", "unresolved": [{"table": "…", "what": "…", "why": "…"}]}. Then end with one short line.

## The schema

{schema}
EOF
  )

;; the task of an agent that changes tables already defined
(define amend-task #<<END
This directory is a FHIR workspace in which the tables of a relational schema are already defined over a hospital's FHIR data: ViewDefinitions (`*.view.json`, each one resource type flattened) and tables defined over them (`*.sql`). `raco fhir guide tables` explains the two kinds of file. Every `raco fhir-mcp call …` runs in this directory.

Make this change: {change}

`./check` asks the workspace queries written for the schema and compares each answer with the known one (`./check --table labevents --show 5` for one table's queries; `./check` for all, a few minutes). Before your change {passing} of them pass; after it the same ones must.

Time: a `.sql` file costs nothing to change. A view over the Observations (more than 800,000) takes about three minutes to compute again when its text changes, so change such a view only if you must, and give such a command a timeout of 10 minutes.

When done, write {answer_file}: {"changed": ["<each file you changed>"], "passing": "<n>/<m> as the last full ./check printed", "notes": "<anything a user of the tables should know>"}. Then end with one short line.

## The schema

{schema}
END
  )

(module+ main
  (define model "sonnet")
  (define timeout 14400)
  (define max-turns 400)
  (define amend #f)                                   ; (cons from-workspace change) | #f
  (define out
    (command-line
     #:program "setup-tables"
     #:once-each
     [("--model") m "model (default sonnet)" (set! model m)]
     [("--timeout") s "seconds the agent may take (default 14400)" (set! timeout (string->number s))]
     [("--max-turns") n "turns the agent may take (default 400)" (set! max-turns (string->number n))]
     [("--amend") from change "start from the workspace FROM and make one stated change" (set! amend (cons from change))]
     #:args (out-dir) out-dir))
  (define store (or (getenv "FAB_STORE") (raise-user-error 'setup-tables "FAB_STORE names the store")))
  (define repo (or (getenv "FAB_REPO") (raise-user-error 'setup-tables "FAB_REPO names a checkout of FHIR-AgentBench")))
  (define work (build-path (path->complete-path out) "workspace"))
  (define schema (string-trim (regexp-replace #px"\n`check-tables.rkt`[^\n]*\n?$" (file->string schema-file) "")))
  ;; prepare : -> void   the workspace over the store, and `./check`: the benchmark's train-split
  ;; queries asked of this directory
  (define (prepare)
    ;; amending: the first agent's files, and the rows it had computed (kept by their place in the
    ;; workspace, so the copy reads them)
    (when amend
      (define from (path->complete-path (car amend)))
      (for ([f (in-list (directory-list from))] #:when (regexp-match? #rx"[.](view[.]json|sql)$" (path->string f)))
        (copy-file (build-path from f) (build-path work f) #t))
      (make-directory* (build-path work ".fhir-mcp"))
      (copy-file (build-path from ".fhir-mcp" "views.db") (build-path work ".fhir-mcp" "views.db") #t))
    (display-to-file (format "fhirVersion: 4.0.1\ndata: ~a\n" (path->complete-path store)) (build-path work "workspace.yaml") #:exists 'truncate)
    (define check (build-path work "check"))
    (display-to-file
     (format "#!/bin/sh\n# the schema's own queries (the benchmark's train split) asked of this workspace\nFAB_REPO='~a' exec racket -l- fhir-examples/agent-bench/fab/check-tables --split train \"$@\" \"$(dirname \"$0\")\"\n"
             (path->complete-path repo))
     check)
    (file-or-directory-permissions check #o755))
  (define rec
    (run-item "workspace"
              (lambda (dir)
                (define passing
                  (and amend
                       (let ([a (with-handlers ([exn:fail? (lambda (_) (hasheq))])
                                  (call-with-input-file (build-path (car amend) "answer.json") read-json))])
                         (hash-ref a 'passing "most"))))
                (for/fold ([t (if amend amend-task task)])
                          ([kv (list (cons "{schema}" schema)
                                     (cons "{answer_file}" (path->string (build-path dir "answer.json")))
                                     (cons "{change}" (if amend (cdr amend) ""))
                                     (cons "{passing}" (or passing "")))])
                  (string-replace t (car kv) (cdr kv))))
              work model
              '("Bash(raco fhir-mcp:*)" "Bash(raco fhir guide:*)" "Bash(./check:*)" "Bash(python3:*)" "Bash(jq:*)" "Read" "Write" "Edit")
              #:prepare prepare #:timeout timeout #:max-turns max-turns
              ;; a first query over a view of the Observations takes minutes
              #:env '(("BASH_DEFAULT_TIMEOUT_MS" . "900000") ("BASH_MAX_TIMEOUT_MS" . "1800000"))))
  (printf "~a  ~a s, ~a turns, $~a\n" (if (hash? (hash-ref rec 'answer)) (jsexpr->string (hash-ref rec 'answer)) (hash-ref rec 'error))
          (hash-ref rec 'seconds) (hash-ref rec 'turns) (hash-ref rec 'cost_usd)))
