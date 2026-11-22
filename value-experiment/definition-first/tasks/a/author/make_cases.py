import json, os, random
HERE = os.path.dirname(os.path.abspath(__file__))
CODE = "ckd-epi-egfr"
SEXVS = "http://example.org/fhir/ValueSet/ckdepi-sex"
UNITVS = "http://example.org/fhir/ValueSet/ckdepi-creatinine-unit"
QUNIT = {"unit": "mL/min/1.73 m2", "system": "http://unitsofmeasure.org", "code": "mL/min/{1.73_m2}"}


def egfr(scr, age, sex):
    k, a = (0.7, -0.241) if sex == "female" else (0.9, -0.302)
    r = scr / k
    v = 142 * min(r, 1) ** a * max(r, 1) ** -1.2 * 0.9938 ** age
    return v * 1.012 if sex == "female" else v


def stage(e):
    for t, s in ((90, "G1"), (60, "G2"), (45, "G3a"), (30, "G3b"), (15, "G4")):
        if e >= t:
            return s
    return "G5"


# ---------- definitions ----------
def P(name, use, mn, mx, typ, doc, vs=None):
    d = {"name": name, "use": use, "min": mn, "max": mx, "type": typ, "documentation": doc}
    if vs:
        d["binding"] = {"strength": "required", "valueSet": vs}
    return d


def params(v):
    ps = [P("creatinine", "in", 1, "1", "decimal",
            "Serum creatinine, in mg/dL (0.2 to 20)." if v == 1 else
            "Serum creatinine, in the unit given by creatinineUnit (0.2 to 20 mg/dL after conversion).")]
    ps.append(P("age", "in", 1, "1", "integer" if v < 3 else "decimal", "Age in years (18 to 120)."))
    ps.append(P("sex", "in", 1, "1", "code", "Sex used by the equation: male or female.", SEXVS))
    if v >= 2:
        ps.append(P("creatinineUnit", "in", 1, "1", "code", "Unit of creatinine: mg/dL or umol/L.", UNITVS))
    ps.append(P("sampleDate", "in", 0, "1", "date", "Date the blood sample was taken; not in the future."))
    ps.append(P("egfr", "out", 1, "1", "decimal" if v < 4 else "Quantity",
                "Estimated GFR, mL/min/1.73 m2, rounded to 1 decimal."))
    ps.append(P("stage", "out", 1, "1", "code", "GFR category G1, G2, G3a, G3b, G4 or G5."))
    return ps


def opdef(v):
    return {"resourceType": "OperationDefinition", "url": "http://example.org/fhir/OperationDefinition/" + CODE,
            "version": str(v), "name": "CkdEpi2021Egfr", "title": "Estimated GFR by CKD-EPI 2021 (creatinine)",
            "status": "active", "kind": "operation", "code": CODE, "system": True, "type": False, "instance": False,
            "description": "Estimates glomerular filtration rate with the race-free CKD-EPI 2021 creatinine equation and assigns the GFR category.",
            "parameter": params(v)}


