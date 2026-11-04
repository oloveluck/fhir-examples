# Structures and the maps between them, as one project

`IntakeForm.fsh` defines the structures: a logical model (the intake form as the desk records it)
and a profile (the Observation the clinic keeps), plus an example form. `IntakeToBP.map` is the
arrow between them in the FHIR Mapping Language. The project is checked and packed as one unit:

```sh
raco fsh check examples/intake-maps          # structures compile; the map's paths exist on them;
                                             # the example form transforms to a valid ScreeningBP
raco fsh examples/intake-maps --pack intake.tgz   # StructureDefinitions + the StructureMap, one package
```

In a program the map is a value, resolved by its canonical from the package:

```racket
(parameterize ([current-sd-packages (list "intake.tgz" core)])
  ((structure-map "http://example.org/intake/StructureMap/IntakeToBP") form))   ; a ScreeningBP
```

`tests/intake-maps-test.rkt` does all three.
