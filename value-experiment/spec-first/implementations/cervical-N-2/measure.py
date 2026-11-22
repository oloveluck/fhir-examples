from datetime import date


def _d(s):
    if not s or not isinstance(s, str):
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


def _span(r):
    """(start, end) dates of the clinical event."""
    for k in ("performed", "effective", "onset", "occurrence", "period"):
        for suf in ("Period", "DateTime", "Instant", ""):
            v = r.get(k + suf)
            if v is None:
                continue
            if isinstance(v, dict):
                s, e = _d(v.get("start")), _d(v.get("end"))
                if s or e:
                    return (s or e, e or s)
            elif isinstance(v, str):
                d = _d(v)
                if d:
                    return (d, d)
    for k in ("recordedDate", "authoredOn", "issued", "date"):
        d = _d(r.get(k))
        if d:
            return (d, d)
    return (None, None)


def evaluate(resources, valuesets, period_start, period_end):
    ps, pe = _d(period_start), _d(period_end)

    def V(*names):
        out = set()
        for n in names:
            out |= set(valuesets.get(n, set()))
        return out

    res = {"initial-population": False, "denominator": False,
           "denominator-exclusion": False, "numerator": False}
    pat = next((r for r in resources if r.get("resourceType") == "Patient"), None)
    if not pat:
        return res
    bd = _d(pat.get("birthDate"))
    if not bd or pat.get("gender") != "female":
        return res

    def age(at):
        return at.year - bd.year - ((at.month, at.day) < (bd.month, bd.day))

    def overlaps(r):
        s, e = _span(r)
        if s is None:
            return False
        return s <= pe and e >= ps

    visit_vs = V("Office Visit", "Preventive Care Services Established Office Visit, 18 and Up",
                 "Preventive Care Services Initial Office Visit, 18 and Up", "Home Healthcare Services",
                 "Telephone Visits", "Virtual Encounter")
    enc = [r for r in resources if r.get("resourceType") == "Encounter"]
    visit = any(r.get("status") == "finished" and overlaps(r) and
                (_codes(r.get("type")) & visit_vs) for r in enc)
    if not (24 <= age(pe) <= 64 and visit):
        return res
    res["initial-population"] = res["denominator"] = True

    hosp_vs = V("Hospice Encounter", "Hospice Care Ambulatory")
    pal_vs = V("Palliative Care Encounter", "Palliative Care Intervention")
    hospice_disp = {("http://snomed.info/sct", "428371000124100"),
                    ("http://snomed.info/sct", "428361000124107")}
    yes = ("http://snomed.info/sct", "373066001")
    excl = False
    for r in resources:
        t = r.get("resourceType")
        if t == "Encounter":
            if not overlaps(r):
                continue
            if _codes(r.get("type")) & (hosp_vs | pal_vs):
                excl = True
            if _codes((r.get("hospitalization") or {}).get("dischargeDisposition")) & hospice_disp:
                excl = True
        elif t in ("Procedure", "ServiceRequest", "DeviceRequest"):
            if r.get("status") in ("entered-in-error", "not-done", "cancelled", "revoked"):
                continue
            c = _codes(r.get("code"))
            if c & (hosp_vs | pal_vs) and overlaps(r):
                excl = True
            if t == "Procedure":
                if r.get("status") == "completed" and c & V("Hysterectomy with No Residual Cervix"):
                    s, _ = _span(r)
                    if s is None or s <= pe:
                        excl = True
                if c & V("Congenital or Acquired Absence of Cervix"):
                    excl = True
        elif t == "Observation":
            c = _codes(r.get("code"))
            if (overlaps(r) and r.get("status") not in ("entered-in-error", "cancelled")
                    and yes in _codes(r.get("valueCodeableConcept"))
                    and c & {("http://loinc.org", "45755-6"), ("http://loinc.org", "71007-9")}):
                excl = True
        elif t == "Condition":
            c = _codes(r.get("code"))
            if c & V("Hospice Diagnosis", "Palliative Care Diagnosis"):
                s, _ = _span(r)
                cl = _codes(r.get("clinicalStatus"))
                inactive = any(x[1] in ("inactive", "resolved", "remission") for x in cl)
                ab = r.get("abatementDateTime") or (r.get("abatementPeriod") or {}).get("start")
                end = _d(ab) if ab else None
                if s is None:
                    s = ps
                if s <= pe and ((end is None and not inactive) or (end and end >= ps)):
                    excl = True
            if c & V("Congenital or Acquired Absence of Cervix"):
                s, _ = _span(r)
                if s is None or s <= pe:
                    excl = True
    res["denominator-exclusion"] = excl
    if excl:
        return res

    pap, hpv = V("Pap Test"), V("HPV Test")
    pap_start = date(ps.year - 2, ps.month, ps.day)
    hpv_start = date(ps.year - 4, ps.month, ps.day)
    for r in resources:
        t = r.get("resourceType")
        if t not in ("Observation", "Procedure", "DiagnosticReport"):
            continue
        st = r.get("status")
        if t == "Procedure" and st != "completed":
            continue
        if t != "Procedure" and st not in ("final", "amended", "corrected"):
            continue
        s, e = _span(r)
        if e is None:
            continue
        c = _codes(r.get("code"))
        if c & pap and pap_start <= e <= pe and age(e) >= 21:
            res["numerator"] = True
        if c & hpv and hpv_start <= e <= pe and age(e) >= 30:
            res["numerator"] = True
    return res
