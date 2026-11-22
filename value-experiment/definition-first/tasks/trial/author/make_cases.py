import json, os, random, math
UCUM = "http://unitsofmeasure.org"
ACT = {"sedentary": 1.2, "light": 1.375, "moderate": 1.55, "active": 1.725, "very-active": 1.9}
GOAL = {"maintain": 0, "lose": -500, "gain": 500}
SEX = ("male", "female")


def acts(v):
    return [a for a in ACT if not (v >= 3 and a == "very-active")]


def rnd(x, d=0):
    return math.floor(x * 10 ** d + 0.5) / 10 ** d


def cat(b):
    return "underweight" if b < 18.5 else "normal" if b < 25 else "overweight" if b < 30 else "obese"


def ref(v, req):
    """Reference implementation of version v. None = request refused."""
    P = {}
    for p in req["parameter"]:
        P.setdefault(p["name"], []).append(p)
    for n in ["weight", "height", "age", "sex"] + (["goal"] if v >= 2 else []):
        if n not in P:
            return None
    for l in P.values():
        if len(l) > 1:
            return None

    def get(n, key):
        if n not in P:
            return None
        p = P[n][0]
        if [k for k in p if k != "name"] != [key]:
            raise ValueError
        return p[key]
    try:
        w = get("weight", "valueDecimal")
        a = get("age", "valueInteger")
        h = get("height", "valueQuantity" if v >= 3 else "valueDecimal")
        s = get("sex", "valueCode")
        ac = get("activity", "valueCode")
        g = get("goal", "valueCode") if v >= 2 else None
    except ValueError:
        return None
    if v >= 3:
        if h.get("system") != UCUM or h.get("code") != "cm":
            return None
        h = h["value"]
    if s not in SEX:
        return None
    if ac is not None and ac not in acts(v):
        return None
    if v >= 2 and g not in GOAL:
        return None
    if not (20 <= w <= 400 and 100 <= h <= 230 and 18 <= a <= 100):
        return None
    bmi = w / (h / 100) ** 2
    if not (12 <= bmi <= 70):
        return None
    bmr = 10 * w + 6.25 * h - 5 * a + (5 if s == "male" else -161)
    en = bmr * ACT[ac or "sedentary"] + (GOAL[g] if v >= 2 else 0)
    o = {"bmr": ("valueDecimal", rnd(bmr), 0.5), "bmi": ("valueDecimal", rnd(bmi, 1), 0.05),
         "energy": ("valueDecimal", rnd(en), 0.5)}
    if v >= 4:
        o["category"] = ("valueCode", cat(bmi), None)
    return o


def build(v, w=70, h=175, a=30, s="male", ac=None, g="maintain"):
    hp = {"valueQuantity": {"value": h, "unit": "cm", "system": UCUM, "code": "cm"}} if v >= 3 else {"valueDecimal": h}
    P = [{"name": "weight", "valueDecimal": w}, {"name": "height", **hp},
         {"name": "age", "valueInteger": a}, {"name": "sex", "valueCode": s}]
    if ac:
        P.append({"name": "activity", "valueCode": ac})
    if v >= 2 and g:
        P.append({"name": "goal", "valueCode": g})
    return P


def R(P):
    return {"resourceType": "Parameters", "parameter": P}


def drop(P, n):
    return [p for p in P if p["name"] != n]


def setp(P, n, **kw):
    return [({"name": n, **kw} if p["name"] == n else p) for p in P]


