import json, os, random, math
from decimal import Decimal, ROUND_HALF_UP
D = os.path.dirname(os.path.abspath(__file__))
TODAY = "2026-11-22"
CODE = "qtc"
FS = "http://example.org/fhir/CodeSystem/qtc-formula"
FVS = "http://example.org/fhir/ValueSet/qtc-formula"
SS = "http://hl7.org/fhir/administrative-gender"
SVS = "http://example.org/fhir/ValueSet/qtc-sex"
KEY = {"decimal": "valueDecimal", "integer": "valueInteger", "code": "valueCode", "date": "valueDate",
       "boolean": "valueBoolean", "string": "valueString"}
FORMULAS = {1: ["bazett", "fridericia", "framingham", "hodges"]}
FORMULAS[2] = FORMULAS[1]
FORMULAS[3] = ["bazett", "fridericia"]
FORMULAS[4] = FORMULAS[3]
FDOC = {"bazett": "QTc = QT / sqrt(RR)", "fridericia": "QTc = QT / RR^(1/3)",
        "framingham": "QTc = QT + 154 * (1 - RR)", "hodges": "QTc = QT + 1.75 * (heart-rate - 60)"}
TYPES = {"qt-ms": "decimal", "heart-rate": "integer", "formula": "code", "sex": "code", "ecg-date": "date",
         "qrs-ms": "integer"}


def inputs(v):
    L = [("qt-ms", "decimal", 1, "Measured QT interval, in milliseconds (ms)."),
         ("heart-rate", "integer", 1, "Heart rate at the time of the recording, in beats per minute."),
         ("formula", "code", 1, "Rate-correction formula to apply."),
         ("sex", "code", 0, "Sex of the patient; selects the prolongation threshold. If left out, the higher (female) threshold is used."),
         ("ecg-date", "date", 0, "Date the ECG was recorded; checked only, it does not enter the computation.")]
    if v >= 2:
        L.insert(2, ("qrs-ms", "integer", 1, "QRS duration, in milliseconds (ms)."))
    return L


def outputs(v):
    if v < 4:
        return [("qtc", "decimal", "Rate-corrected QT interval in ms, 1 decimal."),
                ("prolonged", "boolean", "True when QTc exceeds the sex-specific threshold.")]
    return [("qtc", "decimal", "Rate-corrected QT interval in ms, 1 decimal."),
            ("qtc-prolonged", "boolean", "True when QTc exceeds the sex-specific threshold."),
            ("rr-seconds", "decimal", "RR interval in seconds, 3 decimals.")]


def rnd(x, n):
    return float(Decimal(repr(x)).quantize(Decimal(1).scaleb(-n), rounding=ROUND_HALF_UP))


def evaluate(v, params):
    by = {}
    for p in params:
        k = [k for k in p if k != "name"][0]
        by.setdefault(p["name"], []).append((k, p[k]))
    vals = {}
    for name, typ, mn, _ in inputs(v):
        got = by.get(name, [])
        if len(got) < mn or len(got) > 1:
            return 400, None
        if got:
            k, val = got[0]
            if k != KEY[typ]:
                return 400, None
            vals[name] = val
    if vals["formula"] not in FORMULAS[v]:
        return 400, None
    if "sex" in vals and vals["sex"] not in ("male", "female"):
        return 400, None
    qt, hr = vals["qt-ms"], vals["heart-rate"]
    if not (200 <= qt <= 800) or not (30 <= hr <= 250):
        return 400, None
    if "ecg-date" in vals and vals["ecg-date"] > TODAY:
        return 400, None
    rr = 60.0 / hr
    if qt >= rr * 1000:
        return 400, None
    qta = qt
    if v >= 2:
        q = vals["qrs-ms"]
        if not (40 <= q <= 300) or q >= qt:
            return 400, None
        if q >= 120:
            qta = qt - (q - 100)
    f = vals["formula"]
    if f == "bazett":
        qtc = qta / math.sqrt(rr)
    elif f == "fridericia":
        qtc = qta / rr ** (1 / 3)
    elif f == "framingham":
        qtc = qta + 154 * (1 - rr)
    else:
        qtc = qta + 1.75 * (hr - 60)
    thr = 450 if vals.get("sex") == "male" else 460
    out = [{"name": "qtc", "type": "valueDecimal", "value": rnd(qtc, 1), "tolerance": 0.05}]
    out.append({"name": "prolonged" if v < 4 else "qtc-prolonged", "type": "valueBoolean", "value": qtc > thr})
    if v >= 4:
        out.append({"name": "rr-seconds", "type": "valueDecimal", "value": rnd(rr, 3), "tolerance": 0.0005})
    return 200, (out, qtc, thr)


