# Changes in v2

- New REQUIRED input `creatinineUnit` (code, `mg/dL` or `umol/L`). `creatinine` is now read in that unit; umol/L values are divided by 88.4 before the equation.
- The 0.2-20 range rule applies to creatinine after conversion to mg/dL.