def cases_for(v):
    out = []
    hand = [(70, 175, 30, "male", None, "maintain"), (60, 165, 25, "female", "sedentary", "lose"),
            (85.5, 180, 45, "male", "light", "gain"), (55.2, 160, 60, "female", "moderate", "maintain"),
            (95, 185, 35, "male", "active", "lose"), (48, 158, 22, "female", "active", "gain"),
            (110, 178, 50, "male", "moderate", "lose"), (45, 170, 19, "female", "light", "maintain"),
            (75, 170, 40, "male", "very-active" if v < 3 else "active", "gain"),
            (150, 165, 38, "female", None, "lose"), (52, 175, 100, "male", "sedentary", "maintain"),
            (20, 100, 18, "female", "light", "gain"), (80, 230, 64, "male", None, "lose"),
            (59, 170, 29, "female", "active" if v >= 3 else "very-active", "lose")]
    for t in hand:
        out.append(("valid %s %s" % (t[3], t[4]), R(build(v, *t))))
    rg = random.Random(v * 7 + 1)
    while len(out) < 30:
        w = round(rg.uniform(40, 130), 1)
        h = rg.randint(140, 200)
        a = rg.randint(18, 90)
        b = w / (h / 100) ** 2
        if any(abs(b - t) < 0.4 for t in (18.5, 25, 30)):
            continue
        out.append(("valid random", R(build(v, w, h, a, rg.choice(SEX), rg.choice(acts(v) + [None]),
                                            rg.choice(list(GOAL))))))
    B = build(v)
    BA = build(v, ac="light")
    F = []
    for n in ["weight", "height", "age", "sex"] + (["goal"] if v >= 2 else []):
        F.append(("missing " + n, drop(B, n)))
    F += [("weight twice", B + [{"name": "weight", "valueDecimal": 71}]),
          ("activity twice", BA + [{"name": "activity", "valueCode": "active"}]),
          ("sex twice", B + [{"name": "sex", "valueCode": "male"}]),
          ("weight as string", setp(B, "weight", valueString="70")),
          ("age as string", setp(B, "age", valueString="30")),
          ("sex as string", setp(B, "sex", valueString="male")),
          ("sex outside binding", setp(B, "sex", valueCode="other")),
          ("activity outside binding", build(v, ac="extreme")),
          ("age 17", build(v, a=17)), ("age 101", build(v, a=101)),
          ("weight 19", build(v, w=19, h=100)), ("height 99", build(v, w=40, h=99)),
          ("height 231", build(v, w=80, h=231)),
          ("bmi above 70", build(v, w=300, h=200)), ("bmi below 12", build(v, w=30, h=160))]
    if v >= 2:
        F.append(("goal outside binding", build(v, g="bulk")))
    if v >= 3:
        F += [("very-active no longer bound", build(v, ac="very-active")),
              ("height as decimal", setp(B, "height", valueDecimal=175)),
              ("height unit m", setp(B, "height", valueQuantity={"value": 1.75, "unit": "m", "system": UCUM, "code": "m"}))]
    else:
        F.append(("height as string", setp(B, "height", valueString="175")))
    for ab, P in F:
        out.append((ab, R(P)))
    return out


VS = {"sex": "http://example.org/fhir/ValueSet/energy-sex",
      "activity": "http://example.org/fhir/ValueSet/energy-activity",
      "goal": "http://example.org/fhir/ValueSet/energy-goal"}


def params(v):
    I = [("weight", 1, "1", "decimal", "Body weight in kg."),
         ("height", 1, "1", "Quantity" if v >= 3 else "decimal",
          "Standing height in cm" + (" as a UCUM Quantity (code cm)." if v >= 3 else ".")),
         ("age", 1, "1", "integer", "Age in whole years, 18 to 100."),
         ("sex", 1, "1", "code", "Sex used in the equation: male or female."),
         ("activity", 0, "1", "code", "Activity level: " + ", ".join(acts(v)) + ". Default sedentary.")]
    if v >= 2:
        I.append(("goal", 1, "1", "code", "Energy goal: maintain, lose or gain."))
    O = [("bmr", 1, "1", "decimal", "Basal metabolic rate, kcal/day, 0 decimals."),
         ("bmi", 1, "1", "decimal", "Body mass index, kg/m2, 1 decimal."),
         ("energy", 1, "1", "decimal", "Daily energy target, kcal/day, 0 decimals.")]
    if v >= 4:
        O.append(("category", 1, "1", "code", "BMI category: underweight, normal, overweight or obese."))
    return I, O


def opdef(v):
    I, O = params(v)
    ps = []
    for u, L in (("in", I), ("out", O)):
        for n, mn, mx, t, d in L:
            p = {"name": n, "use": u, "min": mn, "max": mx, "type": t, "documentation": d}
            if u == "in" and t == "code":
                p["binding"] = {"strength": "required", "valueSet": VS[n]}
            ps.append(p)
    return {"resourceType": "OperationDefinition",
            "url": "http://example.org/fhir/OperationDefinition/energy-needs",
            "version": "%d.0.0" % v, "name": "EnergyNeeds", "title": "Adult energy needs",
            "status": "active", "kind": "operation", "code": "energy-needs", "system": True,
            "type": False, "instance": False,
            "description": "Estimates basal metabolic rate (Mifflin-St Jeor), body mass index and daily energy need of an adult.",
            "parameter": ps}


