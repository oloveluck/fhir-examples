import json, os, random
HERE = os.path.dirname(os.path.abspath(__file__))
UC = "http://unitsofmeasure.org"
METH = ["standard", "with-potassium"]
LOW = {"standard": 6, "with-potassium": 10}
HIGH = {"standard": 12, "with-potassium": 16}
MGDL = 9.008


def occ(ps, n):
    return [p for p in ps if p["name"] == n]


def ev(v, ps):
    """returns (status, outputs list of (name,type,value))"""
    req = ["sodium", "chloride", "bicarbonate", "method"] + (["lactate"] if v >= 2 else [])
    names = req + ["potassium", "albumin"]
    d = {}
    for n in names:
        o = occ(ps, n)
        if len(o) > 1:
            return 400, None
        if n in req and not o:
            return 400, None
        if o:
            d[n] = o[0]
    for n, p in d.items():
        want = "valueCode" if n == "method" else ("valueQuantity" if (n == "lactate" and v >= 3) else "valueDecimal")
        if p["key"] != want:
            return 400, None
    num = {k: d[k]["value"] for k in d if k not in ("method", "lactate")}
    m = d["method"]["value"]
    if m not in METH:
        return 400, None
    rng = dict(sodium=(100, 180), chloride=(60, 140), bicarbonate=(2, 60), potassium=(1.0, 10.0), albumin=(0.5, 6.0))
    for k, x in num.items():
        if not rng[k][0] <= x <= rng[k][1]:
            return 400, None
    if num["sodium"] <= num["chloride"]:
        return 400, None
    if m == "with-potassium" and "potassium" not in num:
        return 400, None
    lac = 0.0
    if v >= 2:
        L = d["lactate"]["value"]
        if v >= 3:
            if L.get("system") != UC or L.get("code") not in ("mmol/L", "mg/dL"):
                return 400, None
            lac = L["value"] / (MGDL if L["code"] == "mg/dL" else 1)
        else:
            lac = L
        if not 0 <= lac <= 30:
            return 400, None
    ag = num["sodium"] - num["chloride"] - num["bicarbonate"] + (num["potassium"] if m == "with-potassium" else 0)
    corr = ag + 2.5 * (4.4 - num["albumin"]) if "albumin" in num else None
    base = ag if corr is None else corr
    used = base - lac
    cat = "low" if used < LOW[m] else ("high" if used > HIGH[m] else "normal")
    out = [("anion-gap", "valueDecimal", round(ag, 1))]
    if corr is not None:
        out.append(("corrected-anion-gap", "valueDecimal", round(corr, 1)))
    if v >= 4:
        out.append(("adjusted-gap", "valueDecimal", round(used, 1)))
    out.append(("gap-category" if v >= 4 else "category", "valueCode", cat))
    ev.last = (ag, corr, used, m)
    return 200, out


def P(name, key, value):
    return dict(name=name, key=key, value=value)


def Q(x, code="mmol/L"):
    return dict(value=x, unit=code, system=UC, code=code)


def build(v, o):
    ps = []

    def add(n, val):
        if val is None:
            return
        vals = val if isinstance(val, list) else [val]
        for x in vals:
            if isinstance(x, tuple) and x[0] == "key":
                ps.append(P(n, x[1], x[2]))
            elif n == "method":
                ps.append(P(n, "valueCode", x))
            elif n == "lactate":
                if isinstance(x, tuple) and x[0] == "mgdl":
                    ps.append(P(n, "valueQuantity", Q(x[1], "mg/dL")))
                elif v >= 3:
                    ps.append(P(n, "valueQuantity", Q(x)))
                else:
                    ps.append(P(n, "valueDecimal", x))
            else:
                ps.append(P(n, "valueDecimal", x))
    for n in ["sodium", "chloride", "bicarbonate", "method", "potassium", "albumin"] + (["lactate"] if v >= 2 else []):
        if n in o:
            add(n, o[n])
    return ps


def G(na, cl, hc, m="standard", k=None, alb=None, lac=1.0):
    d = dict(sodium=na, chloride=cl, bicarbonate=hc, method=m, potassium=k, albumin=alb, lactate=lac)
    return {x: y for x, y in d.items() if y is not None}


def B(base, **ch):
    d = dict(base)
    d.update(ch)
    return {k: x for k, x in d.items() if x is not None}


