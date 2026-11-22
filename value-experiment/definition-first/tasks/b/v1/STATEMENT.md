# QTc operation, version 1

Operation `$qtc`, system level: `POST /$qtc` with a Parameters resource. Every parameter is given at most once.

## Inputs

- `qt-ms` (decimal, required): Measured QT interval, in milliseconds (ms).
- `heart-rate` (integer, required): Heart rate at the time of the recording, in beats per minute.
- `formula` (code, required): Rate-correction formula to apply.
- `sex` (code, optional): Sex of the patient; selects the prolongation threshold. If left out, the higher (female) threshold is used.
- `ecg-date` (date, optional): Date the ECG was recorded; checked only, it does not enter the computation.

## Bound codes

`formula` is bound (required) to value set http://example.org/fhir/ValueSet/qtc-formula, code system http://example.org/fhir/CodeSystem/qtc-formula. The value set holds exactly these codes:
- `bazett`: QTc = QT / sqrt(RR)
- `fridericia`: QTc = QT / RR^(1/3)
- `framingham`: QTc = QT + 154 * (1 - RR)
- `hodges`: QTc = QT + 1.75 * (heart-rate - 60)

`sex` is bound (required) to value set http://example.org/fhir/ValueSet/qtc-sex, code system http://hl7.org/fhir/administrative-gender. The value set holds exactly: `male`, `female`. Codes are case-sensitive.

## Rules (a request breaking one is rejected with a 4xx status)

- `qt-ms` is from 200 to 800 inclusive.
- `heart-rate` is from 30 to 250 inclusive.
- `ecg-date`, if given, is not after today's date (UTC).
- `qt-ms` is less than the RR interval in ms, i.e. `qt-ms` < 60000 / `heart-rate`.

## Computation

1. RR = 60 / `heart-rate` (seconds).
2. QTc by `formula`, using QT (= `qt-ms`) in ms, RR in seconds and heart-rate in bpm, without intermediate rounding:
   - `bazett`: QTc = QT / sqrt(RR)
   - `fridericia`: QTc = QT / RR^(1/3)
   - `framingham`: QTc = QT + 154 * (1 - RR)
   - `hodges`: QTc = QT + 1.75 * (heart-rate - 60)
3. Threshold: 450 ms if `sex` is `male`; 460 ms if `sex` is `female` or not given.
4. `prolonged` is true when the unrounded QTc is strictly greater than the threshold, else false.
5. Round outputs as stated below (half up).

## Outputs (all always present)

- `qtc` (decimal, ms): QTc rounded to 1 decimal.
- `prolonged` (boolean).