def statement(v):
    s = "# energy-needs (version %d)\n\nCalled at `POST /$energy-needs`. Estimates, for an adult, the basal metabolic rate (Mifflin-St Jeor equation), the body mass index and a daily energy target.\n\n## Inputs\n\n" % v
    s += "- `weight` (decimal, required, max 1): body weight in kilograms.\n"
    if v >= 3:
        s += "- `height` (Quantity, required, max 1): standing height. Its `system` must be `http://unitsofmeasure.org` and its `code` must be `cm`; its `value` is the height in centimetres (`unit` is ignored).\n"
    else:
        s += "- `height` (decimal, required, max 1): standing height in centimetres.\n"
    s += "- `age` (integer, required, max 1): age in whole years.\n"
    s += "- `sex` (code, required, max 1): bound (required) to value set `http://example.org/fhir/ValueSet/energy-sex`, which holds the codes `male` and `female` of code system `http://hl7.org/fhir/administrative-gender` (no others).\n"
    s += "- `activity` (code, optional, max 1): bound (required) to value set `http://example.org/fhir/ValueSet/energy-activity`, code system `http://example.org/fhir/CodeSystem/activity-level`, holding exactly: %s. When omitted it is `sedentary`.\n" % ", ".join("`" + a + "`" for a in acts(v))
    if v >= 2:
        s += "- `goal` (code, required, max 1): bound (required) to value set `http://example.org/fhir/ValueSet/energy-goal`, code system `http://example.org/fhir/CodeSystem/energy-goal`, holding exactly: `maintain`, `lose`, `gain`.\n"
    s += "\nCodes are compared exactly (lower case). Every input is given at most once, under its declared type's `value[Type]` key.\n\n## Rules (a request breaking one is refused with 4xx)\n\n"
    s += "1. `age` is from 18 to 100 inclusive.\n2. `weight` is from 20 to 400 inclusive (kg).\n"
    s += "3. height is from 100 to 230 inclusive (cm)" + (", and its Quantity has the system and code stated above" if v >= 3 else "") + ".\n"
    s += "4. The body mass index (below) is from 12 to 70 inclusive.\n\n## Computation\n\nLet w = weight, h = height in cm, a = age. Use unrounded intermediate values; round only the outputs, half up.\n\n"
    s += "1. bmi = w / (h/100)^2\n2. bmr = 10*w + 6.25*h - 5*a + k, with k = +5 for `male` and k = -161 for `female`.\n"
    s += "3. factor by activity: sedentary 1.2, light 1.375, moderate 1.55, active 1.725" + (", very-active 1.9" if v < 3 else "") + ".\n"
    if v >= 2:
        s += "4. adjustment by goal: maintain 0, lose -500, gain +500 (kcal/day).\n5. energy = bmr * factor + adjustment.\n"
    else:
        s += "4. energy = bmr * factor.\n"
    if v >= 4:
        s += "%d. category from the unrounded bmi: `underweight` if bmi < 18.5; `normal` if 18.5 <= bmi < 25; `overweight` if 25 <= bmi < 30; `obese` if bmi >= 30.\n" % 6
    s += "\n## Outputs (all always present)\n\n- `bmr` (decimal): kcal/day, rounded to 0 decimals.\n- `bmi` (decimal): kg/m2, rounded to 1 decimal.\n- `energy` (decimal): kcal/day, rounded to 0 decimals.\n"
    if v >= 4:
        s += "- `category` (code): the BMI category above (plain code, no system needed).\n"
    return s


CH = {2: "Added required input `goal` (maintain, lose, gain); `energy` now includes the goal adjustment of 0, -500 or +500 kcal/day.",
      3: "`height` is now a Quantity (UCUM `cm`) instead of a decimal. `activity` no longer accepts `very-active` (it is bound to four codes).",
      4: "Added output `category` (code): BMI category underweight, normal, overweight or obese."}

for v in (1, 2, 3, 4):
    d = "v%d" % v
    os.makedirs(d, exist_ok=True)
    json.dump(opdef(v), open(d + "/OperationDefinition.json", "w"), indent=2)
    open(d + "/STATEMENT.md", "w").write(statement(v))
    if v > 1:
        open(d + "/CHANGE.md", "w").write("# Changes in v%d\n\n%s\n" % (v, CH[v]))
    items = cases_for(v)
    random.Random(v).shuffle(items)
    cs = []
    for i, (ab, req) in enumerate(items, 1):
        o = ref(v, req)
        ch = (ref(v - 1, req) != o) if v > 1 else False
        if o is None:
            exp = {"status": "4xx"}
        else:
            exp = {"status": 200, "outputs": [
                {"name": n, "type": t, "value": val, **({"tolerance": tol} if tol is not None else {})}
                for n, (t, val, tol) in o.items()]}
        cs.append({"id": "c%02d" % i, "about": ab, "change": ch, "request": req, "expect": exp})
    json.dump(cs, open(d + "/cases.json", "w"), indent=1)
    ok = sum(1 for c in cs if c["expect"]["status"] == 200)
    assert all(c["request"]["resourceType"] == "Parameters" for c in cs)
    print(v, len(cs), ok, sum(c["change"] for c in cs))
