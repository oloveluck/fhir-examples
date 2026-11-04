#lang racket/base

;;; intake-maps-test.rkt — the worked project of structures and maps (examples/intake-maps): the FSH
;;; compiles, `check` finds nothing, the package carries the StructureMap, and the map resolves by
;;; canonical from that package as a typed value whose result validates against the profile.

(require rackunit racket/runtime-path racket/file json
         (only-in fhir/r5/schemas)
         (only-in fhir/sd/sd-index current-sd-packages resolve-sd-raw resolve-canonical-raw)
         (only-in fhir/spec-package spec-package-path)
         (only-in fhir/conformance/validate validate-issues issue-severity issue-path issue-msg)
         (only-in fhir/diagnostic diagnostic-severity diagnostic-message)
         (only-in fsh/project compile-project pack-project! project-artifacts project-diagnostics)
         (only-in fsh/check check-fsh-project check-report-diagnostics check-report-examples)
         (only-in fml/registry structure-map smap-source smap-target))

(define-runtime-path project "../examples/intake-maps")

;; 1. the project: structures, the map, the example; nothing to report
(define p (compile-project project))
(check-equal? (project-diagnostics p) '())
(check-equal? (sort (map (lambda (a) (hash-ref a 'resourceType)) (project-artifacts p)) string<?)
              '("IntakeForm" "StructureDefinition" "StructureDefinition" "StructureMap"))
(define report (check-fsh-project project))
(check-equal? (filter (lambda (d) (eq? (diagnostic-severity d) 'error)) (check-report-diagnostics report)) '())
(check-equal? (check-report-examples report) 1)

;; 2. the package: both structures and the map, resolvable by canonical
(define tgz (pack-project! p (make-temporary-file "intake-~a.tgz")))
(define core (spec-package-path "hl7.fhir.r5.core.tgz"))
(parameterize ([current-sd-packages (list tgz core)])
  (check-true (hash? (resolve-sd-raw "http://example.org/intake/StructureDefinition/IntakeForm")))
  (check-true (hash? (resolve-canonical-raw "StructureMap" "http://example.org/intake/StructureMap/IntakeToBP")))
  ;; 3. the map as a value: typed, applied, and its result valid under the profile
  (define to-bp (structure-map "http://example.org/intake/StructureMap/IntakeToBP"))
  (check-equal? (smap-source to-bp) 'IntakeForm)
  (check-equal? (smap-target to-bp) 'Observation)
  (define form (findf (lambda (a) (equal? (hash-ref a 'resourceType) "IntakeForm")) (project-artifacts p)))
  (check-false (hash-has-key? form 'id))              ; a logical model based on Base has no id element
  (define obs (to-bp form))
  (check-equal? (hash-ref obs 'resourceType) "Observation")
  (check-equal? (hash-ref obs 'effectiveDateTime) "2024-03-01T09:00:00Z")
  (check-equal? (length (hash-ref obs 'component)) 2)
  (check-equal? (hash-ref (hash-ref (car (hash-ref obs 'component)) 'valueQuantity) 'value) 120)
  (define profile (resolve-sd-raw "http://example.org/intake/StructureDefinition/ScreeningBP"))
  (define issues (filter (lambda (i) (member (issue-severity i) '("error" "fatal")))
                         (validate-issues obs #:profiles (list profile))))
  (check-equal? (map (lambda (i) (list (issue-path i) (issue-msg i))) issues) '()))
(delete-file tgz)
