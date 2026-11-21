#lang racket/base

;;; run.rkt — MedAgentBench tasks, one arm at a time.
;;;
;;;   racket -l- fhir-examples/agent-bench/mab/run ARM OUT_DIR [--model M] [--ids a,b | --per-kind N] [--parallel K]
;;;
;;; Arms (how the agent reaches the EHR; everything else is the same):
;;;   rest-hapi       curl against the benchmark's own server (HAPI FHIR, from its Docker image)
;;;   rest-ours       curl against this family's fhir-server over the same data
;;;   workspace       the fhir-mcp workspace verbs (`raco fhir-mcp call …`) over the same data
;;;   mcp             the same verbs as MCP tools (`raco fhir-mcp` as the agent's MCP server)
;;;   workspace-tools the two reading verbs, POST and FINISH as the four tools of one process
;;;                   (tools-server.rkt), and no others: no shell, a one-sentence system prompt, and
;;;                   the session ends when `finish` has the answers
;;; The agent arms share the built-in tools (Bash, Read, Write) and the closing instruction; the
;;; workspace arms get the reading card (`raco fhir guide data`) and may write a POST as FSH.
;;;   official-hapi   the benchmark's own protocol (below) against HAPI
;;;   official-ours   … against our server
;;; In the agent arms a POST is recorded, not sent (`./mab post`), and the answers end the task
;;; (`./mab finish`), as the benchmark's harness does; the prompt is the benchmark's, with the access
;;; added. The official arms are the benchmark's MedAgentBench.start_sample with the model behind
;;; `claude -p`: each turn the model answers one `GET url`, `POST url\n<json>` or `FINISH([...])` and
;;; nothing else, a GET is sent to the server (with `&_format=json`), a POST accepted without being
;;; sent, at most 8 rounds; the conversation goes to history.json.
;;; env: MAB_TASKS, MAB_FUNCS, MAB_STORE (our store, for the workspace arm), MAB_HAPI, MAB_OURS.

(require racket/cmdline racket/file racket/list racket/string racket/port racket/runtime-path racket/system json
         net/http-client
         "../run-agent.rkt" "tasks.rkt")

(define hapi (or (getenv "MAB_HAPI") "http://localhost:8080/fhir/"))
(define ours (or (getenv "MAB_OURS") "http://localhost:8766/"))
(define-runtime-path mab-script "mab")

;; ---- the agent arms --------------------------------------------------------------------------

(define agent-template #<<EOF

How to act here:
- {access}
- A POST is recorded, not sent: write the payload to a file with the Write tool (a heredoc holding braces and quotes is refused here), then run `./mab post <url> <file>`, for example `./mab post {api_base}Observation payload.json`.{fsh} Make only the POSTs the question calls for, before you finish.
- The benchmark's grader reads a medication order's route as plain text, not as the object the function list and FHIR describe: write `"dosageInstruction": [{"route": "IV", "doseAndRate": [...]}]` (or `"oral"`), in a JSON file (FSH cannot say it). A ServiceRequest's `note` is one object, `{"text": "..."}`.
- When you have the answers and have done what was asked, run `./mab finish '<JSON list>'`, the equivalent of FINISH([answer1, answer2, ...]): the list must be JSON-loadable, and holds the answers themselves (values), not sentences. That ends the task: end with one short line, no summary.
Use only the access described here; do not look for the benchmark's files or answers.
EOF
  )

;; the same for an agent whose only tools are tools-server.rkt's: a POST and the answers are tool
;; calls, with no file between
(define tools-template #<<EOF

How to act here:
- {access}
- A POST is recorded, not sent: give `post` the url (for example {api_base}Observation) and the resource, as a JSON object (`payload`) or as one FSH Instance (`fsh`; FHIR R4: `Instance: p` / `InstanceOf: Observation` / `* status = #final` / …), which it compiles, saying where it is wrong. Make only the POSTs the question calls for, before you finish.
- The benchmark's grader reads a medication order's route as plain text, not as the object the function list and FHIR describe: write `"dosageInstruction": [{"route": "IV", "doseAndRate": [...]}]` (or `"oral"`), as a JSON payload (FSH cannot say it). A ServiceRequest's `note` is one object, `{"text": "..."}`.
- When you have the answers and have done what was asked, give them to `finish` as a list, the equivalent of FINISH([answer1, answer2, ...]): the list holds the answers themselves (values: `[123]`, `["S1234567"]`), not sentences, and a measurement is its number, without its unit. That ends the task.
Use only these tools.
EOF
  )

(define (access kind base)
  (case kind
    [(workspace)
     (string-append "Read the EHR through the FHIR workspace in this directory, from the shell; there is no other access to the EHR. "
                    "For example: raco fhir-mcp call query language=search text='Observation?patient=Patient/S1234567&code=MG'\n\n" (reading-card) "\n")]
    [(tools)
     (string-append "Read the EHR through the tools `query` and `describe`; there is no other access to the EHR. "
                    "The card below writes a call as the shell does: `describe ref=X as=fsh` is the describe tool with ref and as.\n\n" (reading-card) "\n")]
    [(mcp)
     (string-append "Read the EHR through the FHIR workspace's tools (mcp__fhir__…); there is no other access to the EHR. "
                    "The card below writes a call as the shell does: `describe ref=X as=fsh` is the describe tool with ref and as.\n\n" (reading-card) "\n")]
    [else (format "Read the EHR with curl, for example: curl -s '~aPatient?identifier=S1234567'. Any FHIR search the server supports works; answers are JSON." base)]))

;; fsh-note : kind -> string   the workspace arms may write a payload as FSH (the reading card's language)
(define (fsh-note kind)
  (if (memq kind '(workspace mcp))
      " The payload may be one FSH Instance in a `.fsh` file instead (FHIR R4: `Instance: p` / `InstanceOf: Observation` / `* status = #final` / …): `./mab post` compiles it and records the JSON, or says where it is wrong."
      ""))

;; the official prompt's opening (up to its three response formats) is not the agent's: an agent acts
;; through tools, so it gets the question, the functions and the context, then how to act here
(define (agent-prompt kind base t)
  (define official (official-prompt base t))
  (define tail (car (regexp-match #rx"(?s:Here is a list of functions.*)$" official)))
  (string-append "You are an expert in using FHIR functions to assist medical professionals. You are given a question and a set of possible functions. Based on the question, you will need to make one or more function/tool calls to achieve the purpose.\n\n"
                 tail
                 (if (eq? kind 'tools)
                     (string-replace (string-replace tools-template "{access}" (access kind base)) "{api_base}" base)
                     (string-replace (string-replace (string-replace agent-template "{access}" (access kind base)) "{fsh}" (fsh-note kind)) "{api_base}" base))))

;; the tools arm: tools-server.rkt (the file beside this one) over the task's workspace, a hook
;; that ends the session when `finish` has the answers, and a system prompt of one sentence in
;; place of the runtime's own
(define-runtime-path tools-server "tools-server.rkt")
(define-runtime-path stop-hook "stop-when-finished.sh")
(define (tools-mcp work)
  (jsexpr->string
   (hasheq 'mcpServers
           (hasheq 'mab (hasheq 'command "racket"
                                'args (list (path->string tools-server) (path->string (path->complete-path work))))))))
(define stop-settings
  (jsexpr->string
   (hasheq 'hooks (hasheq 'PostToolUse (list (hasheq 'matcher "mcp__mab__finish"
                                                      'hooks (list (hasheq 'type "command" 'command (path->string stop-hook)))))))))
(define tools-system
  "You carry out one task in a hospital's records with the tools you are given, following the instructions you are given with it.")

(define (tools kind)
  (if (eq? kind 'tools) '("mcp__mab") (tools* kind)))
(define (tools* kind)
  (append (case kind
            [(workspace) '("Bash(raco fhir-mcp:*)" "Bash(raco fhir guide:*)")]
            [(mcp) '("mcp__fhir" "Bash(raco fhir guide:*)")]
            [else '("Bash(curl:*)")])
          '("Bash(./mab:*)" "Bash(python3:*)" "Bash(jq:*)" "Read" "Write")))

(define (run-agent-task kind base model out t)
  (define work (build-path out (hash-ref t 'id)))
  (define (prepare)
    (copy-file mab-script (build-path work "mab"))
    (file-or-directory-permissions (build-path work "mab") #o755)
    (when (memq kind '(workspace mcp tools))
      (display-to-file (format "fhirVersion: 4.0.1\ndata: ~a\n" (env-path "MAB_STORE")) (build-path work "workspace.yaml"))))
  (define tools? (eq? kind 'tools))
  (define rec (run-item (hash-ref t 'id) (agent-prompt kind base t) work model (tools kind) #:prepare prepare
                        #:builtin (if tools? '() builtin-tools)
                        #:mcp (cond [tools? (tools-mcp work)] [(eq? kind 'mcp) (workspace-mcp work)] [else #f])
                        #:settings (and tools? stop-settings)
                        #:system (and tools? tools-system)))
  ;; the workspace's warm process ends with the task
  (void (system* (find-executable-path "pkill") "-f" (format "mcp-daemon.*~a" work)))
  (define bad (audit rec (list "refsol" "test_data" "funcs_v1" "medagentbench" (path->string out))))
  (unless (null? bad) (display-lines-to-file bad (build-path work "AUDIT") #:exists 'truncate))
  (printf "~a ~as $~a ~a~a\n" (hash-ref t 'id) (hash-ref rec 'seconds) (hash-ref rec 'cost_usd)
          (if (hash? (hash-ref rec 'answer)) "answered" "NO ANSWER") (if (null? bad) "" "  AUDIT"))
  (flush-output)
  (let ([c (hash-ref rec 'cost_usd)]) (if (real? c) c 0)))

;; ---- the official protocol ---------------------------------------------------------------------

;; http-get : url-string -> (values text #f) | (values #f error-text)   as the benchmark's
;; send_get_request: the url sent as the model wrote it (spaces as %20; an unencoded `+` stays one),
;; the body whatever its type, a non-2xx status an error
(define (http-get u)
  (with-handlers ([exn:fail? (lambda (e) (values #f (exn-message e)))])
    (define m (regexp-match #rx"^http://([^/:]+)(?::([0-9]+))?(/.*)?$" u))
    (unless m (error 'GET "not an http url: ~a" u))
    (define-values (status _headers in)
      (http-sendrecv (cadr m) (string-replace (or (cadddr m) "/") " " "%20")
                     #:port (if (caddr m) (string->number (caddr m)) 80)))
    (define body (port->string in))
    (if (regexp-match? #rx#"^HTTP/[0-9.]+ 2" status)
        (values body #f)
        (values #f (format "~a for url: ~a" (bytes->string/utf-8 status) u)))))

(define (run-official-task base model out t)
  (define work (build-path out (hash-ref t 'id)))
  (make-directory* work)
  (define first (official-prompt base t))
  (let loop ([msg first] [session #f] [cost 0] [history (list (hasheq 'role "user" 'content first))] [turns 0])
    (define (finish result status cost history)
      (write-json-file (build-path work "history.json") (reverse history))
      (write-json-file (build-path work "answer.json") (hasheq 'finish (or result (json-null)) 'status status 'cost_usd cost))
      (printf "~a ~a $~a\n" (hash-ref t 'id) status (/ (round (* 1000 cost)) 1000.0)) (flush-output)
      cost)
    (if (= turns 8)
        (finish #f "TASK_LIMIT_REACHED" cost history)
        (let*-values ([(reply session c) (claude-turn work msg model session)]
                      [(history) (cons (hasheq 'role "agent" 'content reply) history)]
                      [(r) (string-trim (string-replace (string-replace reply "```tool_code" "") "```" ""))])
          (define (next m) (loop m session (+ cost c) (cons (hasheq 'role "user" 'content m) history) (add1 turns)))
          (cond
            [(string-prefix? r "GET")
             (define-values (body err) (http-get (string-append (string-trim (substring r 3)) "&_format=json")))
             (next (if body
                       (format "Here is the response from the GET request:\n~a. Please call FINISH if you have got answers for all the questions and finished all the requested tasks" body)
                       (format "Error in sending the GET request: ~a" err)))]
            [(string-prefix? r "POST")
             (define payload (with-handlers ([exn:fail? (lambda (_) #f)])
                               (string->jsexpr (string-join (cdr (string-split r "\n" #:trim? #f)) "\n"))))
             (next (if payload
                       "POST request accepted and executed successfully. Please call FINISH if you have got answers for all the questions and finished all the requested tasks"
                       "Invalid POST request"))]
            [(string-prefix? r "FINISH(")
             (finish (substring r 7 (sub1 (string-length r))) "COMPLETED" (+ cost c) history)]
            [else (finish #f "AGENT_INVALID_ACTION" (+ cost c) history)])))))

;; ---- main ----------------------------------------------------------------------------------------

(module+ main
  (define model "sonnet") (define ids #f) (define per-kind #f) (define parallel 4)
  (define-values (arm out)
    (command-line
     #:once-each
     [("--model") m "model (default sonnet)" (set! model m)]
     [("--ids") i "task ids, comma-separated" (set! ids i)]
     [("--per-kind") n "the first N tasks of each kind" (set! per-kind (string->number n))]
     [("--parallel") k "agents at a time (default 4)" (set! parallel (string->number k))]
     [("--resume") "skip the items that already have a record (a killed run, resumed)" (current-resume? #t)]
     #:args (arm out) (values arm out)))
  (define base (if (member arm '("rest-hapi" "official-hapi")) hapi ours))
  (define dir (path->complete-path out))
  (make-directory* dir)
  (define tasks (select-tasks (mab-tasks) ids per-kind))
  (write-json-file (build-path dir "run.json") (hasheq 'arm arm 'model model 'base base 'tasks (length tasks) 'harness 2))
  (define run-one
    (case arm
      [("rest-hapi" "rest-ours") (lambda (t) (run-agent-task 'rest base model dir t))]
      [("workspace") (lambda (t) (run-agent-task 'workspace base model dir t))]
      [("mcp") (lambda (t) (run-agent-task 'mcp base model dir t))]
      [("workspace-tools") (lambda (t) (run-agent-task 'tools base model dir t))]
      [("official-hapi" "official-ours") (lambda (t) (run-official-task base model dir t))]
      [else (raise-user-error 'run (format "unknown arm ~a: rest-hapi rest-ours workspace mcp workspace-tools official-hapi official-ours" arm))]))
  (define costs (in-parallel parallel tasks run-one))
  (printf "total $~a\n" (/ (round (* 100 (apply + (filter real? costs)))) 100.0)))
