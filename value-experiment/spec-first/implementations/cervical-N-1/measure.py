from datetime import date


def _d(s, end=False):
    if not s:
        return None
    try:
        return date(int(s[0:4]), int(s[5:7]) if len(s) >= 7 else (12 if end else 1),
                    int(s[8:10]) if len(s) >= 10 else (31 if end else 1))
    except Exception:
        return None


def _codes(cc):
    out = set()
    if isinstance(cc, list):
        for x in cc:
            out |= _codes(x)
    elif isinstance(cc, dict):
        for c in cc.get("coding", []) or []:
            out.add((c.get("system"), c.get("code")))
    return out


def _interval(r):
    for k in ("performedPeriod", "effectivePeriod", "period", "onsetPeriod", "occurrencePeriod"):
        p = r.get(k)
        if isinstance(p, dict):
            s, e = _d(p.get("start")), _d(p.get("end"), True)
            if s or e:
                return s or e, e or s
    for k in ("performedDateTime", "effectiveDateTime", "onsetDateTime", "authoredOn",
              "occurrenceDateTime", "issued", "recordedDate"):
        if r.get(k):
            d = _d(r[k])
            if d:
                return d, d
    return None, None


def _overlaps(r, a, b):
    s, e = _interval(r)
    if s is None:
        return False
    return s <= b and (e or s) >= a


VALUE_KEYS = ("valueQuantity", "valueCodeableConcept", "valueString", "valueInteger",
              "valueBoolean", "valueRange", "valueRatio", "valueDateTime", "valuePeriod",
              "valueTime", "valueSampledData", "component")


def evaluate(resources, valuesets, period_start, period_end):
    ps, pe = _d(period_start), _d(period_end, True)
    V = lambda n: valuesets.get(n, set())
    pat = next((r for r in resources if r.get("resourceType") == "Patient"), {})
    res = {"initial-population": False, "denominator": False,
           "denominator-exclusion": False, "numerator": False}
    bd = _d(pat.get("birthDate"))
    if not bd or pat.get("gender") != "female":
        return res

    def age_at(d):
        return d.year - bd.year - ((d.month, d.day) < (bd.month, bd.day))

    if not (24 <= age_at(pe) <= 64):
        return res
    visit = set()
    for n in ("Office Visit", "Preventive Care Services Established Office Visit, 18 and Up",
              "Preventive Care Services Initial Office Visit, 18 and Up", "Home Healthcare Services",
              "Telephone Visits", "Virtual Encounter"):
        visit |= V(n)
    ok = False
    for r in resources:
        if r.get("resourceType") == "Encounter" and r.get("status") == "finished" \
                and _codes(r.get("type")) & visit:
            s, e = _interval(r)
            if s and ps <= s <= pe:
                ok = True
    if not ok:
        return res
    res["initial-population"] = res["denominator"] = True

    hospice = V("Hospice Encounter") | V("Hospice Care Ambulatory") | V("Hospice Diagnosis")
    hosp_obs = {("http://loinc.org", "45755-6")}
    pal_obs = {("http://loinc.org", "71007-9")}
    hd = {("http://snomed.info/sct", "428371000124100"), ("http://snomed.info/sct", "428361000124107")}
    pal = V("Palliative Care Encounter") | V("Palliative Care Intervention") | V("Palliative Care Diagnosis")
    hyst = V("Hysterectomy with No Residual Cervix")
    absent = V("Congenital or Acquired Absence of Cervix")
    yes = ("http://snomed.info/sct", "373066001")
    bad_status = ("cancelled", "entered-in-error", "not-done", "draft", "unknown")
    excl = False
    for r in resources:
        t = r.get("resourceType")
        if r.get("status") in bad_status:
            continue
        cs = _codes(r.get("code")) | _codes(r.get("type")) | _codes(r.get("serviceType"))
        if t == "Condition":
            vs = {c for _, c in _codes(r.get("verificationStatus"))}
            if vs & {"entered-in-error", "refuted"}:
                continue
            s, e = _interval(r)
            ab = _d(r.get("abatementDateTime") or (r.get("abatementPeriod") or {}).get("start"))
            if cs & (hospice | pal):
                if s is None or (s <= pe and (ab is None or ab >= ps)):
                    excl = True
            if cs & (absent | hyst) and (s is None or s <= pe):
                excl = True
        elif t == "Observation":
            if cs & (hosp_obs | pal_obs | hospice | pal) and yes in _codes(r.get("valueCodeableConcept")) \
                    and _overlaps(r, ps, pe):
                excl = True
        elif t == "Procedure":
            if cs & (hyst | absent):
                s, e = _interval(r)
                if s is None or s <= pe:
                    excl = True
            if cs & (hospice | pal) and _overlaps(r, ps, pe):
                excl = True
        elif t == "Encounter":
            dd = _codes((r.get("hospitalization") or {}).get("dischargeDisposition"))
            if (cs & (hospice | pal) or dd & hd) and _overlaps(r, ps, pe):
                excl = True
        elif t in ("ServiceRequest", "DeviceRequest", "MedicationRequest", "CarePlan", "Task", "Flag"):
            if cs & (hospice | pal) and _overlaps(r, ps, pe):
                excl = True
    if excl:
        res["denominator-exclusion"] = True
        return res

    pap = V("Pap Test")
    hpv = V("HPV Test")
    for r in resources:
        t = r.get("resourceType")
        if t not in ("Observation", "Procedure", "DiagnosticReport"):
            continue
        if r.get("status") not in ("final", "amended", "corrected", "completed"):
            continue
        if t == "Observation" and not any(k in r for k in VALUE_KEYS):
            continue
        cs = _codes(r.get("code"))
        if not cs & (pap | hpv):
            continue
        s, e = _interval(r)
        when = s
        if not when:
            continue
        if cs & pap and date(ps.year - 2, 1, 1) <= when <= pe and age_at(when) >= 21:
            res["numerator"] = True
        if cs & hpv and date(ps.year - 4, 1, 1) <= when <= pe and age_at(when) >= 30:
            res["numerator"] = True
    return res
