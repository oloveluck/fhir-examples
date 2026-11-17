1754
((3) 0 () 6 ((q lib "fhir-examples/ig-servers/verify.rkt") (q 5320 . 5) (q lib "fhir-examples/bench.rkt") (q 4734 . 23) (q lib "fhir-examples/ig-servers/fetch.rkt") (q lib "fhir-examples/model.rkt")) () (h ! (equal) ((c def c (c (? . 0) q report->jsexpr)) q (5453 . 3)) ((c def c (c (? . 0) q tally-checked)) c (? . 1)) ((c def c (c (? . 0) q tally-failures)) c (? . 1)) ((c def c (c (? . 2) q run-task!)) q (3763 . 9)) ((c def c (c (? . 0) q struct:tally)) c (? . 1)) ((c def c (c (? . 2) q score-task)) q (3660 . 4)) ((c def c (c (? . 2) q make-task!)) q (3493 . 6)) ((c def c (c (? . 2) q list-tasks)) q (3371 . 4)) ((c def c (c (? . 0) q report)) c (? . 3)) ((c def c (c (? . 0) q report-gaps)) c (? . 3)) ((c def c (c (? . 0) q report-search)) c (? . 3)) ((c def c (c (? . 0) q report-version)) c (? . 3)) ((c def c (c (? . 5) q extract-block)) q (4482 . 4)) ((c def c (c (? . 0) q report-types)) c (? . 3)) ((c def c (c (? . 0) q report-rejected)) c (? . 3)) ((c def c (c (? . 0) q tally-kinds)) c (? . 1)) ((c def c (c (? . 0) q tally?)) c (? . 1)) ((c def c (c (? . 0) q report-includes)) c (? . 3)) ((c def c (c (? . 2) q published-package)) q (4104 . 3)) ((c def c (c (? . 0) q report-accepted)) c (? . 3)) ((c def c (c (? . 0) q report?)) c (? . 3)) ((c def c (c (? . 0) q struct:report)) c (? . 3)) ((c def c (c (? . 4) q fetch-ig!)) q (5514 . 4)) ((c def c (c (? . 0) q report-read-back)) c (? . 3)) ((c def c (c (? . 0) q verify-ig)) q (4587 . 4)) ((c def c (c (? . 4) q packages-dir)) q (5607 . 2)) ((c def c (c (? . 0) q report-capability)) c (? . 3)) ((c def c (c (? . 0) q report-profiles)) c (? . 3)) ((c def c (c (? . 0) q tally)) c (? . 1)) ((c def c (c (? . 5) q ask)) q (4172 . 11)) ((c def c (c (? . 0) q report-ig)) c (? . 3))))

file            language                   what it says
qr.json         FHIR JSON                  the form as it arrives: a name, a gender, a birth date
qr2patient.map  FHIR Mapping Language      how each answer becomes an element of a Patient
fsh/intake.fsh  FHIR Shorthand             a profile: a Patient here must have a name, a gender and a birth date
Intake.cql      Clinical Quality Language  the rule: is this patient 65 or older?
main.rkt        Racket                     the few lines that join them

file           language                   its job
profile.fsh    FHIR Shorthand             what a screening blood pressure must contain; two patients and one
                                          reading already on file
forms.fhir6    FHIR R6 resources          two intake forms, checked against FHIR as the file compiles
intake.fml     FHIR Mapping Language      a form becomes a reading
bp-panels.vcl  ValueSet Compose Language  which codes count as a blood pressure panel
screening.cql  Clinical Quality Language  the rule: highest systolic of 140 or more
readings.sof   SQL on FHIR                the readings as a flat table
pipeline.rkt   Racket                     joins the six above
app.rkt        the capability language    declares the same thing as a FHIR server
main.rkt       Racket                     prints the result; its tests check it

racket notes-to-fhir/main.rkt --replay <run>  a recorded run, checked and scored again; no model
racket notes-to-fhir/main.rkt                 every note, live; needs a model command (--model, default claude -p)
racket notes-to-fhir/main.rkt --brief         live, with only the profiles' names and urls in the prompt
… --rounds 3 --timeout 600 [note …]           how many tries, seconds allowed for each, and which notes

racket ig-servers/main.rkt                     download, generate and check all six; one line each
racket ig-servers/main.rkt -v hl7.fhir.uv.ipa  one guide, with every failure printed
raco test ig-servers/verify-test.rkt           hold the recorded results as minimums, for the guides already
                                               downloaded; no network

guide                               types  unmet  accepted  read back  search   includes  refused
International Patient Access 1.1.0  11     0      15/15     15/15      56/56    19/19     61/61
AU Core 2.0.0                       19     0      65/65     64/64      264/264  11/11     283/283
Da Vinci PDex Plan-Net 1.2.0        8      0      87/87     49/49      212/212  332/332   182/182
Da Vinci Drug Formulary 2.1.0       4      0      43/43     22/22      104/104  22/22     106/106
CARIN Blue Button 2.2.0             6      0      104/104   42/42      184/184  144/144   460/460
SDC 4.0.0 (form manager)            7      13     80/80     35/35      29/29    none      158/158

task                   rounds  fidelity  published examples accepted  own examples conform
TumorSize              1       30/34     0/2                          0/1
CancerDiseaseStatus    2       16/20     0/3                          0/1
ECOGPerformanceStatus  1       6/8       2/2                          1/1
procedure
(list-tasks ig)
 -> (listof (list/c string? string? exact-nonnegative-integer?))
  ig : path-string?
procedure
(make-task! ig published profile out) -> path?
  ig : path-string?
  published : path-string?
  profile : string?
  out : path-string?
procedure
(score-task task candidate) -> hash?
  task : path-string?
  candidate : string?
procedure
(run-task!  task                    
            command                 
           [#:rounds rounds         
            #:timeout timeout]) -> (listof hash?)
  task : path-string?
  command : string?
  rounds : exact-positive-integer? = 3
  timeout : (and/c real? positive?) = 1200
procedure
(published-package name) -> path?
  name : string?
procedure
(ask command         
     prompt-file     
     answer-file     
     err-file        
     timeout)    -> any/c real? boolean?
  command : string?
  prompt-file : path-string?
  answer-file : path-string?
  err-file : path-string?
  timeout : real?
procedure
(extract-block answer language) -> string?
  answer : string?
  language : string?
procedure
(verify-ig package [#:capability capability]) -> report?
  package : path-string?
  capability : (or/c string? #f) = #f
struct
(struct report (ig
                version
                capability
                types
                gaps
                profiles
                accepted
                read-back
                search
                includes
                rejected))
  ig : string?
  version : string?
  capability : string?
  types : exact-nonnegative-integer?
  gaps : list?
  profiles : tally?
  accepted : tally?
  read-back : tally?
  search : tally?
  includes : tally?
  rejected : tally?
struct
(struct tally (checked failures kinds))
  checked : exact-nonnegative-integer?
  failures : list?
  kinds : hash?
procedure
(report->jsexpr r) -> jsexpr?
  r : report?
procedure
(fetch-ig! name version) -> path?
  name : string?
  version : string?
procedure
(packages-dir) -> path?
