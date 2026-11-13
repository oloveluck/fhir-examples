#lang scribble/manual
@; Text in @tt is shown exactly as written: no curly quotes, and "--" stays two hyphens.
@(require (only-in scribble/core [element literal-element]))
@(define (tt . text) (literal-element (quote tt) text))
@(require (for-label racket/base racket/contract fhir-examples/bench fhir-examples/model
                     fhir-examples/ig-servers/fetch fhir-examples/ig-servers/verify))

@title{fhir-examples}

FHIR, the health-care standard for exchanging records, is written down in several small languages,
each made for one job: one for saying what valid data looks like, one for converting a record from
one shape to another, one for clinical rules, one for lists of codes, one for tables. A real task
usually needs several of them at once, and it is not obvious from each language's own manual how
they fit together.

This repository is worked examples of them fitting together, from a short program that applies a
few FHIR operations to one written in seven languages. Every example is small enough to read in one
sitting and runs with one command, and @tt{raco test} holds each to its expected results.

It also holds a benchmark. A language model is given the prose that describes a FHIR profile, asked
to write the profile, and scored against the one HL7 published.

Part of the @hyperlink["https://oloveluck.github.io/fhir/"]{fhir} family of FHIR languages and tools.

@table-of-contents[]

@section{What you can do with it}

@itemlist[
@item{@bold{See FHIR operations used as plain functions}, with no server: @secref["pipeline"].}
@item{@bold{Follow one form through a map, a profile and a rule}, and copy that program as the
start of your own: @secref["intake-pipeline"].}
@item{@bold{Keep data structures and the map between them in one checked project}:
@secref["intake-maps"].}
@item{@bold{Read one program written in seven FHIR languages}, and serve it over HTTP:
@secref["screening"].}
@item{@bold{Watch a model turn clinic notes into FHIR} that a specification accepts, with the
recorded runs replayed without a model: @secref["notes"].}
@item{@bold{Check servers generated from published guides} against those guides: @secref["ig-servers"].}
@item{@bold{Measure how well a model writes a profile from prose}: @secref["bench"].}]

