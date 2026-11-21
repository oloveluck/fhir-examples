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
  (check-equal? (python-json '(1 "a")) "[1, \"a\"]"))