def P(name, val, typ=None):
    t = typ or TYPES[name]
    return {"name": name, KEY[t]: val}


def req(plist):
    return {"resourceType": "Parameters", "parameter": plist}


def mk(v, qt, hr, f, sex=None, date=None, qrs=90):
    L = [P("qt-ms", float(qt)), P("heart-rate", hr), P("formula", f)]
    if v >= 2:
        L.append(P("qrs-ms", qrs))
    if sex:
        L.append(P("sex", sex))
    if date:
        L.append(P("ecg-date", date))
    return L


def conform_cases(v, n):
    rng = random.Random(100 + v)
    out = []

    def add(about, L):
        st, r = evaluate(v, L)
        assert st == 200, (about, L)
        _, qtc, thr = r
        if abs(qtc - thr) < 3:
            return False
        out.append((about, L))
        return True
    for rep in range(4):
     for f in FORMULAS[v]:
        for sex in ("male", "female", None):
            for wide in ((False, True) if v >= 2 else (False,)):
                for _ in range(80):
                    qt = rng.choice(range(340, 520, 5))
                    hr = rng.choice(range(48, 121, 4))
                    qrs = rng.choice(range(130, 175, 5)) if wide else rng.choice(range(70, 112, 4))
                    date = rng.choice([None, "2023-03-09", "2026-11-22"])
                    if qt >= 60000 / hr or qrs >= qt:
                        continue
                    about = f + ", sex " + (sex or "omitted")
                    if v >= 2:
                        about += ", wide QRS" if wide else ", narrow QRS"
                    if date:
                        about += ", date " + date
                    if add(about, mk(v, qt, hr, f, sex, date, qrs)):
                        break
    extra = []
    if v >= 2:
        extra += [("QRS exactly 120 (adjusted)", mk(v, 430, 70, "bazett", "male", None, 120)),
                  ("QRS 119 (not adjusted)", mk(v, 430, 70, "bazett", "male", None, 119)),
                  ("QRS 120 fridericia", mk(v, 420, 60, "fridericia", "female", None, 120)),
                  ("QRS 300 near QT", mk(v, 520, 60, "bazett", "female", None, 300)),
                  ("QRS minimum 40", mk(v, 400, 75, "fridericia", None, None, 40))]
    extra += [("QT 200 minimum", mk(v, 200, 75, "bazett", "female", None, 90)),
              ("QT 800 maximum slow HR", mk(v, 800, 30, "fridericia", "male", None, 100)),
              ("HR 250 fast", mk(v, 220, 250, "bazett", None, None, 90)),
              ("HR 30 slow", mk(v, 420, 30, "fridericia", "female", None, 90)),
              ("date today", mk(v, 410, 65, "bazett", "male", "2026-11-22", 90)),
              ("fractional QT", mk(v, 417.5, 72, "fridericia", "female", "2022-01-01", 88))]
    if v <= 2:
        extra += [("hodges HR 60", mk(v, 470, 60, "hodges", "male", None, 90)),
                  ("framingham HR 60", mk(v, 400, 60, "framingham", "female", None, 90))]
    for a, L in extra:
        if not add(a, L):
            print("near threshold", v, a)
    rng.shuffle(out)
    return out[:n]


