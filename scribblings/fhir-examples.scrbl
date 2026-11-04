#lang scribble/manual
@(require (for-label racket/base racket/contract fhir-examples/bench fhir-examples/model
                     fhir-examples/ig-servers/fetch fhir-examples/ig-servers/verify))

@title{fhir-examples}

Worked examples for the @hyperlink["https://github.com/oloveluck/fhir"]{fhir} family of Racket
packages, and @tt{raco spec-bench}, a benchmark for writing FHIR profiles from prose with a model.
Each example directory has a README with its results.

@table-of-contents[]

@section{Run them}

@verbatim{
raco pkg install --link --auto fhir/fhir fhir/fhir-spec fhirpath vcl fhir/fhir-tx fhir/fhir-validation cql fml fsh fhir/fhir-server sql-on-fhir fhir-examples
racket screening/main.rkt                      six languages, one program
racket examples/pipeline.rkt                   operations as procedures
raco fsh check examples/intake-maps            structures, a map, an example: checked as one project
racket notes-to-fhir/main.rkt --replay notes-to-fhir/results/2026-11-03T2336-brief
    recorded model runs, no model
racket ig-servers/main.rkt -v hl7.fhir.uv.ipa  one IG's server, every failure printed
raco test -p fhir-examples                     the recorded results as floors
}

@section{The examples}

