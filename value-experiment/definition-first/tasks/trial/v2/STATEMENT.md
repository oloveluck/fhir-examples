# energy-needs (version 2)

Called at `POST /$energy-needs`. Estimates, for an adult, the basal metabolic rate (Mifflin-St Jeor equation), the body mass index and a daily energy target.

## Inputs

- `weight` (decimal, required, max 1): body weight in kilograms.
- `height` (decimal, required, max 1): standing height in centimetres.
- `age` (integer, required, max 1): age in whole years.
- `sex` (code, required, max 1): bound (required) to value set `http://example.org/fhir/ValueSet/energy-sex`, which holds the codes `male` and `female` of code system `http://hl7.org/fhir/administrative-gender` (no others).
- `activity` (code, optional, max 1): bound (required) to value set `http://example.org/fhir/ValueSet/energy-activity`, code system `http://example.org/fhir/CodeSystem/activity-level`, holding exactly: `sedentary`, `light`, `moderate`, `active`, `very-active`. When omitted it is `sedentary`.
- `goal` (code, required, max 1): bound (required) to value set `http://example.org/fhir/ValueSet/energy-goal`, code system `http://example.org/fhir/CodeSystem/energy-goal`, holding exactly: `maintain`, `lose`, `gain`.

Codes are compared exactly (lower case). Every input is given at most once, under its declared type's `value[Type]` key.

## Rules (a request breaking one is refused with 4xx)

1. `age` is from 18 to 100 inclusive.
2. `weight` is from 20 to 400 inclusive (kg).
3. height is from 100 to 230 inclusive (cm).
4. The body mass index (below) is from 12 to 70 inclusive.

## Computation

Let w = weight, h = height in cm, a = age. Use unrounded intermediate values; round only the outputs, half up.

1. bmi = w / (h/100)^2
2. bmr = 10*w + 6.25*h - 5*a + k, with k = +5 for `male` and k = -161 for `female`.
3. factor by activity: sedentary 1.2, light 1.375, moderate 1.55, active 1.725, very-active 1.9.
4. adjustment by goal: maintain 0, lose -500, gain +500 (kcal/day).
5. energy = bmr * factor + adjustment.

## Outputs (all always present)

- `bmr` (decimal): kcal/day, rounded to 0 decimals.
- `bmi` (decimal): kg/m2, rounded to 1 decimal.
- `energy` (decimal): kcal/day, rounded to 0 decimals.
