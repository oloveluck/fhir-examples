#lang racket/base

;;; export-server.rkt — every resource of a FHIR server to NDJSON, one file per type, by searching
;;; patient by patient in parallel.
;;;
;;;   racket -l- fhir-examples/agent-bench/mab/export-server BASE OUT_DIR [--parallel K]
;;;
;;; A server's search pages are cheap at the start and dear deep in: HAPI recomputes every page of a
;;; 563,000-row search from its offset, so paging Observation whole took most of the 14 minutes the
;;; first export of MedAgentBench's server did, slower page by page. Searched per patient
;;; (`Observation?patient=<id>`) no page is deep, and K patients go at once, each worker on a kept-alive
;;; connection. The patients themselves, and any type no patient owns, are paged whole. Each type's
;;; count is then held to the server's (`_summary=count`): a resource that names no patient would be
;;; missed by the per-patient searches, so a type that comes up short is paged whole instead.
;;; Resources are written as the server sent them, one per line.

(require racket/cmdline racket/file racket/list racket/string racket/port json net/http-client
         (only-in fhir/serialize/fast-json fast-bytes->jsexpr)
         "../run-agent.rkt")

;; A Server is (server host port path-prefix)
(struct server (host port prefix))

(define (parse-base base)
  (define m (regexp-match #rx"^http://([^/:]+)(?::([0-9]+))?(/.*)?$" base))
  (unless m (raise-user-error 'export "not an http base url: ~a" base))
  (server (cadr m) (if (caddr m) (string->number (caddr m)) 80)
          (let ([p (or (cadddr m) "/")]) (if (string-suffix? p "/") p (string-append p "/")))))

;; get : connection server path-or-url -> jsexpr   one GET on a kept-alive connection (an absolute url
;; from a `next` link is taken by its path)
(define (get conn srv where)
  (define path (cond [(regexp-match #rx"^https?://[^/]+(/.*)$" where) => cadr]
                     [else (string-append (server-prefix srv) where)]))
  ;; a server that answers one request per connection (ours) has closed it: open it again
  (unless (http-conn-live? conn) (http-conn-open! conn (server-host srv) #:port (server-port srv)))
  (define-values (status _h in) (http-conn-sendrecv! conn path #:headers '("Accept: application/fhir+json")))
  (define body (port->bytes in))
  (unless (regexp-match? #rx#"^HTTP/[0-9.]+ 200" status)
    (error 'export "~a: ~a" path status))
  (fast-bytes->jsexpr body))

(define (open-conn srv) (http-conn-open (server-host srv) #:port (server-port srv)))

;; all-pages : conn server first-path -> (listof resource)   the search, following `next`
(define (all-pages conn srv first)
  (let loop ([where first] [acc '()])
    (define b (get conn srv where))
    (define rs (for/list ([e (in-list (hash-ref b 'entry '()))]
                          #:when (hash-ref (hash-ref e 'search (hasheq)) 'mode "match")
                          #:unless (equal? (hash-ref (hash-ref e 'resource) 'resourceType) "OperationOutcome"))
                 (hash-ref e 'resource)))
    (define next (for/first ([l (in-list (hash-ref b 'link '()))] #:when (equal? (hash-ref l 'relation) "next"))
                   (hash-ref l 'url)))
    (if next (loop next (append acc rs)) (append acc rs))))

(define (count-of conn srv type)
  (hash-ref (get conn srv (format "~a?_summary=count&_format=json" type)) 'total 0))

(define (write-ndjson file resources)
  (call-with-output-file file #:exists 'truncate
    (lambda (o) (for ([r (in-list resources)]) (write-json r o) (newline o)))))

(define (export base out parallel)
  (define srv (parse-base base))
  (make-directory* out)
  (define conn (open-conn srv))
  (define cs (get conn srv "metadata?_format=json"))
  (define types (for/list ([r (in-list (hash-ref (car (hash-ref cs 'rest)) 'resource))]) (hash-ref r 'type)))
  (define counts (for/hash ([t (in-list types)]) (values t (count-of conn srv t))))
  (define present (filter (lambda (t) (positive? (hash-ref counts t))) types))
  (define start (current-inexact-milliseconds))
  (define (elapsed) (/ (round (/ (- (current-inexact-milliseconds) start) 100)) 10.0))
  (define patients (all-pages conn srv "Patient?_count=1000&_format=json"))
  (write-ndjson (build-path out "Patient.ndjson") patients)
  (printf "Patient ~a/~a ~as\n" (length patients) (hash-ref counts "Patient" 0) (elapsed)) (flush-output)
  (define ids (map (lambda (p) (hash-ref p 'id)) patients))
  ;; one connection per worker thread, kept for all its patients
  (define conns (make-hash))
  (define (worker-conn) (hash-ref! conns (current-thread) (lambda () (open-conn srv))))
  (for ([t (in-list present)] #:unless (equal? t "Patient"))
    (define per-patient
      (append* (in-parallel parallel ids
                            (lambda (id) (all-pages (worker-conn) srv (format "~a?patient=~a&_count=1000&_format=json" t id))))))
    ;; one resource can name the patient twice (subject and performer): keep it once
    (define unique (remove-duplicates per-patient #:key (lambda (r) (hash-ref r 'id))))
    (define resources
      (if (>= (length unique) (hash-ref counts t)) unique
          (begin (printf "~a: ~a by patient, ~a on the server — paging it whole\n" t (length unique) (hash-ref counts t))
                 (all-pages conn srv (format "~a?_count=1000&_format=json" t)))))
    (write-ndjson (build-path out (string-append t ".ndjson")) resources)
    (printf "~a ~a/~a ~as\n" t (length resources) (hash-ref counts t) (elapsed)) (flush-output))
  (for ([c (in-hash-values conns)]) (http-conn-close! c))
  (http-conn-close! conn)
  (printf "exported ~a resources in ~as\n" (for/sum ([t present]) (hash-ref counts t)) (elapsed)))

(module+ main
  (define parallel 8)
  (define-values (base out)
    (command-line
     #:once-each [("--parallel") k "searches at a time (default 8)" (set! parallel (string->number k))]
     #:args (base out) (values base out)))
  (export base (path->complete-path out) parallel))

(module+ test
  (require rackunit)
  (define s (parse-base "http://localhost:8080/fhir"))
  (check-equal? (list (server-host s) (server-port s) (server-prefix s)) '("localhost" 8080 "/fhir/")))
