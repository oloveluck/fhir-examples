# Estimated GFR, CKD-EPI 2021 (creatinine) - version 2

System-level operation `$ckd-epi-egfr`, called by `POST /$ckd-epi-egfr`. It computes the race-free CKD-EPI 2021 creatinine equation and the GFR category.

## Inputs

- `creatinine` (decimal, 1..1): serum creatinine, in the unit given by `creatinineUnit`.
- `age` (integer, 1..1): age in years.
- `sex` (code, 1..1, required binding to http://example.org/fhir/ValueSet/ckdepi-sex): code system `http://hl7.org/fhir/administrative-gender`; the value set holds exactly two codes: `male`, `female` (lower case).
- `creatinineUnit` (code, 1..1, required binding to http://example.org/fhir/ValueSet/ckdepi-creatinine-unit): code system `http://unitsofmeasure.org`; the value set holds exactly two codes: `mg/dL`, `umol/L`.
- `sampleDate` (date, 0..1, optional): date the sample was taken. It does not enter the computation.

## Rules (a request breaking one is answered 4xx)

1. `creatinine`, once converted to mg/dL (step 1 below), must be from 0.2 to 20 mg/dL, both ends included. (So in umol/L: 17.68 to 1768.)
2. `age` must be from 18 to 120 years, both ends included.
3. `sampleDate`, when given, must not be after the current date of the server.

## Computation

1. Scr = `creatinine` if `creatinineUnit` is `mg/dL`; Scr = `creatinine` / 88.4 if it is `umol/L`.
2. If `sex` is `female`: kappa = 0.7, alpha = -0.241, sexFactor = 1.012. If `male`: kappa = 0.9, alpha = -0.302, sexFactor = 1.
3. egfr = 142 * min(Scr/kappa, 1)^alpha * max(Scr/kappa, 1)^(-1.200) * 0.9938^age * sexFactor (unrounded value used below).
4. stage, from the unrounded egfr: `G1` if egfr >= 90; `G2` if 60 <= egfr < 90; `G3a` if 45 <= egfr < 60; `G3b` if 30 <= egfr < 45; `G4` if 15 <= egfr < 30; `G5` if egfr < 15.
5. Round egfr to 1 decimal for the output.

## Outputs (always both)

- `egfr` (decimal): eGFR in mL/min/1.73 m2, rounded to 1 decimal (`valueDecimal`).
- `stage` (code, `valueCode`): one of `G1`, `G2`, `G3a`, `G3b`, `G4`, `G5` as in step 4.
