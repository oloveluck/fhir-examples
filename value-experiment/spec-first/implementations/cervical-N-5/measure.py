from datetime import date


def _d(s):
    if not s:
        return None
    try:
        return date(int(s[0:4]), int(s[5:7]) if len(s) >= 7 else 1, int(s[8:10]) if len(s) >= 10 else 1)
    except Exception:
        return None


def _codes(cc):
    out = set()
    if not cc:
        return out
    if isinstance(cc, list):
        for x in cc:
            out |= _codes(x)
        return out
    for c in cc.get("coding", []) or []:
        out.add((c.get("system"), c.get("code")))
    return out


def _in(cc, *sets):
    cs = _codes(cc)
    return any(cs & s for s in sets)


def _range(r):
    for k in ("performedPeriod", "period", "effectivePeriod"):
        p = r.get(k)
        if isinstance(p, dict):
            s, e = _d(p.get("start")), _d(p.get("end"))
            return (s or e, e or s)
    for k in ("performedDateTime", "effectiveDateTime", "onsetDateTime", "recordedDate",
              "authoredOn", "issued", "effectiveInstant"):
        if r.get(k):
            d = _d(r[k])
            return (d, d)
    return (None, None)


def _age(birth, on):
    return on.year - birth.year - ((on.month, on.day) < (birth.month, birth.day))


def _minus(d, years):
    try:
        return d.replace(year=d.year - years)
    except ValueError:
        return d.replace(year=d.year - years, day=28)


def evaluate(resources, valuesets, period_start, period_end):
    ps, pe = _d(period_start), _d(period_end)
    V = lambda n: valuesets.get(n, set())
    res = {"initial-population": False, "denominator": False,
           "denominator-exclusion": False, "numerator": False}
    pats = [r for r in resources if r.get("resourceType") == "Patient"]
    if not pats:
        return res
    pat = pats[0]
    birth = _d(pat.get("birthDate"))
    if birth is None or pat.get("gender") != "female":
        return res
    if not (23 <= _age(birth, pe) <= 64):
        return res

    visit_sets = [V("Office Visit"), V("Preventive Care Services Established Office Visit, 18 and Up"),
                  V("Preventive Care Services Initial Office Visit, 18 and Up"),
                  V("Home Healthcare Services"), V("Telephone Visits"), V("Virtual Encounter")]

    def overlaps(r, a, b):
        s, e = _range(r)
        if s is None:
            return False
        return s <= b and (e or s) >= a

    ok = False
    for e in resources:
        if e.get("resourceType") != "Encounter" or e.get("status") != "finished":
            continue
        if _in(e.get("type"), *visit_sets):
            s, en = _range(e)
            if s is not None and ps <= s <= pe and (en is None or en <= pe):
                ok = True
                break
    if not ok:
        return res
    res["initial-population"] = True
    res["denominator"] = True

    hosp_enc, hosp_dx, hosp_amb = V("Hospice Encounter"), V("Hospice Diagnosis"), V("Hospice Care Ambulatory")
    pal_enc, pal_dx, pal_iv = V("Palliative Care Encounter"), V("Palliative Care Diagnosis"), V("Palliative Care Intervention")
    hyst, absent = V("Hysterectomy with No Residual Cervix"), V("Congenital or Acquired Absence of Cervix")
    hosp_disp = {("http://snomed.info/sct", "428371000124100"), ("http://snomed.info/sct", "428361000124107")}
    mds, facit = {("http://loinc.org", "45755-6")}, {("http://loinc.org", "71007-9")}
    yes = {("http://snomed.info/sct", "373066001")}
    excl = False
    for r in resources:
        t = r.get("resourceType")
        if t == "Encounter":
            if overlaps(r, ps, pe):
                if _in(r.get("type"), hosp_enc, pal_enc):
                    excl = True
                if _in((r.get("hospitalization") or {}).get("dischargeDisposition"), hosp_disp):
                    excl = True
        elif t == "Condition":
            if _in(r.get("code"), hosp_dx, pal_dx):
                s, _e = _range(r)
                ab = _d(r.get("abatementDateTime") or (r.get("abatementPeriod") or {}).get("start"))
                st = _d(r.get("onsetDateTime") or (r.get("onsetPeriod") or {}).get("start")) or s
                if (st is None or st <= pe) and (ab is None or ab >= ps):
                    excl = True
            if _in(r.get("code"), absent):
                excl = True
        elif t == "Observation":
            if _in(r.get("code"), mds, facit) and _in(r.get("valueCodeableConcept"), yes) \
                    and overlaps(r, ps, pe):
                excl = True
        elif t in ("Procedure", "ServiceRequest"):
            if t == "Procedure" and r.get("status") not in ("completed", "in-progress"):
                continue
            if t == "ServiceRequest" and r.get("status") in ("entered-in-error", "revoked", "draft"):
                continue
            if _in(r.get("code"), hosp_amb, pal_iv) and overlaps(r, ps, pe):
                excl = True
            if t == "Procedure" and _in(r.get("code"), hyst):
                s, _e = _range(r)
                if s is None or s <= pe:
                    excl = True
    res["denominator-exclusion"] = excl

    if not excl:
        pap, hpv = V("Pap Test"), V("HPV Test")
        for r in resources:
            t = r.get("resourceType")
            if t == "Procedure":
                if r.get("status") != "completed":
                    continue
            elif t == "Observation":
                if r.get("status") not in ("final", "amended", "corrected"):
                    continue
                if not any(k.startswith("value") for k in r):
                    continue
            else:
                continue
            s, e = _range(r)
            d = e or s
            if d is None or d > pe:
                continue
            a = _age(birth, d)
            if _in(r.get("code"), pap) and d >= _minus(ps, 2) and a >= 21:
                res["numerator"] = True
            if _in(r.get("code"), hpv) and d >= _minus(ps, 4) and a >= 30:
                res["numerator"] = True
    return res
