#lang racket/base

;;; tests.rkt — the pipeline's one gate, `raco test tests.rkt`: the FSH project checks clean, an example
;;; in the invalid folder fails at its line, the map's result holds to the profile, and main.rkt answers
;;; on either side of the 65th birthday. Each step is the command fhir-authoring runs by hand, here as a
;;; check. Copy it beside files of your own and set the four names below to your layout; the rest reads
;;; what to expect from the files (the invalid folder's Instances, the input's birth date).

(require rackunit racket/runtime-path json racket/file racket/string
         (only-in fsh/check check-fsh-project check-report-diagnostics)
         (only-in fhir/diagnostic diagnostic-message diagnostic-severity diagnostic-loc))

(define profiles-folder "fsh")          ; the FSH project: the profile and its valid example
(define invalid-folder "fsh-invalid")   ; the example(s) meant to fail, checked with the profiles in context
(define input-file "qr.json")           ; a QuestionnaireResponse whose birth date is a valueDate answer
(define main-file "main.rkt")           ; provides (intake qr #:now) -> (values patient answer-text)

(define-runtime-path here ".")
(define (at . parts) (apply build-path here parts))
;; each name above must be there: one line saying which and how to set it (a project with other folder
;; names failed with a raw `directory-list: could not open directory`)
(for ([name (list profiles-folder invalid-folder input-file main-file)]
      [dir? (list #t #t #f #f)])
  (unless (if dir? (directory-exists? (at name)) (file-exists? (at name)))
    (raise-user-error 'tests.rkt "no ~a ~a beside tests.rkt: set the name at the top of tests.rkt to your layout"
                      (if dir? "folder" "file") name)))
(define (errors-of report) (filter (lambda (d) (eq? (diagnostic-severity d) 'error)) (check-report-diagnostics report)))

;; raco fsh check fsh: the profile and its valid example, no error
(check-equal? (map diagnostic-message (errors-of (check-fsh-project (at profiles-folder)))) '())

;; raco fsh check fsh-invalid --context fsh: the example meant to fail fails, at an instance of that
;; folder (read from the files, so a project of your own needs no edit here)
(define invalid-files (for/list ([f (in-list (directory-list (at invalid-folder) #:build? #t))]
                                 #:when (regexp-match? #rx"[.]fsh$" (path->string f)))
                        f))
(define invalid-instances          ; (name . line) of each Instance in fsh-invalid/
  (for*/list ([f (in-list invalid-files)]
              [l+i (in-list (for/list ([l (in-list (file->lines f))] [i (in-naturals 1)]) (cons l i)))]
              #:when (regexp-match? #rx"^Instance:" (car l+i)))
    (cons (string-trim (substring (car l+i) 9)) (cdr l+i))))
(define bad (errors-of (check-fsh-project (at invalid-folder) #:context (list (at profiles-folder)))))
(check-true (pair? bad) (format "an example in ~a/ should break the profile" invalid-folder))
(check-true (pair? invalid-instances) (format "~a/ should hold an Instance" invalid-folder))
(check-not-false (for/or ([inst (in-list invalid-instances)])
                   (regexp-match? (regexp (string-append (regexp-quote (car inst)) ": ")) (diagnostic-message (car bad))))
                 (diagnostic-message (car bad)))
(check-true (pair? (filter (lambda (d) (diagnostic-loc d)) bad)) "each problem has a line")

;; main.rkt: the map, validated against IntakePatient, then CQL — on either side of the 65th
;; birthday, the birth date read from qr.json (the answer written as a date, whatever its linkId)
(define intake (dynamic-require (at main-file) 'intake (lambda () #f)))
;; the shape this file drives, said when main.rkt lacks it (a renamed function failed as a raw
;; `dynamic-require: name is not provided`)
(unless intake
  (raise-user-error 'tests.rkt "main.rkt must provide `intake`: (provide intake) and (define (intake qr #:now [now #f]) …) answering (values patient answer-text) — the Patient as FHIR JSON and the answer as text"))
(define qr (call-with-input-file (at input-file) read-json))
(define (date-answer? i) (for/or ([a (in-list (hash-ref i 'answer '()))]) (hash-has-key? a 'valueDate)))
(define birth-item (findf date-answer? (hash-ref qr 'item)))
(define born (hash-ref (car (hash-ref birth-item 'answer)) 'valueDate))
(define (years-after date n)       ; "1950-05-01" 66 -> "2016-05-01"
  (format "~a~a" (+ n (string->number (substring date 0 4))) (substring date 4 10)))
(define-values (patient old?) (intake qr #:now (years-after born 66)))
(check-equal? (hash-ref patient 'birthDate) born)
(check-equal? old? "true")
(define-values (_p young?) (intake qr #:now (years-after born 64)))
(check-equal? young? "false")

;; a response with no birth date breaks the profile, and says so at the map's rule
(define no-birth (hash-set qr 'item (remq birth-item (hash-ref qr 'item))))
(check-exn #rx"[.]map:[0-9]+:[0-9]+: .*Patient[.]birthDate: minimum required = 1" (lambda () (intake no-birth)))
