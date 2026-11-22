from datetime import date

HOSP_DIS = {("http://snomed.info/sct", "428371000124100"), ("http://snomed.info/sct", "428361000124107")}
HOSPICE_OBS = {("http://loinc.org", "45755-6")}
FACIT = {("http://loinc.org", "71007-9")}
YES = {("http://snomed.info/sct", "373066001")}


def _d(s):
    if not s:
        return None
    try:
        return date(int(s[0:4]), int(s[5:7]) if len(s) >= 7 else 1, int(s[8:10]) if len(s) >= 10 else 1)
    except Exception:
        return None


def _codes(cc):
    out = set()
    if isinstance(cc, dict):
        cc = [cc]
    for c in cc or []:
        for k in c.get("coding", []) or []:
            out.add((k.get("system"), k.get("code")))
    return out


def _in(cc, *sets):
    cs = _codes(cc)
    return any(cs & s for s in sets)


def _span(r):
    for k in ("performedPeriod", "effectivePeriod", "period", "onsetPeriod"):
        p = r.get(k)
        if isinstance(p, dict):
            s, e = _d(p.get("start")), _d(p.get("end"))
            if s or e:
                return (s or e, e)
    for k in ("performedDateTime", "effectiveDateTime", "effectiveInstant", "performedInstant",
              "onsetDateTime", "authoredOn", "recordedDate", "issued"):
        if r.get(k):
            x = _d(r[k])
            return (x, x)
    return (None, None)


def _overlaps(sp, a, b):
    s, e = sp
    if s is None and e is None:
        return False
    if e is None:
        e = date(9999, 1, 1)
    return s <= b and e >= a


def _age(bd, on):
    return on.year - bd.year - ((on.month, on.day) < (bd.month, bd.day))


def evaluate(resources, valuesets, period_start, period_end):
    ps, pe = _d(period_start), _d(period_end)

    def V(n):
        return valuesets.get(n, set())

    res = {"initial-population": False, "denominator": False,
           "denominator-exclusion": False, "numerator": False}
    pat = next((r for r in resources if r.get("resourceType") == "Patient"), None)
    if not pat:
        return res
    bd = _d(pat.get("birthDate"))
    if not bd or pat.get("gender") != "female":
        return res
    if not (24 <= _age(bd, pe) <= 64):
        return res

    visit_sets = [V(n) for n in (
        "Office Visit", "Preventive Care Services Established Office Visit, 18 and Up",
        "Preventive Care Services Initial Office Visit, 18 and Up", "Home Healthcare Services",
        "Telephone Visits", "Virtual Encounter")]
    ok = False
    for e in resources:
        if e.get("resourceType") != "Encounter":
            continue
        if e.get("status") in (None, "finished") and _in(e.get("type"), *visit_sets) \
                and _overlaps(_span(e), ps, pe):
            ok = True
    if not ok:
        return res
    res["initial-population"] = res["denominator"] = True

    absence = (V("Congenital or Acquired Absence of Cervix"), V("Hysterectomy with No Residual Cervix"))
    hp = (V("Hospice Care Ambulatory"), V("Palliative Care Intervention"))
    excl = False
    for r in resources:
        t = r.get("resourceType")
        st = r.get("status")
        if st in ("entered-in-error", "cancelled", "not-done", "refuted", "revoked"):
            continue
        sp = _span(r)
        code = r.get("code")
        if t == "Encounter":
            if _in(r.get("type"), V("Hospice Encounter"), V("Palliative Care Encounter")) and _overlaps(sp, ps, pe):
                excl = True
            if _in((r.get("hospitalization") or {}).get("dischargeDisposition"), HOSP_DIS) and _overlaps(sp, ps, pe):
                excl = True
        elif t == "Condition":
            if _in(code, V("Hospice Diagnosis"), V("Palliative Care Diagnosis")):
                s = _d(r.get("onsetDateTime")) or _d(r.get("recordedDate")) or sp[0]
                e = _d(r.get("abatementDateTime"))
                if (s is None or s <= pe) and (e is None or e >= ps):
                    excl = True
            if _in(code, *absence):
                s = _d(r.get("onsetDateTime")) or sp[0]
                if s is None or s <= pe:
                    excl = True
        elif t == "Procedure":
            if _in(code, *hp) and _overlaps(sp, ps, pe):
                excl = True
            if _in(code, *absence):
                s = sp[1] or sp[0]
                if s is None or s <= pe:
                    excl = True
        elif t == "Observation":
            if _in(code, HOSPICE_OBS) and _in(r.get("valueCodeableConcept"), YES) and _overlaps(sp, ps, pe):
                excl = True
            if _in(code, FACIT) and _overlaps(sp, ps, pe):
                excl = True
            if _in(code, *hp) and _overlaps(sp, ps, pe):
                excl = True
        elif t in ("ServiceRequest", "DeviceRequest"):
            if _in(code, *hp) and _overlaps(sp, ps, pe) and st in ("active", "completed", "on-hold"):
                excl = True
    if excl:
        res["denominator-exclusion"] = True
        return res

    pap_start = date(ps.year - 2, ps.month, ps.day)
    hpv_start = date(ps.year - 4, ps.month, ps.day)
    for r in resources:
        t = r.get("resourceType")
        if t not in ("Observation", "Procedure", "DiagnosticReport"):
            continue
        if t == "Procedure":
            if r.get("status") != "completed":
                continue
        elif r.get("status") not in ("final", "amended", "corrected", "preliminary"):
            continue
        sp = _span(r)
        d = sp[1] or sp[0]
        if d is None:
            continue
        if t == "Observation" and not any(k.startswith("value") or k == "component" for k in r):
            continue
        a = _age(bd, d)
        if _in(r.get("code"), V("Pap Test")) and pap_start <= d <= pe and a >= 21:
            res["numerator"] = True
        if _in(r.get("code"), V("HPV Test")) and hpv_start <= d <= pe and a >= 30:
            res["numerator"] = True
    return res