@itemlist[
@item{@tt{screening/}: a blood pressure screening in six FHIR languages, each file a module in its
own @hash-lang[] (FHIR Shorthand, FHIR R6 resources, the FHIR Mapping Language, VCL, CQL, SQL on
FHIR), composed by one Racket program. Each language checks its file as the program compiles; the
modules' values are FHIR resources and procedures over them, joined by FHIR operations.
@racketblock[
(require (only-in "profile.fsh" [compiled clinic])
         (only-in "intake.fml" [transform intake->reading])
         (only-in "bp-panels.vcl" [valueset bp-panels])
         (only-in "screening.cql" [evaluate screen])
         (only-in "readings.sof" [->json view-definitions]))
(code:comment "FML, then the FSH profile")
(~> form intake->reading (ensure-valid #:profile profile))
(code:comment "the VCL value set, expanded")
($expand #:valueSet bp-panels)
(code:comment "CQL over one patient")
(screen patient-data #:parameters (hash "Panel Codes" codes))
(view-rows view)                                                    (code:comment "SQL on FHIR over the same data")]}
@item{@tt{examples/pipeline.rkt}: FHIR operations applied as procedures, no server. A
QuestionnaireResponse becomes a Patient through @tt{$transform}, is validated, and its gender is
checked with @tt{ValueSet/$validate-code}.}
@item{@tt{examples/intake-maps/}: structures and the map between them as one project. A logical
model (the front desk's intake form) and a profile (the clinic's screening Observation) in FSH, the
map from one to the other in FML, and an example form. @tt{raco fsh check} compiles the structures,
checks the map against them and transforms the example into a valid Observation; @tt{--pack} writes
one package holding both structures and the StructureMap; @tt{(structure-map url)} then applies the
map by canonical from that package as a typed procedure (@tt{tests/intake-maps-test.rkt}). The
fml document walks through it.}
@item{@tt{notes-to-fhir/}: clinic notes (text) become FHIR with a model, held to a small IG written
in FSH by @tt{$validate}, each issue fed back by resource and path until the data conforms; then the
screening rule runs over it. @litchar{--brief} leaves the FSH out of the prompt; @litchar{--replay} re-checks a
recorded run without a model.}
@item{@tt{ig-servers/}: servers generated from six published IGs (IPA, AU Core, Plan-Net, Drug
Formulary, CARIN Blue Button, SDC), checked against nothing but each IG: every example accepted, read
back, found by every advertised search parameter and include; every example made invalid refused;
every requirement of the CapabilityStatement met. Packages are fetched into @tt{ig-servers/packages/}
and locked.}]

@section{The benchmark}
@defmodule[fhir-examples/bench]

A task is a published IG's FSH minus one leaf profile and its instances. The prompt gives what the IG
publishes about the profile (description, purpose, and the short, definition and comment text of
every element it constrains) and names the constrained elements, never a constraint value. The answer
is FSH. The score is against the profile HL7 published.

@defproc[(list-tasks [ig path-string?]) (listof (list/c string? string? exact-nonnegative-integer?))]{
The profiles that can be taken out alone (no other local profile derives from them): name, id, number
of examples.}
@defproc[(make-task! [ig path-string?] [published path-string?] [profile string?] [out path-string?]) path?]{
Writes @tt{out/project/} (the IG without the profile and its instances), @tt{out/prompt.md} and
@tt{out/task.rktd}. @racket[published] is the IG's package.}
@defproc[(score-task [task path-string?] [candidate string?]) hash?]{
Compiles the candidate FSH inside the task's project with @tt{fsh/check}, then scores it:
@racket['check_errors]; @racket['fidelity], facets agreed with the published differential (min, max,
mustSupport, types, binding, fixed and pattern values, slicing) as @racket[(list ok total)], and
@racket['extra_constrained_elements]; @racket['accepts_published_examples], the IG's examples
validated against the candidate's profile; @racket['examples_conform_to_published], the candidate's
examples validated against the published profile; @racket['rejections] and
@racket['diagnostics_text].}
@defproc[(run-task! [task path-string?] [command string?]
                    [#:rounds rounds exact-positive-integer? 3]
                    [#:timeout timeout (and/c real? positive?) 1200]) (listof hash?)]{
Runs a shell command on the task: the prompt on its stdin, the answer on its stdout (the last
@tt{```fsh} block is the candidate), through files, its process group killed past the timeout. Each
round's prompt, answer, FSH and score go under @tt{runs/<stamp>/} and a line is appended to
@tt{results.jsonl}. After a round with @tt{check} errors the next prompt carries the answer and the
diagnostics; rounds stop when the answer checks clean.}
@defproc[(published-package [name string?]) path?]{A package by path, by file name in @tt{fhir-spec}, or by name (@racket["hl7.fhir.us.mcode-4.0.0"]).}

@subsection[#:style 'unnumbered]{@tt{fhir-examples/model}}
@defmodule[fhir-examples/model]

@defproc[(ask [command string?] [prompt-file path-string?] [answer-file path-string?] [err-file path-string?] [timeout real?]) (values any/c real? boolean?)]{
Runs a shell command with the prompt file on stdin and its output in the answer and error files;
returns the exit code, the seconds taken, and whether it timed out.}
@defproc[(extract-block [answer string?] [language string?]) string?]{The last fenced block of that language, else the last fenced block, else the whole answer.}

@subsection[#:style 'unnumbered]{@tt{raco spec-bench}}

@verbatim{
raco spec-bench list <ig-dir>
raco spec-bench make <ig-dir> <published-package> <Profile> <task-dir>
raco spec-bench score <task-dir> (--oracle | --empty | <candidate.fsh>)
raco spec-bench run <task-dir> --model '<shell command>' [--rounds n] [--timeout seconds]
}

End to end, on mCODE (its FSH sources are vendored in the fsh repository):

@verbatim{
raco spec-bench list ../fsh/tests/vendor/mcode-4.0.0
raco spec-bench make ../fsh/tests/vendor/mcode-4.0.0 hl7.fhir.us.mcode-4.0.0 TumorSize task/
raco spec-bench score task/ --oracle
    the IG's own FSH: the ceiling this compiler allows
raco spec-bench score task/ --empty                  nothing: 0
raco spec-bench run task/ --model 'claude -p' --rounds 3 --timeout 1200
cat task/results.jsonl
}

The model command reads the prompt on stdin and answers on stdout; the last @tt{```fsh} block is the
candidate. Each round's files are under @tt{task/runs/<stamp>/}.

@section{IG servers}
@defmodule[fhir-examples/ig-servers/verify]

@defproc[(verify-ig [package path-string?] [#:capability capability (or/c string? #f) #f]) report?]{
Generates a server from the package (@tt{fhir/store/ig-server}) over a temporary store, with the
fetched dependencies in @racket[current-package-directories], and checks it against the IG.}
@defstruct*[report ([ig string?] [version string?] [capability string?] [types exact-nonnegative-integer?] [gaps list?]
                    [profiles tally?] [accepted tally?] [read-back tally?] [search tally?] [includes tally?] [rejected tally?])]
@defstruct*[tally ([checked exact-nonnegative-integer?] [failures list?] [kinds hash?])]
@defproc[(report->jsexpr [r report?]) jsexpr?]{What @tt{ig-servers/results/*.json} hold.}

@subsection[#:style 'unnumbered]{@tt{fhir-examples/ig-servers/fetch}}
@defmodule[fhir-examples/ig-servers/fetch]

@defproc[(fetch-ig! [name string?] [version string?]) path?]{
The IG's package and its dependencies, transitively, from packages.fhir.org into
@racket[(packages-dir)], checked against the registry's shasum and recorded in @tt{packages.lock}.
Core packages come from @tt{fhir-spec}; terminology, extension and VSAC packages are not fetched.}
@defproc[(packages-dir) path?]{@tt{ig-servers/packages/}, not committed.}