def goods(v):
    g = [
        ("std, high, no albumin", G(140, 100, 24, lac=1.0)),
        ("std, normal gap", G(140, 104, 26, lac=1.0)),
        ("std, low gap", G(138, 106, 28, lac=0.5)),
        ("std, lactate shifts to normal", G(140, 100, 24, lac=8.0)),
        ("std, lactate shifts high to normal", G(135, 100, 20, lac=4.0)),
        ("with-K, normal", G(140, 104, 25, "with-potassium", 4.0, lac=1.0)),
        ("with-K, high", G(140, 100, 24, "with-potassium", 5.0, lac=2.0)),
        ("with-K, low", G(138, 106, 26, "with-potassium", 3.5, lac=0.5)),
        ("with-K, lactate shifts to normal", G(140, 100, 24, "with-potassium", 5.0, lac=8.0)),
        ("std, low albumin raises gap", G(140, 100, 24, alb=2.0, lac=2.0)),
        ("std, albumin lifts low to normal", G(138, 108, 26, alb=2.0, lac=1.0)),
        ("std, albumin 4.4 no change", G(140, 104, 22, alb=4.4, lac=1.0)),
        ("std, albumin above 4.4", G(140, 100, 30, alb=5.0, lac=1.0)),
        ("with-K, albumin 2.6", G(140, 102, 24, "with-potassium", 4.5, 2.6, lac=3.0)),
        ("with-K, albumin 3.0 normal", G(136, 104, 24, "with-potassium", 4.0, 3.0, lac=2.0)),
        ("with-K, albumin lactate to normal", G(135, 105, 26, "with-potassium", 4.0, 1.0, lac=3.0)),
        ("std, decimal inputs", G(141.5, 101.3, 23.4, lac=1.2)),
        ("std, decimal albumin", G(139.2, 103.6, 25.1, alb=3.6, lac=2.0)),
        ("std, potassium given but ignored", G(140, 104, 26, "standard", 4.0, lac=1.0)),
        ("std, lactate zero", G(140, 102, 24, lac=0.0)),
        ("min sodium bound", G(100, 70, 10, lac=1.0)),
        ("max sodium bound", G(180, 130, 40, lac=1.0)),
        ("max potassium bound", G(140, 100, 30, "with-potassium", 10.0, lac=2.0)),
        ("albumin 0.6 low", G(140, 104, 28, alb=0.6, lac=5.0)),
    ]
    if v == 2:
        g += [("std, lactate 2.5", G(140, 100, 24, lac=2.5)),
              ("with-K, lactate 10", G(140, 100, 24, "with-potassium", 5.0, lac=10.0)),
              ("std albumin, lactate 3", G(140, 100, 24, alb=2.0, lac=3.0)),
              ("std low, lactate 1", G(138, 106, 28, lac=1.0)),
              ("max lactate bound", G(140, 100, 24, lac=30.0))]
    if v >= 3:
        g += [("max lactate bound", G(140, 100, 24, lac=30.0)),
              ("lactate mg/dL std", G(140, 100, 24, lac=("mgdl", 45.0))),
              ("lactate mg/dL with-K", G(140, 100, 24, "with-potassium", 5.0, lac=("mgdl", 90.0))),
              ("lactate mg/dL albumin", G(140, 100, 24, alb=2.0, lac=("mgdl", 27.0))),
              ("lactate mg/dL low", G(138, 106, 28, lac=("mgdl", 9.0)))]
    return g


def bads(v):
    b0 = G(140, 100, 24, lac=1.0)
    bk = G(140, 104, 25, "with-potassium", 4.0, lac=1.0)
    b = [
        ("sodium missing", B(b0, sodium=None)),
        ("chloride missing", B(b0, chloride=None)),
        ("bicarbonate missing", B(b0, bicarbonate=None)),
        ("method missing", B(b0, method=None)),
        ("sodium given twice", B(b0, sodium=[140, 141])),
        ("albumin given twice", B(b0, albumin=[3.0, 3.5])),
        ("sodium as string", B(b0, sodium=("key", "valueString", "140"))),
        ("chloride as string", B(b0, chloride=("key", "valueString", "100"))),
        ("method as string", B(b0, method=("key", "valueString", "standard"))),
        ("albumin as boolean", B(b0, albumin=("key", "valueBoolean", True))),
        ("method outside binding", B(b0, method="calculated")),
        ("method outside binding 2", B(b0, method="potassium")),
        ("sodium too high", B(b0, sodium=190)),
        ("chloride too low", B(b0, chloride=50)),
        ("bicarbonate too high", B(b0, bicarbonate=70)),
        ("with-K without potassium", B(b0, method="with-potassium")),
        ("potassium too high", B(bk, potassium=12.0)),
        ("albumin too high", B(b0, albumin=7.0)),
        ("albumin too low", B(b0, albumin=0.2)),
        ("sodium not above chloride", B(b0, sodium=100, chloride=105, bicarbonate=20)),
        ("sodium equal to chloride", B(b0, sodium=110, chloride=110, bicarbonate=20)),
    ]
    if v >= 2:
        b += [("lactate missing", B(b0, lactate=None)),
              ("lactate negative", B(b0, lactate=-1.0)),
              ("lactate as string", B(b0, lactate=("key", "valueString", "1.0"))),
              ("lactate given twice", B(b0, lactate=[1.0, 2.0])),
              ("lactate too high", B(b0, lactate=35.0))]
    if v >= 3:
        b += [("lactate as decimal", B(b0, lactate=("key", "valueDecimal", 1.0))),
              ("lactate unit outside list", B(b0, lactate=("key", "valueQuantity", Q(1.0, "g/L")))),
              ("lactate mg/dL too high", B(b0, lactate=("mgdl", 400.0)))]
    drop = {1: ["method outside binding 2", "sodium equal to chloride", "albumin too low", "potassium too high", "chloride as string"], 2: ["method outside binding 2", "sodium equal to chloride", "albumin too low", "potassium too high", "bicarbonate too high", "chloride as string"],
            3: ["method outside binding 2", "sodium equal to chloride", "albumin too low", "potassium too high", "bicarbonate too high", "chloride as string", "albumin too high", "albumin given twice", "albumin as boolean"],
            4: ["method outside binding 2", "sodium equal to chloride", "albumin too low", "potassium too high", "bicarbonate too high", "chloride as string", "albumin too high", "albumin given twice", "albumin as boolean"]}[v]
    return [x for x in b if x[0] not in drop]