def bad_cases(v):
    base = mk(v, 400, 70, "bazett", "male", None, 90)

    def rem(n):
        return [p for p in base if p["name"] != n]

    def setv(n, val):
        return [P(n, val) if p["name"] == n else p for p in base]

    def retype(n, key, val):
        return [({"name": n, key: val} if p["name"] == n else p) for p in base]
    B = [("missing qt-ms", rem("qt-ms")), ("missing heart-rate", rem("heart-rate")),
         ("missing formula", rem("formula"))]
    if v >= 2:
        B += [("missing qrs-ms", rem("qrs-ms")),
              ("qrs-ms as string", retype("qrs-ms", "valueString", "90")),
              ("qrs-ms 39 below range", setv("qrs-ms", 39)),
              ("qrs-ms 301 above range", setv("qrs-ms", 301)),
              ("qrs-ms equals qt-ms", mk(v, 250, 70, "bazett", "male", None, 250)),
              ("qrs-ms exceeds qt-ms", mk(v, 250, 70, "bazett", None, None, 280)),
              ("qrs-ms given twice", base + [P("qrs-ms", 95)])]
    B += [("qt-ms given twice", base + [P("qt-ms", 410.0)]),
          ("heart-rate given twice", base + [P("heart-rate", 80)]),
          ("sex given twice", base + [P("sex", "female")]),
          ("formula given twice", base + [P("formula", "fridericia")]),
          ("qt-ms as string", retype("qt-ms", "valueString", "400")),
          ("heart-rate under decimal key", retype("heart-rate", "valueDecimal", 70.5)),
          ("formula as string", retype("formula", "valueString", "bazett")),
          ("sex as string", retype("sex", "valueString", "male")),
          ("ecg-date as string", base + [P("ecg-date", "2023-03-09", "string")]),
          ("qt-ms as integer key", retype("qt-ms", "valueInteger", 400)),
          ("formula unknown code", setv("formula", "rautaharju")),
          ("sex unknown code", setv("sex", "other")),
          ("sex wrong case", setv("sex", "Male")),
          ("qt-ms 199.9 below range", setv("qt-ms", 199.9)),
          ("qt-ms 800.5 above range", setv("qt-ms", 800.5)),
          ("heart-rate 29", setv("heart-rate", 29)),
          ("heart-rate 251", setv("heart-rate", 251)),
          ("ecg-date in future", base + [P("ecg-date", "2099-12-31")]),
          ("ecg-date tomorrow", base + [P("ecg-date", "2026-11-23")]),
          ("qt-ms above RR", mk(v, 420, 150, "bazett", "female", None, 90)),
          ("qt-ms equals RR", mk(v, 400, 150, "fridericia", None, None, 90))]
    if v >= 3:
        for f, qt, hr, sex in [("framingham", 400, 70, "male"), ("hodges", 420, 80, "female"),
                               ("framingham", 450, 55, None), ("hodges", 390, 65, "male"),
                               ("framingham", 380, 90, "female"), ("hodges", 440, 50, None),
                               ("framingham", 410, 60, "male"), ("hodges", 360, 100, "female"),
                               ("framingham", 430, 75, None), ("hodges", 405, 72, "male"),
                               ("framingham", 395, 85, "female"), ("hodges", 470, 58, "male")]:
            B.append((f + " no longer bound", mk(v, qt, hr, f, sex, None, 90)))
    return B


def build(v):
    bad = bad_cases(v)
    n = 0
    if v == 4:
        nb = [b for b in bad if b[0].endswith("no longer bound")][:3]
        bad = [b for b in bad if not b[0].endswith("no longer bound")] + nb
    n = round(1.5 * len(bad))
    conf = conform_cases(v, n)
    items = []
    for a, L in conf:
        st, r = evaluate(v, L)
        items.append((a, L, 200, r[0]))
    for a, L in bad:
        st, _ = evaluate(v, L)
        assert st == 400, (v, a)
        items.append((a, L, 400, None))
    random.Random(7 * v).shuffle(items)
    cases = []
    for i, (a, L, st, o) in enumerate(items, 1):
        ch = False
        if v > 1:
            ps, po = evaluate(v - 1, L)
            if ps != st:
                ch = True
            elif st == 200:
                ch = po[0] != o
        e = {"status": 200, "outputs": o} if st == 200 else {"status": "4xx"}
        cases.append({"id": "c%02d" % i, "about": a, "change": ch, "request": req(L), "expect": e})
    return cases


def opdef(v):
    params = []
    for n, t, mn, doc in inputs(v):
        p = {"name": n, "use": "in", "min": mn, "max": "1", "documentation": doc, "type": t}
        if n == "formula":
            p["binding"] = {"strength": "required", "valueSet": FVS}
        if n == "sex":
            p["binding"] = {"strength": "required", "valueSet": SVS}
        params.append(p)
    for n, t, doc in outputs(v):
        params.append({"name": n, "use": "out", "min": 1, "max": "1", "documentation": doc, "type": t})
    return {"resourceType": "OperationDefinition",
            "url": "http://example.org/fhir/OperationDefinition/qtc",
            "version": "%d.0.0" % v, "name": "CorrectedQtInterval",
            "title": "Rate-corrected QT interval (QTc)", "status": "active",
            "kind": "operation", "code": CODE, "system": True, "type": False, "instance": False,
            "description": "Computes the heart-rate-corrected QT interval from an ECG and whether it is prolonged.",
            "parameter": params}


