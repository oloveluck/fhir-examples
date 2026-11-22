# QTc operation, version 3

Operation `$qtc`, system level: `POST /$qtc` with a Parameters resource. Every parameter is given at most once.

## Inputs

- `qt-ms` (decimal, required): Measured QT interval, in milliseconds (ms).
- `heart-rate` (integer, required): Heart rate at the time of the recording, in beats per minute.
- `qrs-ms` (integer, required): QRS duration, in milliseconds (ms).
- `formula` (code, required): Rate-correction formula to apply.
- `sex` (code, optional): Sex of the patient; selects the prolongation threshold. If left out, the higher (female) threshold is used.
- `ecg-date` (date, optional): Date the ECG was recorded; checked only, it does not enter the computation.

## Bound codes

`formula` is bound (required) to value set http://example.org/fhir/ValueSet/qtc-formula, code system http://example.org/fhir/CodeSystem/qtc-formula. The value set holds exactly these codes:
- `bazett`: QTc = QT / sqrt(RR)
- `fridericia`: QTc = QT / RR^(1/3)

`sex` is bound (required) to value set http://example.org/fhir/ValueSet/qtc-sex, code system http://hl7.org/fhir/administrative-gender. The value set holds exactly: `male`, `female`. Codes are case-sensitive.

## Rules (a request breaking one is rejected with a 4xx status)

- `qt-ms` is from 200 to 800 inclusive.
- `heart-rate` is from 30 to 250 inclusive.
- `ecg-date`, if given, is not after today's date (UTC).
- `qt-ms` is less than the RR interval in ms, i.e. `qt-ms` < 60000 / `heart-rate`.
- `qrs-ms` is from 40 to 300 inclusive.
- `qrs-ms` is less than `qt-ms`.

## Computation

1. RR = 60 / `heart-rate` (seconds).
2. Adjusted QT, QTa: if `qrs-ms` >= 120 then QTa = `qt-ms` - (`qrs-ms` - 100); otherwise QTa = `qt-ms`. (A QRS of exactly 120 is adjusted.)
3. QTc by `formula`, using QTa in ms, RR in seconds and heart-rate in bpm, without intermediate rounding:
   - `bazett`: QTc = QTa / sqrt(RR)
   - `fridericia`: QTc = QTa / RR^(1/3)
4. Threshold: 450 ms if `sex` is `male`; 460 ms if `sex` is `female` or not given.
5. `prolonged` is true when the unrounded QTc is strictly greater than the threshold, else false.
6. Round outputs as stated below (half up).

## Outputs (all always present)

- `qtc` (decimal, ms): QTc rounded to 1 decimal.
- `prolonged` (boolean).