def make_cases(v):
    items = [(a, True, o) for a, o in goods(v)] + [(a, False, o) for a, o in bads(v)]
    random.Random(v * 7 + 1).shuffle(items)
    res = []
    for i, (about, ok, o) in enumerate(items, 1):
        ps = build(v, o)
        st, out = ev(v, ps)
        assert (st == 200) == ok, (v, about, st)
        if ok:
            ag, corr, used, m = ev.last
            for t in (LOW[m], HIGH[m]):
                assert abs(used - t) > 0.4, (v, about, used)
            for x in (ag, corr):
                if x is not None:
                    assert abs(abs(x * 10 - int(x * 10)) - 0.5) > 0.05, (v, about, x)
        change = False
        if v > 1:
            st0, out0 = ev(v - 1, ps)
            change = (st0 != st) or (st == 200 and out0 != out)
        if st == 200:
            outs = [dict(name=n, type=t, value=val, **({"tolerance": 0.05} if t == "valueDecimal" else {})) for n, t, val in out]
            expect = dict(status=200, outputs=outs)
        else:
            expect = dict(status="4xx")
        req = dict(resourceType="Parameters", parameter=[{"name": p["name"], p["key"]: p["value"]} for p in ps])
        res.append(dict(id="c%02d" % i, about=about, change=change, request=req, expect=expect))
    return res


CS = "http://example.org/fhir/CodeSystem/anion-gap-method"
VS = "http://example.org/fhir/ValueSet/anion-gap-method"


def inputs(v):
    I = [
        ("sodium", 1, "1", "decimal", "Serum sodium in mmol/L. Must be from 100 to 180."),
        ("chloride", 1, "1", "decimal", "Serum chloride in mmol/L. Must be from 60 to 140, and sodium must be greater than chloride."),
        ("bicarbonate", 1, "1", "decimal", "Serum bicarbonate in mmol/L. Must be from 2 to 60."),
        ("method", 1, "1", "code", "Gap method, a code of the value set " + VS + " (code system " + CS + "): standard or with-potassium."),
        ("potassium", 0, "1", "decimal", "Serum potassium in mmol/L, from 1.0 to 10.0. Required when method is with-potassium; ignored in the computation when method is standard."),
        ("albumin", 0, "1", "decimal", "Serum albumin in g/dL, from 0.5 to 6.0. When given, the gap is albumin-corrected."),
    ]
    if v == 2:
        I.append(("lactate", 1, "1", "decimal", "Blood lactate in mmol/L, from 0 to 30."))
    if v >= 3:
        I.append(("lactate", 1, "1", "Quantity", "Blood lactate as a Quantity with system http://unitsofmeasure.org and code mmol/L or mg/dL (no other code). Its value in mmol/L (mg/dL divided by 9.008) must be from 0 to 30."))
    return I


def outputs(v):
    O = [("anion-gap", 1, "1", "decimal", "Anion gap in mmol/L, 1 decimal."),
         ("corrected-anion-gap", 0, "1", "decimal", "Albumin-corrected anion gap in mmol/L, 1 decimal. Present only when albumin is given.")]
    if v >= 4:
        O.append(("adjusted-gap", 1, "1", "decimal", "Value the category is based on (corrected gap if present, else gap, minus lactate), in mmol/L, 1 decimal. Always present."))
    O.append(("gap-category" if v >= 4 else "category", 1, "1", "code", "low, normal or high. Always present."))
    return O


