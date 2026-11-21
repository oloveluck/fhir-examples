#lang racket/base

;;; tasks.rkt — MedAgentBench's tasks, functions and prompt, as the runners read them.
;;;
;;; The task file (test_data_v2.json) and the function list (funcs_v1.json) are the benchmark's, found
;;; through MAB_TASKS and MAB_FUNCS. A Task is the benchmark's hasheq: id ("task3_17"), instruction,
;;; context, sol (some kinds), eval_MRN.

(require racket/contract racket/list racket/string json)

(provide
 (contract-out
  [mab-tasks (-> (listof hash?))]
  [mab-funcs (-> list?)]
  [task-kind (-> hash? string?)]
  ;; first-of-each : tasks n -> tasks   the first n tasks of each kind (task1 … task10), in file order
  [first-of-each (-> (listof hash?) exact-positive-integer? (listof hash?))]
  ;; select-tasks : tasks ids-or-#f n-or-#f -> tasks
  [select-tasks (-> (listof hash?) (or/c #f string?) (or/c #f exact-positive-integer?) (listof hash?))]
  ;; official-prompt : api-base task -> string   the benchmark's MedAgentBench_prompt, filled
  [official-prompt (-> string? hash? string?)]
  ;; functions-text : functions -> string   a function list as the benchmark's prompt writes it
  [functions-text (-> list? string?)]
  [function-outline (-> hash? string?)]
  [env-path (-> string? string?)]))

(define (env-path name)
  (or (getenv name) (error 'mab "set ~a" name)))

(define (mab-tasks) (call-with-input-file (env-path "MAB_TASKS") read-json))
(define (mab-funcs) (call-with-input-file (env-path "MAB_FUNCS") read-json))
(define (task-kind t) (car (string-split (hash-ref t 'id) "_")))

(define (first-of-each tasks n)
  (define-values (kept _)
    (for/fold ([kept '()] [count (hash)]) ([t (in-list tasks)])
      (define k (task-kind t))
      (define c (add1 (hash-ref count k 0)))
      (values (if (<= c n) (cons t kept) kept) (hash-set count k c))))
  (reverse kept))

(define (select-tasks tasks ids per-kind)
  (cond [ids (let ([want (string-split ids ",")]) (filter (lambda (t) (member (hash-ref t 'id) want)) tasks))]
        [per-kind (first-of-each tasks per-kind)]
        [else tasks]))

;; the benchmark's own prompt (src/server/tasks/medagentbench/__init__.py), word for word
(define official-template #<<EOF
You are an expert in using FHIR functions to assist medical professionals. You are given a question and a set of possible functions. Based on the question, you will need to make one or more function/tool calls to achieve the purpose.

1. If you decide to invoke a GET function, you MUST put it in the format of
GET url?param_name1=param_value1&param_name2=param_value2...

2. If you decide to invoke a POST function, you MUST put it in the format of
POST url
[your payload data in JSON format]

3. If you have got answers for all the questions and finished all the requested tasks, you MUST call to finish the conversation in the format of (make sure the list is JSON loadable.)
FINISH([answer1, answer2, ...])

Your response must be in the format of one of the three cases, and you can call only one function each time. You SHOULD NOT include any other text in the response.

Here is a list of functions in JSON format that you can invoke. Note that you should use {api_base} as the api_base.
{functions}

Context: {context}
Question: {question}
EOF
  )

;; python-json : jsexpr -> string   with Python's json.dumps separators (", " and ": "): the function list
;; the model reads is the benchmark's JSON, its object keys in the reader's order rather than the file's
(define (python-json v)
  (cond [(hash? v) (string-append "{" (string-join (for/list ([(k x) (in-hash v)])
                                                    (string-append (jsexpr->string (symbol->string k)) ": " (python-json x)))
                                                  ", ") "}")]
        [(list? v) (string-append "[" (string-join (map python-json v) ", ") "]")]
        [else (jsexpr->string v)]))

(define (functions-text fs) (python-json fs))

;; function-outline : function -> string   a function as lines: its name and description, what it
;; requires, then each value of its JSON schema by its path (`category[].coding[].code`) with
;; its type and the benchmark's description of it. Every word of the definition and none of the
;; schema's own (`{"type": "object", "properties": …}`): 1.2k tokens for the three functions
;; that write, where the JSON is 1.9k. Required values first, in the definition's order.
(define (function-outline f)
  (define schema (hash-ref f 'parameters (hasheq)))
  (define required (let ([r (hash-ref schema 'required '())]) (if (list? r) r '())))
  (string-join
   (append (list (string-join (filter non-empty-string? (list (hash-ref f 'name "") (string-trim (hash-ref f 'description "")))) " — "))
           (if (null? required) '() (list (string-append "  required: " (string-join required ", "))))
           (for/list ([l (in-list (schema-lines schema "" required))])
             (string-append "  " l)))
   "\n"))

;; schema-lines : schema path (listof string) -> (listof string)   one line a value; `first`:
;; the properties to list first at this level
(define (schema-lines schema path [first '()])
  (define type (hash-ref schema 'type #f))
  (define said (let ([d (hash-ref schema 'description #f)]) (and (string? d) (non-empty-string? (string-trim d)) (string-trim d))))
  (define (line) (string-append path ": " (if (string? type) type "value") (if said (string-append " — " said) "")))
  (cond
    [(and (equal? type "object") (hash? (hash-ref schema 'properties #f)))
     (define props (hash-ref schema 'properties))
     (define names (map symbol->string (hash-keys props)))
     (define ordered (append (filter (lambda (n) (member n names)) first)
                             (sort (filter (lambda (n) (not (member n first))) names) string<?)))
     (append (if (and said (non-empty-string? path)) (list (line)) '())
             (append* (for/list ([n (in-list ordered)])
                        (schema-lines (hash-ref props (string->symbol n)) (if (string=? path "") n (string-append path "." n))))))]
    [(and (equal? type "array") (hash? (hash-ref schema 'items #f)))
     (schema-lines (hash-ref schema 'items) (string-append path "[]"))]
    [else (if (string=? path "") '() (list (line)))]))

(define (official-prompt api-base t)
  (for/fold ([s official-template])
            ([k '("{api_base}" "{functions}" "{context}" "{question}")]
             [v (list api-base (python-json (mab-funcs)) (hash-ref t 'context "") (hash-ref t 'instruction))])
    (string-replace s k v #:all? #f)))

(module+ test
  (require rackunit)
  (define ts (list (hasheq 'id "task1_1") (hasheq 'id "task1_2") (hasheq 'id "task2_1") (hasheq 'id "task1_3")))
  (check-equal? (map (lambda (t) (hash-ref t 'id)) (first-of-each ts 2)) '("task1_1" "task1_2" "task2_1"))
  (check-equal? (map (lambda (t) (hash-ref t 'id)) (select-tasks ts "task2_1,task1_3" #f)) '("task2_1" "task1_3"))
  (check-equal? (python-json '(1 "a")) "[1, \"a\"]")
  (define f
    (hasheq 'name "POST {api_base}/Observation" 'description "Observation.Create (Vitals) Files a vital sign. "
            'parameters
            (hasheq 'type "object" 'required '("resourceType" "category" "subject")
                    'properties
                    (hasheq 'subject (hasheq 'type "object" 'properties (hasheq 'reference (hasheq 'type "string" 'description "The patient.")))
                            'note (hasheq 'type "object" 'description "A comment." 'properties (hasheq 'text (hasheq 'type "string")))
                            'category (hasheq 'type "array"
                                              'items (hasheq 'type "object"
                                                             'properties (hasheq 'coding (hasheq 'type "array"
                                                                                                'items (hasheq 'type "object"
                                                                                                               'properties (hasheq 'code (hasheq 'type "string" 'description "Use \"vital-signs\" ")))))))
                            'resourceType (hasheq 'type "string" 'description "Use \"Observation\"")))))
  (check-equal? (function-outline f)
                (string-join '("POST {api_base}/Observation — Observation.Create (Vitals) Files a vital sign."
                               "  required: resourceType, category, subject"
                               "  resourceType: string — Use \"Observation\""
                               "  category[].coding[].code: string — Use \"vital-signs\""
                               "  subject.reference: string — The patient."
                               "  note: object — A comment."
                               "  note.text: string")
                             "\n"))
  (check-equal? (function-outline (hasheq 'name "POST x" 'description "")) "POST x")
  (check-equal? (functions-text (list (hasheq 'name "a"))) "[{\"name\": \"a\"}]"))
