# Anion gap with albumin correction (version 4)

Operation code `anion-gap`, called at `POST /$anion-gap` with a Parameters resource. Every input may be given at most once.

## Inputs

- `sodium` (decimal, required): Serum sodium in mmol/L. Must be from 100 to 180.
- `chloride` (decimal, required): Serum chloride in mmol/L. Must be from 60 to 140, and sodium must be greater than chloride.
- `bicarbonate` (decimal, required): Serum bicarbonate in mmol/L. Must be from 2 to 60.
- `method` (code, required): Gap method, a code of the value set http://example.org/fhir/ValueSet/anion-gap-method (code system http://example.org/fhir/CodeSystem/anion-gap-method): standard or with-potassium.
- `potassium` (decimal, optional): Serum potassium in mmol/L, from 1.0 to 10.0. Required when method is with-potassium; ignored in the computation when method is standard.
- `albumin` (decimal, optional): Serum albumin in g/dL, from 0.5 to 6.0. When given, the gap is albumin-corrected.
- `lactate` (Quantity, required): Blood lactate as a Quantity with system http://unitsofmeasure.org and code mmol/L or mg/dL (no other code). Its value in mmol/L (mg/dL divided by 9.008) must be from 0 to 30.

## Code system and value set

`method` is bound (required) to value set `http://example.org/fhir/ValueSet/anion-gap-method`, which holds exactly the codes of code system `http://example.org/fhir/CodeSystem/anion-gap-method`: `standard` and `with-potassium`. Codes are case-sensitive.

## Rules

A request that breaks any of these is rejected with a 4xx status and an OperationOutcome:
- every required input is present; no input is given more than once; each input has its declared type;
- `method` is one of the two codes;
- sodium 100 to 180, chloride 60 to 140, bicarbonate 2 to 60, potassium (if given) 1.0 to 10.0, albumin (if given) 0.5 to 6.0, all inclusive;
- sodium is greater than chloride (not equal);
- if `method` is `with-potassium`, `potassium` is given.
- lactate's code is `mmol/L` or `mg/dL` and its system is http://unitsofmeasure.org; lactate in mmol/L (value if mmol/L, value / 9.008 if mg/dL) is from 0 to 30 inclusive. A lactate given as a decimal is of another type and rejected.

## Computation

1. gap = sodium - chloride - bicarbonate; if method is `with-potassium`, add potassium.
2. If albumin is given: corrected = gap + 2.5 * (4.4 - albumin). Otherwise there is no corrected gap.
3. base = corrected if it exists, otherwise gap.
4. value = base - lactate (lactate in mmol/L; a mg/dL lactate is first divided by 9.008).
5. Category from value (unrounded), by method: for `standard`, `low` if value < 6, `high` if value > 12, else `normal`; for `with-potassium`, `low` if value < 10, `high` if value > 16, else `normal`. (Thresholds themselves are `normal`.)
6. Round the numeric outputs to 1 decimal (from the unrounded numbers).

## Outputs

- `anion-gap` (decimal): Anion gap in mmol/L, 1 decimal.
- `corrected-anion-gap` (decimal): Albumin-corrected anion gap in mmol/L, 1 decimal. Present only when albumin is given.
- `adjusted-gap` (decimal): Value the category is based on (corrected gap if present, else gap, minus lactate), in mmol/L, 1 decimal. Always present.
- `gap-category` (code): low, normal or high. Always present.

An answer is a Parameters resource holding exactly the outputs above (the optional one only as stated), each under its declared type key (`valueDecimal`, `valueCode`).