def statement(v):
    s = ["# Estimated GFR, CKD-EPI 2021 (creatinine) - version %d\n" % v,
         "System-level operation `$%s`, called by `POST /$%s`. It computes the race-free CKD-EPI 2021 creatinine equation and the GFR category.\n" % (CODE, CODE),
         "## Inputs\n"]
    if v == 1:
        s.append("- `creatinine` (decimal, 1..1): serum creatinine in mg/dL.")
    else:
        s.append("- `creatinine` (decimal, 1..1): serum creatinine, in the unit given by `creatinineUnit`.")
    s.append("- `age` (%s, 1..1): age in years." % ("integer" if v < 3 else "decimal, fractions of a year allowed, e.g. 54.5"))
    s.append("- `sex` (code, 1..1, required binding to %s): code system `http://hl7.org/fhir/administrative-gender`; the value set holds exactly two codes: `male`, `female` (lower case)." % SEXVS)
    if v >= 2:
        s.append("- `creatinineUnit` (code, 1..1, required binding to %s): code system `http://unitsofmeasure.org`; the value set holds exactly two codes: `mg/dL`, `umol/L`." % UNITVS)
    s.append("- `sampleDate` (date, 0..1, optional): date the sample was taken. It does not enter the computation.\n")
    s.append("## Rules (a request breaking one is answered 4xx)\n")
    if v == 1:
        s.append("1. `creatinine` must be from 0.2 to 20 mg/dL, both ends included.")
    else:
        s.append("1. `creatinine`, once converted to mg/dL (step 1 below), must be from 0.2 to 20 mg/dL, both ends included. (So in umol/L: 17.68 to 1768.)")
    s.append("2. `age` must be from 18 to 120 years, both ends included.")
    s.append("3. `sampleDate`, when given, must not be after the current date of the server.\n")
    s.append("## Computation\n")
    if v == 1:
        s.append("1. Scr = `creatinine` (mg/dL).")
    else:
        s.append("1. Scr = `creatinine` if `creatinineUnit` is `mg/dL`; Scr = `creatinine` / 88.4 if it is `umol/L`.")
    s += ["2. If `sex` is `female`: kappa = 0.7, alpha = -0.241, sexFactor = 1.012. If `male`: kappa = 0.9, alpha = -0.302, sexFactor = 1.",
          "3. egfr = 142 * min(Scr/kappa, 1)^alpha * max(Scr/kappa, 1)^(-1.200) * 0.9938^age * sexFactor (unrounded value used below).",
          "4. stage, from the unrounded egfr: `G1` if egfr >= 90; `G2` if 60 <= egfr < 90; `G3a` if 45 <= egfr < 60; `G3b` if 30 <= egfr < 45; `G4` if 15 <= egfr < 30; `G5` if egfr < 15.",
          "5. Round egfr to 1 decimal for the output.\n", "## Outputs (always both)\n"]
    if v < 4:
        s.append("- `egfr` (decimal): eGFR in mL/min/1.73 m2, rounded to 1 decimal (`valueDecimal`).")
    else:
        s.append("- `egfr` (Quantity, `valueQuantity`): `value` = eGFR rounded to 1 decimal, `system` = `http://unitsofmeasure.org`, `code` = `mL/min/{1.73_m2}` (`unit` \"mL/min/1.73 m2\").")
    s.append("- `stage` (code, `valueCode`): one of `G1`, `G2`, `G3a`, `G3b`, `G4`, `G5` as in step 4.")
    return "\n".join(s) + "\n"


CHANGES = {
    2: "# Changes in v2\n\n- New REQUIRED input `creatinineUnit` (code, `mg/dL` or `umol/L`). `creatinine` is now read in that unit; umol/L values are divided by 88.4 before the equation.\n- The 0.2-20 range rule applies to creatinine after conversion to mg/dL.\n",
    3: "# Changes in v3\n\n- Input `age` changes type from integer to decimal; fractions of a year are used in the equation as given.\n- The range 18-120 is unchanged.\n",
    4: "# Changes in v4\n\n- Output `egfr` changes type from decimal to Quantity (mL/min/1.73 m2, UCUM `mL/min/{1.73_m2}`), still rounded to 1 decimal.\n- Output `stage` is unchanged.\n"}

# ---------- cases ----------
CONF = [(0.6, 30, "female", "2023-05-17"), (0.8, 25, "male", None), (1.0, 50, "male", None), (1.1, 45, "female", "2024-11-02"),
        (1.3, 60, "male", None), (1.8, 70, "male", "2022-01-31"), (2.1, 55, "female", None), (2.2, 65, "male", None),
        (2.7, 72, "female", "2021-07-09"), (5.5, 58, "male", None), (7.8, 80, "female", None), (12.0, 40, "male", "2020-02-29"),
        (0.9, 18, "male", None), (0.7, 120, "female", None), (1.2, 66, "female", None), (0.5, 35, "female", "2025-03-03"),
        (1.5, 52, "female", None), (2.0, 77, "male", None), (1.0, 90, "female", "2019-12-31"), (19.5, 64, "male", None),
        (0.3, 29, "male", None), (1.4, 41, "male", "2026-01-15")]
FRAC = [0.0, 0.5, 0.25, 0.75]


