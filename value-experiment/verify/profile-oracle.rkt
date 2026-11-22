#lang racket/base

;;; profile-oracle.rkt — a profile's definition, executed: this toolkit's validator (fhir-validation)
;;; holding a resource to the profile in the guide's packages, answering valid or not and nothing
;;; else. Experiment V-profile's arm O gives a checker this command.
;;;
;;;   (oracle-main profile)   the command a checker runs: `racket oracle.rkt [FILE|DIR]…`
;;;   (verdict-line name answer)
;;;
;;; The verdict alone: what is wrong with a resource is not said (that is another experiment's
;;; question). How often the verdict is HL7's validator's is profile-cases.rkt's `agreement`.

(require racket/list racket/string json
         (only-in "profile-cases.rkt" toolkit-valid?))

(provide oracle-main verdict-line resource-files)

;; verdict-line : string (or/c boolean string) -> string   as the checkers' own script prints a verdict
(define (verdict-line name answer)
  (format "~a ~a" name (cond [(string? answer) (format "ERROR ~a" (car (string-split answer "\n")))]
                             [answer "valid"]
                             [else "invalid"])))

;; resource-files : (listof path-string) -> (listof path)   the JSON files named, and those of the
;; directories named, in name order
(define (resource-files args)
  (append*
   (for/list ([a (in-list args)])
     (cond [(directory-exists? a)
            (for/list ([f (in-list (sort (map path->string (directory-list a)) string<?))] #:when (regexp-match? #rx"[.]json$" f))
              (build-path a f))]
           [else (list (string->path a))]))))

;; oracle-main : Profile -> void   `racket oracle.rkt [FILE|DIR]…` (default sample/): one line a resource
(define (oracle-main p)
  (define args (vector->list (current-command-line-arguments)))
  ;; a reader that stops early (`| head`) ends the command quietly
  (with-handlers ([exn:fail:filesystem:errno? (lambda (_) (exit 0))])
    (verdicts p (resource-files (if (null? args) '("sample") args)))))

;; verdicts : Profile (listof path) -> void   one line a resource
(define (verdicts p files)
  (for ([f (in-list files)])
    (define name (let-values ([(_b n _d) (split-path f)]) (regexp-replace #rx"[.]json$" (path->string n) "")))
    (displayln
     (verdict-line name
                   (with-handlers ([exn:fail? (lambda (e) (format "the file does not read as a FHIR resource: ~a" (exn-message e)))])
                     (define r (call-with-input-file f read-json))
                     (if (hash? r) (toolkit-valid? p r) "the file is not a JSON object"))))
    (flush-output)))

(module+ test
  (require rackunit racket/file)
  (check-equal? (verdict-line "case-01" #t) "case-01 valid")
  (check-equal? (verdict-line "case-02" #f) "case-02 invalid")
  (check-equal? (verdict-line "x" "no\nmore") "x ERROR no")
  (define dir (make-temporary-file "oracle-~a" 'directory))
  (display-to-file "{}" (build-path dir "b.json")) (display-to-file "{}" (build-path dir "a.json")) (display-to-file "" (build-path dir "notes.txt"))
  (check-equal? (map (lambda (f) (let-values ([(_b n _d) (split-path f)]) (path->string n))) (resource-files (list (path->string dir)))) '("a.json" "b.json"))
  (delete-directory/files dir))
