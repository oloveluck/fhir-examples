#lang racket/base
;; serve-store.rkt — a plain FHIR R4 REST server over a store: read, vread and search, with the R4
;; core SearchParameters (what a CRUD FHIR server gives an agent). Used as the REST arm of the
;; agent benchmarks.
;;   racket serve-store.rkt <fhir.db> <port> <Type> …
(require racket/list
         fhir/r4/schemas
         (only-in fhir/store/fhir-sqlite open-fhir-store)
         (only-in fhir/store/serve make-store-app)
         (only-in fhir/http/server serve-app)
         (only-in fhir/spec-package spec-package-path))

(define args (vector->list (current-command-line-arguments)))
(define store (open-fhir-store (first args)))
(define port (string->number (second args)))
(define types (map string->symbol (drop args 2)))
(define app (make-store-app store #:package (spec-package-path "hl7.fhir.r4.core.tgz") #:fhir-version "4.0.1"
                            #:types types))
(void (serve-app app #:port port))
(printf "FHIR R4 server on http://localhost:~a\n" port) (flush-output)
(sync never-evt)