def opdef(v):
    params = []
    for use, L in (("in", inputs(v)), ("out", outputs(v))):
        for n, mn, mx, t, doc in L:
            p = dict(name=n, use=use, min=mn, max=mx, type=t, documentation=doc)
            if n == "method":
                p["binding"] = dict(strength="required", valueSet=VS)
            params.append(p)
    return dict(resourceType="OperationDefinition", url="http://example.org/fhir/OperationDefinition/anion-gap",
                name="AnionGap", title="Serum anion gap with albumin correction", status="active", kind="operation",
                code="anion-gap", system=True, type=False, instance=False,
                description="Calculates the serum anion gap, optionally albumin-corrected, and classifies it. Version %d." % v,
                parameter=params)


def statement(v):
    s = ["# Anion gap with albumin correction (version %d)\n" % v,
         "Operation code `anion-gap`, called at `POST /$anion-gap` with a Parameters resource. Every input may be given at most once.\n",
         "## Inputs\n"]
    for n, mn, mx, t, doc in inputs(v):
        s.append("- `%s` (%s, %s): %s" % (n, t, "required" if mn else "optional", doc))
    s += ["", "## Code system and value set\n",
          "`method` is bound (required) to value set `%s`, which holds exactly the codes of code system `%s`: `standard` and `with-potassium`. Codes are case-sensitive.\n" % (VS, CS),
          "## Rules\n",
          "A request that breaks any of these is rejected with a 4xx status and an OperationOutcome:",
          "- every required input is present; no input is given more than once; each input has its declared type;",
          "- `method` is one of the two codes;",
          "- sodium 100 to 180, chloride 60 to 140, bicarbonate 2 to 60, potassium (if given) 1.0 to 10.0, albumin (if given) 0.5 to 6.0, all inclusive;",
          "- sodium is greater than chloride (not equal);",
          "- if `method` is `with-potassium`, `potassium` is given."]
    if v == 2:
        s.append("- lactate is from 0 to 30 mmol/L inclusive.")
    if v >= 3:
        s.append("- lactate's code is `mmol/L` or `mg/dL` and its system is http://unitsofmeasure.org; lactate in mmol/L (value if mmol/L, value / 9.008 if mg/dL) is from 0 to 30 inclusive. A lactate given as a decimal is of another type and rejected.")
    s += ["", "## Computation\n",
          "1. gap = sodium - chloride - bicarbonate; if method is `with-potassium`, add potassium.",
          "2. If albumin is given: corrected = gap + 2.5 * (4.4 - albumin). Otherwise there is no corrected gap."]
    if v == 1:
        s.append("3. value = corrected if it exists, otherwise gap.")
    else:
        s.append("3. base = corrected if it exists, otherwise gap.")
        s.append("4. value = base - lactate (lactate in mmol/L%s)." % ("" if v == 2 else "; a mg/dL lactate is first divided by 9.008"))
    k = 4 if v == 1 else 5
    s += ["%d. Category from value (unrounded), by method: for `standard`, `low` if value < 6, `high` if value > 12, else `normal`; for `with-potassium`, `low` if value < 10, `high` if value > 16, else `normal`. (Thresholds themselves are `normal`.)" % k,
          "%d. Round the numeric outputs to 1 decimal (from the unrounded numbers)." % (k + 1),
          "", "## Outputs\n"]
    for n, mn, mx, t, doc in outputs(v):
        s.append("- `%s` (%s): %s" % (n, t, doc))
    s.append("\nAn answer is a Parameters resource holding exactly the outputs above (the optional one only as stated), each under its declared type key (`valueDecimal`, `valueCode`).")
    return "\n".join(s) + "\n"


CH = {2: "New required input `lactate` (decimal, mmol/L, 0 to 30). The category is now based on the gap minus lactate; `anion-gap` and `corrected-anion-gap` are unchanged. Requests without lactate are rejected.",
      3: "Input `lactate` changes type from decimal to Quantity (UCUM code `mmol/L` or `mg/dL`; mg/dL is divided by 9.008). A decimal lactate is rejected; any other code is rejected.",
      4: "Output `category` is renamed `gap-category`. New output `adjusted-gap` (decimal, 1 decimal): the value the category is based on (corrected gap if present, else gap, minus lactate in mmol/L)."}

for v in range(1, 5):
    d = os.path.join(HERE, "v%d" % v)
    os.makedirs(d, exist_ok=True)
    json.dump(opdef(v), open(d + "/OperationDefinition.json", "w"), indent=2)
    open(d + "/STATEMENT.md", "w").write(statement(v))
    if v > 1:
        open(d + "/CHANGE.md", "w").write("# Version %d\n\n%s\n" % (v, CH[v]))
    cs = make_cases(v)
    json.dump(cs, open(d + "/cases.json", "w"), indent=1)
    assert all(c["request"]["resourceType"] == "Parameters" for c in cs)
    print(v, len(cs), sum(c["expect"]["status"] == 200 for c in cs), sum(c["change"] for c in cs))
