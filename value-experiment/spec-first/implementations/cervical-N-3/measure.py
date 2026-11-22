from datetime import date

VALUE_KEYS = ("valueCodeableConcept", "valueQuantity", "valueString", "valueBoolean", "valueInteger",
              "valueRange", "valueRatio", "valueDateTime", "valuePeriod", "valueTime")


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


def _in(cc, vs):
    return bool(_codes(cc) & vs)


def _span(r):
    for k in ("period", "performedPeriod", "effectivePeriod"):
        p = r.get(k)
        if p:
            s, e = _d(p.get("start")), _d(p.get("end"))
            return s or e, e or s
    for k in ("performedDateTime", "effectiveDateTime", "performedInstant", "effectiveInstant",
              "onsetDateTime", "authoredOn", "recordedDate", "issued"):
        if r.get(k):
            x = _d(r[k])
            return x, x
    return None, None


def _age(birth, on):
    return on.year - birth.year - ((on.month, on.day) < (birth.month, birth.day))


def evaluate(resources, valuesets, period_start, period_end):
    ps, pe = _d(period_start), _d(period_end)
    V = lambda n: valuesets.get(n, set())
    res = {"initial-population": False, "denominator": False,
           "denominator-exclusion": False, "numerator": False}
    pat = next((r for r in resources if r.get("resourceType") == "Patient"), None)
    if not pat:
        return res
    birth = _d(pat.get("birthDate"))
    if pat.get("gender") != "female" or not birth:
        return res
    if not (23 <= _age(birth, pe) <= 64):
        return res

    def overlaps(r):
        s, e = _span(r)
        if s is None:
            return False
        return s <= pe and e >= ps

    visit = (V("Office Visit") | V("Preventive Care Services Established Office Visit, 18 and Up")
             | V("Preventive Care Services Initial Office Visit, 18 and Up") | V("Home Healthcare Services")
             | V("Telephone Visits") | V("Virtual Encounter"))
    ok = False
    for r in resources:
        if (r.get("resourceType") == "Encounter" and r.get("status") == "finished"
                and _in(r.get("type"), visit) and overlaps(r)):
            ok = True
    if not ok:
        return res
    res["initial-population"] = res["denominator"] = True

    hosp = V("Hospice Encounter") | V("Hospice Care Ambulatory") | V("Hospice Diagnosis")
    pall = V("Palliative Care Encounter") | V("Palliative Care Intervention") | V("Palliative Care Diagnosis")
    absent = V("Hysterectomy with No Residual Cervix") | V("Congenital or Acquired Absence of Cervix")
    disch = {("http://snomed.info/sct", "428371000124100"), ("http://snomed.info/sct", "428361000124107")}
    excl = False
    for r in resources:
        t = r.get("resourceType")
        if r.get("status") in ("entered-in-error", "cancelled", "not-done"):
            continue
        if t == "Encounter":
            if _in(r.get("type"), hosp | pall) and overlaps(r):
                excl = True
            if _in((r.get("hospitalization") or {}).get("dischargeDisposition"), disch) and overlaps(r):
                excl = True
        elif t == "Observation":
            code = _codes(r.get("code"))
            if ("http://loinc.org", "45755-6") in code and _in(
                    r.get("valueCodeableConcept"), {("http://snomed.info/sct", "373066001")}) and overlaps(r):
                excl = True
            if ("http://loinc.org", "71007-9") in code and overlaps(r):
                excl = True
        elif t in ("Procedure", "ServiceRequest", "DeviceRequest", "MedicationRequest"):
            code = r.get("code")
            if _in(code, hosp | pall) and overlaps(r):
                excl = True
            if t == "Procedure" and _in(code, absent):
                s, e = _span(r)
                if s is None or s <= pe:
                    excl = True
        elif t == "Condition":
            code = r.get("code")
            s = (_d(r.get("onsetDateTime")) or _d((r.get("onsetPeriod") or {}).get("start"))
                 or _d(r.get("recordedDate")))
            ab = _d(r.get("abatementDateTime")) or _d((r.get("abatementPeriod") or {}).get("end"))
            if _in(code, hosp | pall) and (s is None or s <= pe) and (ab is None or ab >= ps):
                excl = True
            if _in(code, absent) and (s is None or s <= pe):
                excl = True
    if excl:
        res["denominator-exclusion"] = True
        return res

    pap, hpv = V("Pap Test"), V("HPV Test")
    pap_start = date(ps.year - 2, 1, 1)
    hpv_start = date(ps.year - 4, 1, 1)
    for r in resources:
        t = r.get("resourceType")
        if t not in ("Observation", "Procedure", "DiagnosticReport"):
            continue
        if r.get("status") not in ("final", "completed", "amended", "corrected", "appended"):
            continue
        s, e = _span(r)
        when = s or e
        if when is None:
            continue
        if t == "Observation" and not any(k in r for k in VALUE_KEYS):
            continue
        code = r.get("code")
        if _in(code, pap) and pap_start <= when <= pe and _age(birth, when) >= 21:
            res["numerator"] = True
        if _in(code, hpv) and hpv_start <= when <= pe and _age(birth, when) >= 30:
            res["numerator"] = True
    return res