def statement(v):
    s = ["# QTc operation, version %d\n" % v,
         "Operation `$%s`, system level: `POST /$%s` with a Parameters resource. Every parameter is given at most once.\n" % (CODE, CODE),
         "## Inputs\n"]
    for n, t, mn, doc in inputs(v):
        s.append("- `%s` (%s, %s): %s" % (n, t, "required" if mn else "optional", doc))
    s.append("\n## Bound codes\n")
    s.append("`formula` is bound (required) to value set %s, code system %s. The value set holds exactly these codes:" % (FVS, FS))
    for f in FORMULAS[v]:
        s.append("- `%s`: %s" % (f, FDOC[f]))
    s.append("\n`sex` is bound (required) to value set %s, code system %s. The value set holds exactly: `male`, `female`. Codes are case-sensitive.\n" % (SVS, SS))
    s.append("## Rules (a request breaking one is rejected with a 4xx status)\n")
    r = ["`qt-ms` is from 200 to 800 inclusive.", "`heart-rate` is from 30 to 250 inclusive.",
         "`ecg-date`, if given, is not after today's date (UTC).",
         "`qt-ms` is less than the RR interval in ms, i.e. `qt-ms` < 60000 / `heart-rate`."]
    if v >= 2:
        r += ["`qrs-ms` is from 40 to 300 inclusive.", "`qrs-ms` is less than `qt-ms`."]
    for x in r:
        s.append("- " + x)
    s.append("\n## Computation\n")
    k = 1
    s.append("%d. RR = 60 / `heart-rate` (seconds)." % k)
    k += 1
    if v >= 2:
        s.append("%d. Adjusted QT, QTa: if `qrs-ms` >= 120 then QTa = `qt-ms` - (`qrs-ms` - 100); otherwise QTa = `qt-ms`. (A QRS of exactly 120 is adjusted.)" % k)
        k += 1
        q, nm = "QTa", "QTa"
    else:
        q, nm = "QT (= `qt-ms`)", "QT"
    s.append("%d. QTc by `formula`, using %s in ms, RR in seconds and heart-rate in bpm, without intermediate rounding:" % (k, q))
    k += 1
    for f in FORMULAS[v]:
        s.append("   - `%s`: %s" % (f, FDOC[f].replace("QT ", nm + " ")))
    s.append("%d. Threshold: 450 ms if `sex` is `male`; 460 ms if `sex` is `female` or not given." % k)
    k += 1
    pn = "prolonged" if v < 4 else "qtc-prolonged"
    s.append("%d. `%s` is true when the unrounded QTc is strictly greater than the threshold, else false." % (k, pn))
    k += 1
    s.append("%d. Round outputs as stated below (half up).\n" % k)
    s.append("## Outputs (all always present)\n")
    s.append("- `qtc` (decimal, ms): QTc rounded to 1 decimal.")
    s.append("- `%s` (boolean)." % pn)
    if v >= 4:
        s.append("- `rr-seconds` (decimal, seconds): RR from step 1 rounded to 3 decimals.")
    return "\n".join(s) + "\n"


CHANGE = {2: "New required input `qrs-ms` (integer, ms, 40 to 300, must be less than `qt-ms`). A QRS of 120 ms or more now shortens the QT before correction: QTa = QT - (QRS - 100). Requests without `qrs-ms` are rejected.",
          3: "Input `formula` is bound to fewer codes: `framingham` and `hodges` are removed; only `bazett` and `fridericia` are accepted. Requests using the removed codes are rejected.",
          4: "Output `prolonged` is renamed `qtc-prolonged`, and a new output `rr-seconds` (decimal, seconds, 3 decimals) is added. `qtc` is unchanged."}

for v in (1, 2, 3, 4):
    d = os.path.join(D, "v%d" % v)
    os.makedirs(d, exist_ok=True)
    json.dump(opdef(v), open(d + "/OperationDefinition.json", "w"), indent=2)
    open(d + "/STATEMENT.md", "w").write(statement(v))
    if v > 1:
        open(d + "/CHANGE.md", "w").write("# Version %d\n\n%s\n" % (v, CHANGE[v]))
    c = build(v)
    json.dump(c, open(d + "/cases.json", "w"), indent=1)
    c2 = json.load(open(d + "/cases.json"))
    assert all(x["request"]["resourceType"] == "Parameters" for x in c2)
    ok = sum(1 for x in c2 if x["expect"]["status"] == 200)
    print(v, len(c2), "conform", ok, "change", sum(x["change"] for x in c2))
