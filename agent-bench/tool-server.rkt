#lang racket/base

;;; tool-server.rkt — the little of the Model Context Protocol a server of tools needs.
;;;
;;; An arm whose agent has a handful of tools and nothing else (fab/tables-server.rkt,
;;; mab/tools-server.rkt) is a process on stdin/stdout, one JSON object a line: initialize, ping,
;;; tools/list, tools/call. No resources, no prompts, nothing announced that a client would turn
;;; into more definitions: what a server announces is in every call of the model.

(require racket/list json)

(provide (struct-out tool) handle serve-tools)

;; A Tool is (tool name description schema run): run : (hash symbol -> jsexpr) -> string, the text
;; answered; it raises exn:fail for what the caller got wrong, which is answered as the tool's error.
(struct tool (name description schema run))

(define protocol-versions '("2025-06-18" "2025-03-26" "2024-11-05"))

;; handle : Message (listof Tool) [string] -> jsexpr | #f   the response to a request; #f for a
;; notification. `server` is the name the server gives itself.
(define (handle m tools [server "tables"])
  (define id (hash-ref m 'id #f))
  (define params (let ([p (hash-ref m 'params #f)]) (if (hash? p) p (hasheq))))
  (define (result r) (hasheq 'jsonrpc "2.0" 'id id 'result r))
  (define (failure code message) (hasheq 'jsonrpc "2.0" 'id id 'error (hasheq 'code code 'message message)))
  (define (said text error?) (result (hasheq 'content (list (hasheq 'type "text" 'text text)) 'isError error?)))
  (and id
       (case (hash-ref m 'method #f)
         [("initialize")
          (result (hasheq 'protocolVersion (let ([asked (hash-ref params 'protocolVersion #f)])
                                             (if (member asked protocol-versions) asked (car protocol-versions)))
                          'capabilities (hasheq 'tools (hasheq))
                          'serverInfo (hasheq 'name server 'version "1")))]
         [("ping") (result (hasheq))]
         [("tools/list")
          (result (hasheq 'tools (for/list ([t (in-list tools)])
                                   (hasheq 'name (tool-name t) 'description (tool-description t) 'inputSchema (tool-schema t)))))]
         [("tools/call")
          (define t (findf (lambda (t) (equal? (tool-name t) (hash-ref params 'name #f))) tools))
          (define args (let ([a (hash-ref params 'arguments #f)]) (if (hash? a) a (hasheq))))
          (cond [(not t) (failure -32602 (format "unknown tool ~a" (hash-ref params 'name #f)))]
                [else (with-handlers ([exn:fail? (lambda (e) (said (exn-message e) #t))])
                        (said ((tool-run t) args) #f))])]
         [else (failure -32601 (format "unknown method ~a" (hash-ref m 'method #f)))])))

;; serve-tools : (listof Tool) [string] -> void   requests read from stdin until it ends, each
;; answered on stdout
(define (serve-tools tools [server "tables"])
  (define out (current-output-port))
  (let loop ()
    (define line (read-line (current-input-port) 'any))
    (unless (eof-object? line)
      (define m (with-handlers ([exn:fail? (lambda (_) #f)]) (string->jsexpr line)))
      (define response (and (hash? m) (handle m tools server)))
      (when response (write-json response out) (newline out) (flush-output out))
      (loop))))

(module+ test
  (require rackunit racket/port)
  (define tools (list (tool "echo" "Says it back." (hasheq 'type "object") (lambda (args) (hash-ref args 'text (lambda () (error "`text` is required")))))))
  (define (request method [params (hasheq)]) (hasheq 'jsonrpc "2.0" 'id 1 'method method 'params params))
  (check-equal? (hash-ref (hash-ref (hash-ref (handle (request "initialize") tools "t") 'result) 'serverInfo) 'name) "t")
  (check-equal? (hash-ref (hash-ref (handle (request "initialize" (hasheq 'protocolVersion "2025-03-26")) tools) 'result) 'protocolVersion) "2025-03-26")
  (check-equal? (hash-ref (hash-ref (handle (request "initialize" (hasheq 'protocolVersion "1999-01-01")) tools) 'result) 'protocolVersion) "2025-06-18")
  (check-false (handle (hasheq 'jsonrpc "2.0" 'method "notifications/initialized") tools))
  (check-equal? (hash-ref (car (hash-ref (hash-ref (handle (request "tools/list") tools) 'result) 'tools)) 'name) "echo")
  (let ([r (hash-ref (handle (request "tools/call" (hasheq 'name "echo" 'arguments (hasheq 'text "hi"))) tools) 'result)])
    (check-equal? (hash-ref (car (hash-ref r 'content)) 'text) "hi")
    (check-false (hash-ref r 'isError)))
  (let ([r (hash-ref (handle (request "tools/call" (hasheq 'name "echo")) tools) 'result)])
    (check-true (hash-ref r 'isError))
    (check-regexp-match #rx"`text` is required" (hash-ref (car (hash-ref r 'content)) 'text)))
  (check-equal? (hash-ref (hash-ref (handle (request "tools/call" (hasheq 'name "nope")) tools) 'error) 'code) -32602)
  (check-equal? (hash-ref (hash-ref (handle (request "resources/list") tools) 'error) 'code) -32601)
  ;; the loop: a line that is no JSON and a notification are passed over
  (define said
    (with-output-to-string
      (lambda ()
        (parameterize ([current-input-port (open-input-string (string-append "not json\n"
                                                                             (jsexpr->string (hasheq 'jsonrpc "2.0" 'method "notifications/initialized")) "\n"
                                                                             (jsexpr->string (request "ping")) "\n"))])
          (serve-tools tools)))))
  (check-equal? (string->jsexpr said) (hasheq 'jsonrpc "2.0" 'id 1 'result (hasheq))))
