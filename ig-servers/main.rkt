#lang racket/base

;;; main.rkt — servers generated from published IGs, each held to its IG (verify.rkt).
;;;
;;;   racket ig-servers/main.rkt                    every IG below: fetch, generate, verify; results/
;;;   racket ig-servers/main.rkt hl7.fhir.uv.ipa    one
;;;   racket ig-servers/main.rkt -v …               and print every failure

(require racket/list racket/string racket/file racket/runtime-path json
         "fetch.rkt" "verify.rkt")

(provide igs)

(define-runtime-path here ".")

;; An IG to verify: (list package version server-CapabilityStatement-id), each a published release
;; whose package ships a server CapabilityStatement
(define igs
  '(("hl7.fhir.uv.ipa"                     "1.1.0" "ipa-server")
    ("hl7.fhir.au.core"                    "2.0.0" "au-core-responder")
    ("hl7.fhir.us.davinci-pdex-plan-net"   "1.2.0" "plan-net")
    ("hl7.fhir.us.davinci-drug-formulary"  "2.1.0" "usdf-server")
    ("hl7.fhir.us.carin-bb"                "2.2.0" "c4bb")
    ("hl7.fhir.uv.sdc"                     "4.0.0" "sdc-form-manager")))

(define (tallies r) (list (report-profiles r) (report-accepted r) (report-read-back r) (report-search r)
                         (report-includes r) (report-rejected r)))
(define (summary t) (format "~a/~a" (- (tally-checked t) (length (tally-failures t))) (tally-checked t)))

(module+ main
  (define args (vector->list (current-command-line-arguments)))
  (define verbose? (member "-v" args))
  (define chosen (let ([names (filter (lambda (a) (not (regexp-match? #rx"^-" a))) args)])
                   (if (null? names) igs (filter (lambda (ig) (member (car ig) names)) igs))))
  (make-directory* (build-path here "results"))
  (printf "~a\n" (string-join '("IG" "types" "unmet" "profiles" "accepted" "read back" "search" "includes" "rejected") "\t"))
  (for ([ig (in-list chosen)])
    (define tgz (fetch-ig! (first ig) (second ig)))
    (define r (verify-ig tgz #:capability (third ig)))
    (with-output-to-file (build-path here "results" (format "~a-~a.json" (first ig) (second ig))) #:exists 'truncate
      (lambda () (write-json (report->jsexpr r)) (newline)))
    (printf "~a ~a\t~a\t~a\t~a\n" (first ig) (second ig) (report-types r) (length (report-gaps r))
            (string-join (map summary (tallies r)) "\t"))
    (when verbose?
      (for ([g (in-list (report-gaps r))]) (printf "    unmet ~s\n" g))
      (for ([k (in-list '("profiles" "accepted" "read back" "search" "includes" "rejected"))]
            [t (in-list (tallies r))])
        (for ([f (in-list (tally-failures t))]) (printf "    ~a: ~s\n" k f)))
      (for ([(kind n) (in-hash (tally-kinds (report-rejected r)))]) (printf "    rejected ~a: ~a\n" kind n)))
    (flush-output)))
