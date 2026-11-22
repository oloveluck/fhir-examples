def _d(s):
    return s[:10] if isinstance(s, str) and len(s) >= 10 else None


def _codes(cc):
    out = set()
    if isinstance(cc, list):
        for x in cc:
            out |= _codes(x)
    elif isinstance(cc, dict):
        for c in cc.get("coding", []) or []:
            out.add((c.get("system"), c.get("code")))
    return out


def _in(cc, vs):
    return bool(_codes(cc) & vs)


def _span(r):
    for k in ("period", "effectivePeriod", "performedPeriod", "prevalencePeriod"):
        p = r.get(k)
        if isinstance(p, dict):
            s, e = _d(p.get("start")), _d(p.get("end"))
            if s or e:
                return s or e, e or s
    for k in ("effectiveDateTime", "performedDateTime", "onsetDateTime", "authoredOn",
              "issued", "occurrenceDateTime", "recordedDate"):
        if _d(r.get(k)):
            return _d(r[k]), _d(r[k])
    return None, None


def _overlap(r, a, b):
    s, e = _span(r)
    if s is None:
        return False
    return s <= b and (e or s) >= a


YES = {("http://snomed.info/sct", "373066001")}
NURSING = {("http://snomed.info/sct", "160734000")}


def evaluate(resources, valuesets, period_start, period_end):
    ps, pe = period_start[:10], period_end[:10]
    prior = "%04d%s" % (int(ps[:4]) - 1, ps[4:])
    V = lambda n: valuesets.get(n, set())
    res = {"initial-population": False, "denominator": False,
           "denominator-exclusion": False, "numerator": False}
    by = {}
    for r in resources:
        if r.get("status") == "entered-in-error":
            continue
        by.setdefault(r.get("resourceType"), []).append(r)

    pat = (by.get("Patient") or [None])[0]
    if not pat or not _d(pat.get("birthDate")):
        return res
    b = pat["birthDate"]
    bm = int(b[5:7]) if len(b) >= 7 else 1
    bd = int(b[8:10]) if len(b) >= 10 else 1
    age = int(pe[:4]) - int(b[:4]) - ((int(pe[5:7]), int(pe[8:10])) < (bm, bd))
    if not 18 <= age <= 75:
        return res

    def cond_active(c, a, z):
        vs = _codes(c.get("verificationStatus"))
        if any(x[1] in ("entered-in-error", "refuted") for x in vs):
            return False
        cs = {x[1] for x in _codes(c.get("clinicalStatus"))}
        s = (_d(c.get("onsetDateTime")) or _d((c.get("onsetPeriod") or {}).get("start"))
             or _d(c.get("recordedDate")) or "0000")
        e = _d(c.get("abatementDateTime")) or _d((c.get("abatementPeriod") or {}).get("end"))
        if e is None and cs & {"inactive", "resolved", "remission"}:
            return False
        return s <= z and (e is None or e >= a)

    conds = by.get("Condition", [])
    encs_all = by.get("Encounter", [])
    if not any(_in(c.get("code"), V("Diabetes")) and cond_active(c, ps, pe) for c in conds):
        return res

    visit_sets = ["Office Visit", "Annual Wellness Visit",
                  "Preventive Care Services Established Office Visit, 18 and Up",
                  "Preventive Care Services Initial Office Visit, 18 and Up",
                  "Home Healthcare Services", "Telephone Visits", "Virtual Encounter"]
    vis = set()
    for n in visit_sets:
        vis |= V(n)
    encs = [e for e in encs_all if e.get("status", "finished") == "finished"]
    if not any(_in(e.get("type"), vis) and _overlap(e, ps, pe) for e in encs):
        return res
    res["initial-population"] = res["denominator"] = True

    obs = by.get("Observation", [])

    def has(rtype, vsname, a, z, field="code"):
        return any(_in(r.get(field), V(vsname)) and _overlap(r, a, z) for r in by.get(rtype, []))

    hosp_dis = {("http://snomed.info/sct", "428371000124100"), ("http://snomed.info/sct", "428361000124107")}
    hospice = (
        any(_in(e.get("type"), V("Hospice Encounter")) and _overlap(e, ps, pe) for e in encs_all)
        or any(_in((e.get("hospitalization") or {}).get("dischargeDisposition"), hosp_dis)
               and _overlap(e, ps, pe) for e in encs_all)
        or has("ServiceRequest", "Hospice Care Ambulatory", ps, pe)
        or has("Procedure", "Hospice Care Ambulatory", ps, pe)
        or has("Observation", "Hospice Care Ambulatory", ps, pe)
        or any(_in(c.get("code"), V("Hospice Diagnosis")) and cond_active(c, ps, pe) for c in conds)
        or any(_in(o.get("code"), {("http://loinc.org", "45755-6")})
               and _in(o.get("valueCodeableConcept"), YES) and _overlap(o, ps, pe) for o in obs)
    )
    palliative = (
        any(_in(c.get("code"), V("Palliative Care Diagnosis")) and cond_active(c, ps, pe) for c in conds)
        or any(_in(e.get("type"), V("Palliative Care Encounter")) and _overlap(e, ps, pe) for e in encs_all)
        or has("Procedure", "Palliative Care Intervention", ps, pe)
        or has("ServiceRequest", "Palliative Care Intervention", ps, pe)
        or has("Observation", "Palliative Care Intervention", ps, pe)
        or any(_in(o.get("code"), {("http://loinc.org", "71007-9")})
               and _in(o.get("valueCodeableConcept"), YES) and _overlap(o, ps, pe) for o in obs)
    )
    excl = hospice or palliative

    if not excl and age >= 66:
        nursing = any(_in(o.get("code"), {("http://loinc.org", "71802-3")})
                      and _in(o.get("valueCodeableConcept"), NURSING)
                      and (_span(o)[0] or "9") <= pe for o in obs)
        nursing = nursing or any(_in(c.get("code"), NURSING) and cond_active(c, "0000", pe) for c in conds)
        if nursing:
            excl = True
        else:
            fd, fs = V("Frailty Device"), V("Frailty Symptom")
            frail = (
                any(_in(c.get("code"), V("Frailty Diagnosis")) and cond_active(c, ps, pe) for c in conds)
                or any(_in(e.get("type"), V("Frailty Encounter")) and _overlap(e, ps, pe) for e in encs_all)
                or has("DeviceRequest", "Frailty Device", ps, pe, "codeCodeableConcept")
                or has("ServiceRequest", "Frailty Device", ps, pe)
                or has("Procedure", "Frailty Device", ps, pe)
                or any(_overlap(o, ps, pe) and (_in(o.get("code"), fs) or _in(o.get("code"), fd)
                       or _in(o.get("valueCodeableConcept"), fd) or _in(o.get("valueCodeableConcept"), fs))
                       for o in obs)
            )
            if frail:
                adv = any(_in(c.get("code"), V("Advanced Illness")) and cond_active(c, prior, pe) for c in conds)
                if not adv:
                    meds = by.get("MedicationRequest", []) + by.get("MedicationStatement", []) + by.get("MedicationDispense", [])
                    for m in meds:
                        if m.get("status") in ("cancelled", "draft"):
                            continue
                        if _in(m.get("medicationCodeableConcept"), V("Dementia Medications")):
                            s, e = _span(m)
                            if s and s <= pe and (e or s) >= prior:
                                adv = True
                if adv:
                    excl = True
    if excl:
        res["denominator-exclusion"] = True
        return res

    tests = V("HbA1c Laboratory Test") | {("http://loinc.org", "97506-0")}
    byday = {}
    for o in obs:
        if o.get("status") not in ("final", "amended", "corrected"):
            continue
        if not _in(o.get("code"), tests):
            continue
        s, e = _span(o)
        day = e or s
        if not day or not (ps <= day <= pe):
            continue
        q = o.get("valueQuantity")
        if not isinstance(q, dict) or q.get("value") is None:
            continue
        unit = q.get("unit") or q.get("code")
        if unit not in (None, "%", "percent", "Percent"):
            continue
        byday.setdefault(day, []).append(float(q["value"]))
    if not byday:
        res["numerator"] = True
    else:
        res["numerator"] = min(byday[max(byday)]) > 9.0
    return res