@section[#:tag "start"]{Before you start}

The examples are Racket programs, so they need Racket and the family's packages, not only the
standalone tools. Install the family as its
@hyperlink["https://oloveluck.github.io/fhir/"]{front page} describes, clone this repository beside
the others, and add it:

@verbatim{
raco pkg install --link --auto fhir-examples
}

Every command on this page is run from the repository's directory. Most take three to five
seconds.

Three things need more than Racket, and this page says so where they come up: the live run of
@tt{notes-to-fhir} and the benchmark's @tt{run} call a language model, and @tt{ig-servers}
downloads packages from the network. Everything else runs offline.

@section{The examples, smallest first}

@subsection[#:tag "pipeline"]{@tt{examples/pipeline.rkt}: operations as functions}

A FHIR @italic{operation} is a named action the standard defines, written with a dollar sign:
@tt{$validate} checks a record, @tt{$transform} converts one with a map. They are usually requests
sent to a server. Here each is an ordinary function you call, and no server is involved.

The program takes a filled-in form (a @tt{QuestionnaireResponse}) whose one answer is "female",
converts it to a Patient with a map, checks that the Patient is valid FHIR, and then asks whether
its gender is one of the codes FHIR allows.

@verbatim|{
$ racket examples/pipeline.rkt
transformed: {"gender":"female","resourceType":"Patient"}
validated:   {"gender":"female","resourceType":"Patient"}
gender valid: #t
an invalid Patient: {"issue":[{"code":"code-invalid","diagnostics":"code `florp` not in required value set http://hl7.org/fhir/ValueSet/administrative-gender; it holds female, male, other, unknown","expression":["Patient.gender"],"severity":"error"}],"resourceType":"OperationOutcome"}
a misapplied operation: {"issue":[{"code":"invalid","diagnostics":"$validate has no input parameter 'profle' (it takes: resource, mode, profile, usageContext)","severity":"error"}],"resourceType":"OperationOutcome"}
}|

Reading the output:

@itemlist[
@item{@bold{transformed} is the map's result. @bold{validated} is the same record after it passed
the check; in a chain of steps, a record that fails stops the chain.}
@item{@bold{gender valid} is the answer of @tt{$validate-code}: @tt{#t} is Racket's "true".}
@item{The last two lines are mistakes made on purpose. A Patient whose gender is @tt{florp} is
refused, with the allowed codes listed. Calling @tt{$validate} with a misspelt input,
@tt{profle}, is refused too, with the inputs it does take. Both answers are an
@tt{OperationOutcome}, the FHIR record for reporting a problem.}]

In the source, the three ways of calling an operation are side by side:

@racketblock[
(apply-operation "StructureMap/$transform" qr #:srcMap fml)     (code:comment "by name, inputs as keywords")
(define transform (operation "StructureMap/$transform"))        (code:comment "looked up once, then a function")
(~> qr (transform #:srcMap fml) (ensure-valid))                 (code:comment "a chain: each result feeds the next step")
]

@subsection[#:tag "intake-pipeline"]{@tt{examples/intake-pipeline/}: one form, a map, a profile, a rule}

This is the smallest program that uses several languages, and the one to copy when you start your
own. A clinic's intake form comes in; the program turns it into a Patient, checks the Patient
against the clinic's own requirements, and answers one question about them. Each step is a file in
the language made for it:

@tabular[#:style 'boxed #:sep @hspace[2]
(list (list @bold{file} @bold{language} @bold{what it says})
      (list @tt{qr.json} "FHIR JSON" "the form as it arrives: a name, a gender, a birth date")
      (list @tt{qr2patient.map} "FHIR Mapping Language" "how each answer becomes an element of a Patient")
      (list @tt{fsh/intake.fsh} "FHIR Shorthand" @elem{a @italic{profile}: a Patient here must have a name, a gender and a birth date})
      (list @tt{Intake.cql} "Clinical Quality Language" @elem{the rule: is this patient 65 or older?})
      (list @tt{main.rkt} "Racket" "the few lines that join them"))]

@verbatim|{
$ racket examples/intake-pipeline/main.rkt examples/intake-pipeline/qr.json --now 2026-01-01
{
  "resourceType": "Patient",
  "name": [
    {
      "text": "Ana Rivera"
    }
  ],
  "gender": "female",
  "birthDate": "1950-05-01"
}
65 or older: true
}|

The Patient is what the map made from the form. The last line is the rule's answer.
@litchar{--now} fixes "today", so the answer does not change as time passes; with
@litchar{--now 2015-04-30}, the day before her 65th birthday, the last line is
@tt{65 or older: false}.

Now a mistake. Give it a form with no birth date and the program stops, because the profile
requires one. The message does not only say what is missing. It points at the line of the map
that should have written it, and says why that line wrote nothing:

@verbatim|{
the map's Patient is invalid against IntakePatient (http://example.org/StructureDefinition/intake-patient) (FHIR R5 (5.0.0)):
  qr2patient.map:15:3: fml validate error: Patient.birthDate: minimum required = 1, but found 0 (the rule here wrote nothing: its source matched 2 items, but `where (linkId = 'birthDate')` held for none (the linkId there: name, gender))
}|

Each piece can also be checked on its own, before the program runs. From inside
@tt{examples/intake-pipeline/}:

@verbatim|{
$ raco fsh check fsh
fsh check: 1 example, 0 with errors; 0 errors, 0 warnings
  canonical: http://example.org (default; a sushi-config.yaml beside the files sets it: `canonical: http://…`)

$ raco fsh check fsh-invalid --context fsh
fsh-invalid/bad.fsh:3:1: fsh validate error: instance intake-bad: Patient.birthDate: minimum required = 1, but found 0 (no rule of intake-bad writes `birthDate`) (constrained by profile IntakePatient at fsh/intake.fsh:9:3)
 3 | Instance: intake-bad
   | ^^^^^^^^^
fsh check: 1 example, 1 with errors; 1 error, 0 warnings
…

$ raco fml check qr2patient.map
qr2patient.map: 0 findings
}|

The first command compiles the profile and holds its example patient to it. The second does the
same for an example that is meant to fail, kept in a folder of its own so that the first command
stays a clean pass. The third checks the map against the shapes of the form and the Patient.
@tt{tests.rkt} in the same folder runs all of these, and the program on both sides of the 65th
birthday, as one gate: @tt{raco test tests.rkt}.

To start a project of your own from this one, @tt{raco fhir new pipeline <dir>} copies the folder.

@subsection[#:tag "intake-maps"]{@tt{examples/intake-maps/}: two structures and the map between them}

The previous example was a program. This one is a @italic{project}: a folder of definitions meant
to be published together, with no Racket in it.

@tt{IntakeForm.fsh} describes two structures. The first is a blood pressure reading as the front
desk records it: a patient id, a time, two numbers. It is a @italic{logical model}, a structure of
your own that is not one of FHIR's record types. The second is the Observation the clinic keeps, as
a profile. The file ends with one example form. @tt{IntakeToBP.map} is the map from the first
structure to the second.

@verbatim{
$ raco fsh check examples/intake-maps
fsh check: 1 example, 0 with errors; 0 errors, 0 warnings
  canonical: http://example.org/intake (…/examples/intake-maps/sushi-config.yaml)
}

That one line covers three checks: both structures compile; every element the map reads or writes
exists on them; and the example form, run through the map, comes out as an Observation the profile
accepts.

The project can then be packed into one file, the form FHIR definitions are published in:

@verbatim{
$ raco fsh examples/intake-maps --pack intake.tgz
fsh: packed 4 resource(s) into …/intake.tgz
  StructureDefinition-IntakeForm.json
  StructureDefinition-ScreeningBP.json
  IntakeForm-instance.json
  StructureMap-instance.json
fsh: wrote 4 artifact(s) to examples/intake-maps/fsh-generated
}

(As the last line says, packing also writes the compiled JSON into a @tt{fsh-generated} folder
beside the sources.) A program that has the package can ask for the map by its url and use it as a
function. Given the example form, it answers the Observation, with the panel code, the patient, the
time, and 120 and 80 as its two components:

@racketblock[
(parameterize ([current-sd-packages (list "intake.tgz" core)])
  ((structure-map "http://example.org/intake/StructureMap/IntakeToBP") form))
]

@tt{tests/intake-maps-test.rkt} does all three steps. The
@hyperlink["https://oloveluck.github.io/fml/"]{fml manual} covers maps themselves, and the
directory's @tt{README.md} this project.

@subsection[#:tag "screening"]{@tt{screening/}: one program in seven languages}

This is the example the others lead up to. A clinic wants to know which patients have high blood
pressure. It has some readings on file, and more arrive on intake forms. The program is nine short
files:

@tabular[#:style 'boxed #:sep @hspace[2]
(list (list @bold{file} @bold{language} @bold{its job})
      (list @tt{profile.fsh} "FHIR Shorthand" "what a screening blood pressure must contain; two patients and one reading already on file")
      (list @tt{forms.fhir6} "FHIR R6 resources" "two intake forms, checked against FHIR as the file compiles")
      (list @tt{intake.fml} "FHIR Mapping Language" "a form becomes a reading")
      (list @tt{bp-panels.vcl} "ValueSet Compose Language" "which codes count as a blood pressure panel")
      (list @tt{screening.cql} "Clinical Quality Language" "the rule: highest systolic of 140 or more")
      (list @tt{readings.sof} "SQL on FHIR" "the readings as a flat table")
      (list @tt{pipeline.rkt} "Racket" "joins the six above")
      (list @tt{app.rkt} "the capability language" "declares the same thing as a FHIR server")
      (list @tt{main.rkt} "Racket" "prints the result; its tests check it"))]

@verbatim{
$ racket screening/main.rkt
intake: 2 forms mapped and valid against http://example.org/StructureDefinition/screening-blood-pressure
panel codes (from bp-panels.vcl): 85354-9, 55284-4

patient  date        systolic  diastolic  hypertensive
ann      2026-09-14  152       96        yes
ann      2026-10-02  148       92        yes
bo       2026-10-03  124       79        no
}

The first line says the two forms were converted by the map and that each result passed the
profile. The second is the list of codes, worked out from the one-line value set. The table has a
row for each reading, the one on file and the two from the forms, made by the SQL on FHIR view. The
last column is the rule's answer for that row's patient: Ann's highest systolic is 152, so she is
flagged on both her rows; Bo's is 124.

What makes this one program, not seven tools glued together, is that each file is a module. The
Racket program asks for them by name, as it would any library:

@racketblock[
(require (only-in "profile.fsh"    [compiled clinic])
         (only-in "forms.fhir6"    [->json forms])
         (only-in "intake.fml"     [transform intake->reading])
         (only-in "bp-panels.vcl"  [valueset bp-panels])
         (only-in "screening.cql"  [evaluate screen])
         (only-in "readings.sof"   [->json view-definitions]))

(~> form intake->reading (ensure-valid #:profile profile))    (code:comment "the map, then the profile")
($expand #:valueSet bp-panels)                                (code:comment "the value set, as its codes")
(screen patient-data #:parameters (hash "Panel Codes" codes)) (code:comment "the rule over one patient")
(view-rows view)                                              (code:comment "the table")
]

Three things follow from that.

@itemlist[
@item{@bold{A mistake in any file stops the program from building}, and is reported in that file,
at its line, in that language's terms: a misspelt element in the profile, an unknown function in
the rule, a form that is not valid FHIR.}
@item{@bold{The places where two languages meet are checked too.} Before any form is converted,
the map is checked against the profile it says it produces. Each converted reading is then held to
the profile. A map that wrote the panel code without its display text was caught this way while
the example was being written.}
@item{@bold{Nothing has to be registered by hand.} Asking for @tt{profile.fsh} is what makes its
profile findable by its url; the same goes for the map and the value set.}]

The directory's own @tt{README.md} goes through each of these in more detail.

@bold{The same program, served.} @tt{app.rkt} declares what a server offers: two record types, the
map as @tt{$transform}, @tt{$validate}, @tt{$expand}, and the whole screening as one operation of
its own, @tt{$screen}. The server's description of itself (its @italic{CapabilityStatement}) is
derived from those declarations, so it cannot disagree with what runs. @tt{racket screening/app.rkt}
prints that description. To serve it:

@verbatim|{
$ raco fhir-server serve screening/app.rkt 8080
FHIR server on http://localhost:8080  (Ctrl-C, or kill 8353, to stop)
…

$ curl -X POST 'localhost:8080/$screen' -d '{"resourceType":"Parameters","parameter":[{"name":"patient","valueString":"ann"}]}'
{"resourceType":"Parameters","parameter":[{"name":"highest","valueInteger":152},{"name":"hypertensive","valueBoolean":true}]}

$ curl 'localhost:8080/$screen?patient=bo'
{"resourceType":"Parameters","parameter":[{"name":"highest","valueInteger":124},{"name":"hypertensive","valueBoolean":false}]}
}|

@subsection[#:tag "notes"]{@tt{notes-to-fhir/}: clinic notes to FHIR, with a model}

A doctor's note is free text: "65 y/o F here for f/u of HTN … BP 152/96 seated … Continue
lisinopril". Here a language model reads such a note and writes it as FHIR records. What decides
whether the model got it right is not a person and not another model. It is a small specification,
four profiles and two lists of allowed codes in @tt{ig/}, and the family's validator. Every problem
the validator finds is sent back to the model, naming the record and the element, and the model
tries again until nothing is left. The finished data then goes into the screening rule from the
previous example, unchanged.

A live run calls a model (by default the command @tt{claude -p}) and records every prompt and
answer under @tt{notes-to-fhir/results/}. Three such runs are kept in the repository, and
@litchar{--replay} checks and scores a recorded run again with no model:

@verbatim{
$ racket notes-to-fhir/main.rkt --replay notes-to-fhir/results/2026-11-03T2336-brief

note      rounds  issues per round     patient  readings  problems  medications
alvarez   2       1 -> 0               4/4      1/1       1/1       1/1
chen      2       3 -> 0               4/4      2/2       1/1       1/1
ng        2       3 -> 0               4/4      1/1       2/2       2/2
okafor    2       2 -> 0               4/4      1/1       1/1       1/1
(right/expected, +extra; issues are what the profiles rejected in each round)

screening rule (../screening/screening.cql) over the extracted data:
  alvarez: highest systolic 118, hypertensive: no
  chen: highest systolic 158, hypertensive: yes
  ng: highest systolic 152, hypertensive: yes
  okafor: highest systolic 124, hypertensive: no
}

There is one row for each of the four notes. @bold{issues per round} is how many problems the
validator found in the model's first answer and in its second: every note was clean by the second
round. The four columns after it compare the final answer with an answer key written by hand:
facts right out of facts expected, for the patient's details, the blood pressure readings, the
diagnoses and the medications. The lines at the bottom are the screening rule run over what the
model extracted.

The notes are synthetic, and each has a trap: a lab result the specification has no place for, a
"no history of hypertension", a father's diabetes, a reading with no date.

In this run the model was told only the profiles' names (@litchar{--brief}), so it learned the
rest from the validator's messages. The other two recorded runs show the contrast. Given the whole
specification in the prompt, the model was right first time. Given only names, and an earlier
validator whose message said "value does not match required pattern" without saying which pattern,
it never got there. The directory's @tt{README.md} tells that story: a check is only as useful to
a model as its message is specific.

@tabular[#:style 'boxed #:sep @hspace[2]
(list (list @tt{racket notes-to-fhir/main.rkt --replay <run>} "a recorded run, checked and scored again; no model")
      (list @tt{racket notes-to-fhir/main.rkt} @elem{every note, live; needs a model command (@litchar{--model}, default @tt{claude -p})})
      (list @tt{racket notes-to-fhir/main.rkt --brief} "live, with only the profiles' names and urls in the prompt")
      (list @tt{… --rounds 3 --timeout 600 [note …]} "how many tries, seconds allowed for each, and which notes"))]

@subsection[#:tag "ig-servers"]{@tt{ig-servers/}: servers generated from published guides}

An @italic{implementation guide} (IG) is a published set of FHIR rules for one purpose: Australia's
core records, a health plan's provider directory. A guide includes a statement of what a server
that follows it must do, and examples of valid records. The family's server package can generate a
working server from a guide's package alone. This example asks whether such a server really does
what the guide says, for six guides the generator was not written for.

Nothing is expected by hand; each guide is its own test. Every example the guide publishes must be
accepted by the server, read back as written, and found by every search the guide says the server
supports. Every example deliberately broken (a required element removed, a date that is not a date)
must be refused. And everything the guide's statement requires must be offered.

This example needs the network: it downloads each guide's package, and the packages it depends on,
from @tt{packages.fhir.org} into @tt{ig-servers/packages/}, and it rewrites the files in
@tt{ig-servers/results/}.

@tabular[#:style 'boxed #:sep @hspace[2]
(list (list @tt{racket ig-servers/main.rkt} "download, generate and check all six; one line each")
      (list @tt{racket ig-servers/main.rkt -v hl7.fhir.uv.ipa} "one guide, with every failure printed")
      (list @tt{raco test ig-servers/verify-test.rkt} "hold the recorded results as minimums, for the guides already downloaded; no network"))]

The recorded results, from @tt{ig-servers/results/}:

@tabular[#:style 'boxed #:sep @hspace[2]
(list (list @bold{guide} @bold{types} @bold{unmet} @bold{accepted} @bold{read back} @bold{search} @bold{includes} @bold{refused})
      (list "International Patient Access 1.1.0" "11" "0" "15/15" "15/15" "56/56" "19/19" "61/61")
      (list "AU Core 2.0.0" "19" "0" "65/65" "64/64" "264/264" "11/11" "283/283")
      (list "Da Vinci PDex Plan-Net 1.2.0" "8" "0" "87/87" "49/49" "212/212" "332/332" "182/182")
      (list "Da Vinci Drug Formulary 2.1.0" "4" "0" "43/43" "22/22" "104/104" "22/22" "106/106")
      (list "CARIN Blue Button 2.2.0" "6" "0" "104/104" "42/42" "184/184" "144/144" "460/460")
      (list "SDC 4.0.0 (form manager)" "7" "13" "80/80" "35/35" "29/29" "none" "158/158"))]

@bold{types} is how many kinds of record the server serves; @bold{unmet} is how many of the
guide's requirements it does not meet. SDC's thirteen are two features that are not implemented:
searches that combine two values, and one optional operation. The directory's @tt{README.md}
explains each check and lists the five defects in the generator that this example found.

@section[#:tag "bench"]{The benchmark}

@subsection{The idea}

A @italic{profile} is the part of a FHIR specification that says what a valid record of some kind
must contain: which elements are required, which codes are allowed, how a list is divided up.
Profiles are written by committees, published with paragraphs of explanation, and take skill to
write. The question the benchmark asks is: given only the explanation, can a language model write
the profile?

It answers with real published work, not made-up exercises. Take a published guide. Remove one
profile and its examples from the guide's sources. Show the model what the guide @italic{says}
about that profile in words, and ask it to write the profile, with an example, in FHIR Shorthand.
Then compare the answer with the profile that was removed.

The model is told the profile's description and, for each element the profile constrains, the
guide's own sentence about it. It is never told a constraint: not a count, not a code, not a type.
This is the start of the prompt for mCODE's tumor size profile (mCODE is a published guide for
cancer data):

@verbatim|{
Write `Profile: TumorSize` with `Id: mcode-tumor-size` […], and at least one example `Instance` of
it that is valid against it. […]

## What the IG says about this profile

Records the dimensions of a tumor

## The elements it constrains, in the IG's words

- `Observation.code`: (no description published)
- `Observation.subject`: The patient whose tumor was measured. — The patient whose tumor was
  measured. SHALL be a `Patient` resource conforming to `CancerPatient`.
- `Observation.focus`: Identifies a tumor that has NOT been removed from the body — …
…
}|

After an answer that does not compile, the model gets the errors, each at its line, and may try
again. So the benchmark measures the loop a person works in: write, check, fix.

@subsection[#:tag "scores"]{The four scores}

An answer is a profile and at least one example of it. Each score asks a different question, and
an answer can do well on one and badly on another.

@itemlist[
@item{@bold{Does it check?} (@tt{check errors}) The answer is compiled inside the rest of the
guide, and its own examples are held to its own profile. The score is the number of errors; 0 is
what you want. This is the only score the model is shown between rounds.}
@item{@bold{Does it say what the published profile says?} (@tt{fidelity}) For each element the
published profile constrains, the answer's version is compared point by point: how many values are
required and allowed, whether the element is marked as one systems must support, which types it
may be, which list of codes it is tied to, any fixed value, and how a list is divided into named
parts. The score is points agreed out of points there are, such as 30/34. Elements the answer
constrains that the published profile does not are counted separately, as @tt{extra elements}.}
@item{@bold{Does it accept real data?} (@tt{accepts published examples}) The guide's own examples
of this profile, written by its authors, are checked against the answer's profile. A profile that
refuses them is wrong in a way that matters: it would turn away valid records.}
@item{@bold{Does its own data pass?} (@tt{examples conform to the published profile}) The other
direction: the examples the model wrote are checked against the published profile. This shows
whether the model understood what a valid record looks like, apart from how well it wrote the
rules.}]

Two reference answers mark the ends of the scale. @litchar{--oracle} scores the guide's own text
for the profile, the best any answer can do through this toolkit. @litchar{--empty} scores no
answer at all.

@subsection{Trying it}

You need a guide's FHIR Shorthand sources and its published package. mCODE 4.0.0 has both at hand:
its sources are in the fsh repository's tests, and its package comes with the family. With the
repositories side by side:

@bold{1. See which profiles can be tasks.} A profile qualifies when no other profile in the guide
is built on it, so it can be taken out alone.

@verbatim{
$ raco spec-bench list ../fsh/tests/vendor/mcode-4.0.0
MCODEPatientGroup	mcode-patient-group	1 examples
MCODEPatientBundle	mcode-patient-bundle	1 examples
Comorbidities	mcode-comorbidities	2 examples
…
TumorSize	mcode-tumor-size	2 examples
…
}

It lists 36 profiles for mCODE, each with its id and how many examples the guide has of it.

@bold{2. Make a task.} This writes a folder holding the guide without the profile
(@tt{project/}), the prompt (@tt{prompt.md}) and the task's record (@tt{task.rktd}).

@verbatim{
$ raco spec-bench make ../fsh/tests/vendor/mcode-4.0.0 hl7.fhir.us.mcode-4.0.0 TumorSize task/
…/task/
}

@bold{3. Score the two reference answers.}

@verbatim{
$ raco spec-bench score task/ --oracle
TumorSize: check errors 0 (0 in the candidate); profile compiled; fidelity 34/34 facets, 0 extra elements; accepts 2/2 published examples; 2/2 of its examples conform to the published profile

$ raco spec-bench score task/ --empty
TumorSize: check errors 0 (0 in the candidate); profile MISSING; fidelity 0/34 facets, 0 extra elements; accepts 0/2 published examples; 0/0 of its examples conform to the published profile
}

Each line has the four scores in order. Each of these steps takes ten to fifteen seconds, because
the whole guide is compiled.

@bold{4. Score an answer.} Any file of FHIR Shorthand can be scored. The repository keeps a
model's recorded answers, so you can score one without calling a model:

@verbatim|{
$ raco spec-bench score task/ results/2026-11-03/TumorSize/round-1.fsh
TumorSize: check errors 1 (1 in the candidate); profile compiled; fidelity 30/34 facets, 0 extra elements; accepts 0/2 published examples; 0/1 of its examples conform to the published profile
  rejected: tumor-size-jenny-m: Observation.code value does not match required pattern {"coding":[{"code":"246116008","display":"Lesion size","system":"http://snomed.info/sct"}]}
  …
  rejected: candidate tumor-size-imaging-example: Observation.code value does not match required pattern {"coding":[{"code":"21889-1","system":"http://loinc.org"}]}
/input/fsh/zz-candidate.fsh:84:1: fsh compile error: instance: cancer-patient-eve-anyperson: the CancerPatient instance id `cancer-patient-eve-anyperson` is already used (/fsh/EX_Basic.fsh:107)
…
}|

This answer shows why there are four scores. Its rules agree with the published profile on 30 of
34 points. But it accepts none of the guide's examples, and its own example fails the published
profile. The first and last @tt{rejected} lines say why: for "tumor size" the model fixed a
SNOMED CT code, and the guide's authors fixed a LOINC code. Nothing in the prose says which. A
profile can be nearly right in shape and still turn away every real record over one code. (The
one check error is an example patient whose id is already used in the guide.)

@bold{5. Run a model.} This step calls a model, so it costs what the model costs:

@verbatim{
raco spec-bench run task/ --model 'claude -p' --rounds 3 --timeout 1200
}

The model is any shell command that reads the prompt on its standard input and writes its answer
on its standard output; the last block marked @tt{@literal{```fsh}} in the answer is taken as the profile.
Each round's prompt, raw answer, extracted profile and anything the command printed as an error
are kept under @tt{task/runs/<time>/}, and each round's scores are added as a line to
@tt{task/results.jsonl}. After a round whose answer has errors, the next prompt carries that
answer and the errors. Rounds stop when the answer checks clean, or after @litchar{--rounds}. A
round that runs past @litchar{--timeout} seconds is stopped, and the run ends there with no answer
for that round.

@subsection{Recorded results}

Three mCODE profiles were given to one model (@tt{claude -p}) on 2026-11-03. Every prompt and
answer is in @tt{results/2026-11-03/}. As scored that day:

@tabular[#:style 'boxed #:sep @hspace[2]
(list (list @bold{task} @bold{rounds} @bold{fidelity} @bold{published examples accepted} @bold{own examples conform})
      (list "TumorSize" "1" "30/34" "0/2" "0/1")
      (list "CancerDiseaseStatus" "2" "16/20" "0/3" "0/1")
      (list "ECOGPerformanceStatus" "1" "6/8" "2/2" "1/1"))]

As the repository's @tt{TESTING.md} records, every rejected example came down to a code the
published profile fixes and the prompt does not state, and CancerDiseaseStatus's first answer had
one error, which the second round fixed from the message.

These are the numbers of that day. The compiler and the checker have changed since, so scoring
the same recorded answers today gives somewhat different numbers: the guide's own text now scores
full marks on all three profiles (34/34, 20/20 and 8/8; it was 28/34, 14/20 and 5/8 then), and the
checker now reports an example whose id repeats one already in the guide, as step 4 above shows.
Three tasks from one guide and one model are a demonstration of the method, not a ranking.

@section{For an AI agent}

Two of the examples are about a model working with these tools: @secref["notes"] and
@secref["bench"]. Both drive the model through a shell command and files, so any model with a
command-line client can be used. Neither is how an agent would normally use the family. For that,
see @hyperlink["https://oloveluck.github.io/fhir/fhir-mcp/index.html"]{fhir-mcp}, which gives an
agent a workspace with the same languages and checks.

@section{Limits}

@itemlist[
@item{@bold{They need Racket.} The examples are programs, not files for the standalone tools.}
@item{@bold{FHIR versions differ between examples.} The screening forms are FHIR R6; the pipelines
validate in R5; the notes specification and every CQL rule are R4. The examples use only elements
that are the same across those versions.}
@item{@bold{The data is made up.} Every patient, form and note was written for the example.}
@item{@bold{The benchmark needs a guide's sources}, not only its package, and only profiles that
nothing else in the guide builds on can be tasks.}
@item{@bold{The prompt gives one hint.} It names which elements the profile constrains, as a
guide's own "key elements" page does. It gives no constraint.}
@item{@bold{Fidelity compares the listed points only}, as this toolkit compiles them. Descriptions
and other text are not compared.}
@item{@bold{The recorded results are small and dated}: three profiles of one guide, one model, one
day, scored with the toolkit of that day.}
@item{@bold{@tt{ig-servers} does not download terminology packages.} The large code-system and
extension packages are skipped, and the generated servers accept what those packages define
without checking it.}]

@section[#:tag "words"]{Words used here}

@itemlist[
@item{@bold{FHIR}: the health-care standard for records exchanged between systems.
@bold{Resource}: one record of a given kind (a Patient, an Observation), written as JSON.}
@item{@bold{Profile}: rules that narrow a kind of resource for one use: what is required, which
codes are allowed.}
@item{@bold{Implementation guide} (IG): a published set of profiles, code lists and examples for
one purpose. Its @bold{package} is the file it is distributed as. @bold{mCODE} is one, for cancer
data.}
@item{@bold{FHIR Shorthand} (FSH): the language profiles and examples are written in.}
@item{@bold{FHIR Mapping Language} (FML), a @bold{map}: rules that turn a record of one shape into
another. A @bold{StructureMap} is a map in its published form.}
@item{@bold{CQL} (Clinical Quality Language): the language clinical rules are written in.}
@item{@bold{Value set}: a named list of codes. @bold{VCL}: a one-line way to write one.}
@item{@bold{SQL on FHIR}, a @bold{view}: a description of how resources become the rows of a table.}
@item{@bold{Logical model}: a structure of your own, described the way FHIR describes its own
types, but not one of them.}
@item{@bold{QuestionnaireResponse}: the FHIR resource for a filled-in form.}
@item{@bold{Operation}: a named action the standard defines, written with a dollar sign
(@tt{$validate}, @tt{$transform}, @tt{$expand}). @bold{OperationOutcome}: the resource that
reports a problem. @bold{Parameters}: the resource that carries an operation's inputs or outputs.}
@item{@bold{Validate}: check a resource against FHIR's rules and a profile's.}
@item{@bold{Canonical}: the url that names a definition (a profile, a map, a value set), wherever
it is stored.}
@item{@bold{CapabilityStatement}: a server's own description of what it supports.}
@item{@bold{LOINC}, @bold{SNOMED CT}, @bold{RxNorm}: the code systems for lab tests and
measurements, clinical terms, and medications.}
@item{@bold{Model}: here, a language model. @bold{Round}: one answer from it.
@bold{Oracle}: the guide's own text for a profile, scored as if it were an answer.}
@item{@bold{Differential}: the part of a compiled profile that lists only what it changes; it is
what the fidelity score compares.}]

@section{How it is tested}

Each example checks itself. @tt{raco test .} in the repository runs all of the following:

@itemlist[
@item{@tt{screening/main.rkt}: the program's results, each place two languages meet (a map with a
misspelt element must be reported at its line), the @tt{$screen} operation, and the server.}
@item{@tt{examples/intake-pipeline/tests.rkt}: the profile's example passes, the invalid one fails
at its line, the map's result fits the profile, and the answer changes on the 65th birthday.}
@item{@tt{tests/intake-maps-test.rkt}: the project checks clean, packs, and its map works when
asked for by url from the package.}
@item{@tt{notes-to-fhir/replay-test.rkt}: the three recorded runs replay to the same scores, with
no model.}
@item{@tt{tests/bench-r4-test.rkt}: on mCODE's TumorSize, the prompt leaks no fixed code, the
guide's own text scores at least 28 of 34 on fidelity with every example passing, and an empty
answer scores 0.}
@item{@tt{ig-servers/verify-test.rkt}: the recorded results hold as minimums, for the guides that
have been downloaded; the rest are skipped.}]

Runs that need a model are not tests; they are recorded, in @tt{results/} and
@tt{notes-to-fhir/results/}. The repository's @tt{TESTING.md} has the benchmark's method and
recorded results.

@section{Reference}

@subsection[#:style 'unnumbered]{@tt{raco spec-bench}}

@verbatim{
raco spec-bench list <ig-dir>
raco spec-bench make <ig-dir> <published-package> <Profile> <task-dir>
raco spec-bench score <task-dir> (--oracle | --empty | <candidate.fsh>)
raco spec-bench run <task-dir> --model '<shell command>' [--rounds n] [--timeout seconds]
}

@tt{<published-package>} is a path, a file name among the family's packages, or a package name
(@tt{hl7.fhir.us.mcode-4.0.0}). @tt{--rounds} defaults to 3 and @tt{--timeout} to 1200 seconds.

@subsection[#:style 'unnumbered]{@tt{fhir-examples/bench}}
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
@tt{@literal{```fsh}} block is the candidate), through files, its process group killed past the timeout. Each
round's prompt, answer, FSH and score go under @tt{runs/<stamp>/} and a line is appended to
@tt{results.jsonl}. After a round with @tt{check} errors the next prompt carries the answer and the
diagnostics; rounds stop when the answer checks clean.}
@defproc[(published-package [name string?]) path?]{A package by path, by file name in @tt{fhir-spec}, or by name (@racket["hl7.fhir.us.mcode-4.0.0"]).}

@subsection[#:style 'unnumbered]{@tt{fhir-examples/model}}
@defmodule[fhir-examples/model]

The shared model runner: the benchmark and @tt{notes-to-fhir} both talk to a model through it.

@defproc[(ask [command string?] [prompt-file path-string?] [answer-file path-string?] [err-file path-string?] [timeout real?]) (values any/c real? boolean?)]{
Runs a shell command with the prompt file on stdin and its output in the answer and error files;
returns the exit code, the seconds taken, and whether it timed out.}
@defproc[(extract-block [answer string?] [language string?]) string?]{The last fenced block of that language, else the last fenced block, else the whole answer.}

@subsection[#:style 'unnumbered]{@tt{fhir-examples/ig-servers/verify}}
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