def build(v):
    cases = []
    agekey = "valueInteger" if v < 3 else "valueDecimal"

    def base(cr, age, sex, date, unit="mg/dL"):
        L = [("creatinine", "valueDecimal", cr), ("age", agekey, age), ("sex", "valueCode", sex)]
        if v >= 2:
            L.append(("creatinineUnit", "valueCode", unit))
        if date:
            L.append(("sampleDate", "valueDate", date))
        return L

    def mk(about, L, expect, change=False):
        cases.append({"about": about, "change": change,
                      "request": {"resourceType": "Parameters",
                                  "parameter": [{"name": n, k: x} for (n, k, x) in L]},
                      "expect": expect})

    def ok(about, cr_mg, age, sex, date, unit="mg/dL"):
        cr = cr_mg
        if unit == "umol/L":
            cr = float(round(cr_mg * 88.4))
        if v >= 3:
            age = float(age)
        scr = cr / 88.4 if unit == "umol/L" else cr
        e = egfr(scr, age, sex)
        for t in (15, 30, 45, 60, 90):
            assert abs(e - t) > 1, (about, e)
        val = round(e, 1)
        out = {"name": "egfr", "type": "valueDecimal", "value": val, "tolerance": 0.05}
        if v == 4:
            out = {"name": "egfr", "type": "valueQuantity", "value": dict(value=val, **QUNIT), "tolerance": 0.05}
        mk(about, base(cr, age, sex, date, unit),
           {"status": 200, "outputs": [out, {"name": "stage", "type": "valueCode", "value": stage(e), "tolerance": 0}]},
           change=(v in (3, 4)) or (v == 2 and unit == "umol/L"))

    for i, (cr, age, sex, date) in enumerate(CONF):
        unit = "mg/dL"
        if v >= 2 and (i % 2 == 1 or i in (4, 12)):
            unit = "umol/L"
        a = age
        if v >= 3 and age not in (18, 120):
            a = age + FRAC[i % 4]
        ok("%s, age %s, %s, %s" % (sex, a, unit, stage(egfr(cr, a, sex))), cr, a, sex, date, unit)

    def bad(about, L, change=False):
        mk(about, L, {"status": "4xx"}, change and v == 2)

    ageok = 50.5 if v >= 3 else 50
    d = base(1.0, ageok, "male", None)

    def drop(n):
        return [x for x in d if x[0] != n]

    def rep(n, key, val):
        return [(n, key, val) if x[0] == n else x for x in d]

    def dup(n, key, val):
        return d + [(n, key, val)]

    for n in ["creatinine", "age", "sex"] + (["creatinineUnit"] if v >= 2 else []):
        bad("missing " + n, drop(n), change=(n == "creatinineUnit"))
    dd = d + [("sampleDate", "valueDate", "2022-02-02")]
    bad("creatinine twice", dup("creatinine", "valueDecimal", 1.1))
    bad("age twice", dup("age", agekey, ageok))
    bad("sex twice", dup("sex", "valueCode", "male"))
    bad("sampleDate twice", dd + [("sampleDate", "valueDate", "2022-02-03")])
    if v >= 2:
        bad("unit twice", dup("creatinineUnit", "valueCode", "mg/dL"), change=True)
    bad("creatinine as string", rep("creatinine", "valueString", "1.0"))
    bad("age as string", rep("age", "valueString", "50"))
    bad("sex as string", rep("sex", "valueString", "male"))
    bad("date as string", d + [("sampleDate", "valueString", "2022-02-02")])
    bad("sex outside binding", rep("sex", "valueCode", "other"))
    bad("sex wrong case", rep("sex", "valueCode", "Female"))
    if v >= 2:
        bad("unit as string", rep("creatinineUnit", "valueString", "mg/dL"), change=True)
        bad("unit outside binding", rep("creatinineUnit", "valueCode", "mmol/L"), change=True)
        bad("unit wrong case", rep("creatinineUnit", "valueCode", "umol/l"), change=True)
        lo = [(n, k, 10.0 if n == "creatinine" else ("umol/L" if n == "creatinineUnit" else x)) for (n, k, x) in d]
        hi = [(n, k, 2000.0 if n == "creatinine" else ("umol/L" if n == "creatinineUnit" else x)) for (n, k, x) in d]
        bad("umol/L below range", lo, change=True)
        bad("umol/L above range", hi, change=True)
        bad("umol-sized value given as mg/dL", rep("creatinine", "valueDecimal", 88.4))
    bad("creatinine too low", rep("creatinine", "valueDecimal", 0.1))
    bad("creatinine too high", rep("creatinine", "valueDecimal", 25.0))
    bad("age under 18", rep("age", agekey, 17.9 if v >= 3 else 17))
    bad("age over 120", rep("age", agekey, 120.5 if v >= 3 else 121))
    bad("sampleDate in future", d + [("sampleDate", "valueDate", "2999-12-31")])
    random.Random(v).shuffle(cases)
    out = []
    for i, c in enumerate(cases):
        c2 = {"id": "c%02d" % (i + 1)}
        c2.update(c)
        out.append(c2)
    return out


for v in (1, 2, 3, 4):
    dr = os.path.join(HERE, "v%d" % v)
    os.makedirs(dr, exist_ok=True)
    json.dump(opdef(v), open(dr + "/OperationDefinition.json", "w"), indent=2)
    open(dr + "/STATEMENT.md", "w").write(statement(v))
    if v > 1:
        open(dr + "/CHANGE.md", "w").write(CHANGES[v])
    cs = build(v)
    json.dump(cs, open(dr + "/cases.json", "w"), indent=1)
    assert all(c["request"]["resourceType"] == "Parameters" for c in cs)
    print(v, len(cs), sum(1 for c in cs if c["expect"]["status"] == 200), sum(c["change"] for c in cs))
