SNOMED = "http://snomed.info/sct"
LOINC = "http://loinc.org"
BAD = ("cancelled", "draft", "not-done", "revoked", "entered-in-error")


def _d(s):
    return s[:10] if isinstance(s, str) and len(s) >= 10 else None


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
    for k in ("period", "effectivePeriod", "performedPeriod"):
        p = r.get(k)
        if p:
            return _d(p.get("start")), _d(p.get("end"))
    for k in ("effectiveDateTime", "performedDateTime", "onsetDateTime", "authoredOn",
              "recordedDate", "issued", "effectiveInstant"):
        if r.get(k):
            d = _d(r[k])
            return d, d
    return None, None


def _overlaps(r, lo, hi):
    s, e = _span(r)
    if s is None and e is None:
        return False
    if s is None:
        s = e
    return s <= hi and (e is None or e >= lo)


def _onset(c):
    return (_d(c.get("onsetDateTime")) or _d((c.get("onsetPeriod") or {}).get("start"))
            or _d(c.get("recordedDate")))


def _abate(c):
    return _d(c.get("abatementDateTime")) or _d((c.get("abatementPeriod") or {}).get("end"))


def evaluate(resources, valuesets, period_start, period_end):
    V = lambda n: valuesets.get(n, set())
    ps, pe = period_start[:10], period_end[:10]
    prior = "%04d%s" % (int(ps[:4]) - 1, ps[4:])
    res = [r for r in resources if r.get("status") != "entered-in-error"]
    by = lambda t: [r for r in res if r.get("resourceType") == t]
    out = {"initial-population": False, "denominator": False,
           "denominator-exclusion": False, "numerator": False}

    pat = (by("Patient") or [None])[0]
    if not pat or not pat.get("birthDate"):
        return out
    b = pat["birthDate"][:10]
    age = int(pe[:4]) - int(b[:4]) - ((pe[5:7], pe[8:10]) < (b[5:7], b[8:10]))
    if not 18 <= age <= 75:
        return out

    def diabetes_ok(c):
        if not _in(c.get("code"), V("Diabetes")):
            return False
        vs = {k[1] for k in _codes(c.get("verificationStatus"))}
        if vs & {"refuted", "entered-in-error"}:
            return False
        on, ab = _onset(c), _abate(c)
        if on and on > pe:
            return False
        if ab and ab < ps:
            return False
        st = {k[1] for k in _codes(c.get("clinicalStatus"))}
        if st & {"inactive", "resolved", "remission"} and not ab:
            return False
        return True

    if not any(diabetes_ok(c) for c in by("Condition")):
        return out

    visit_vs = set()
    for n in ("Office Visit", "Annual Wellness Visit", "Home Healthcare Services",
              "Preventive Care Services Established Office Visit, 18 and Up",
              "Preventive Care Services Initial Office Visit, 18 and Up",
              "Telephone Visits", "Virtual Encounter"):
        visit_vs |= V(n)
    encs = by("Encounter")
    if not any(e.get("status") == "finished" and _in(e.get("type"), visit_vs)
               and _overlaps(e, ps, pe) for e in encs):
        return out
    out["initial-population"] = out["denominator"] = True

    def conds(vs, lo, hi):
        res_ = []
        for c in by("Condition"):
            if _in(c.get("code"), vs):
                on, ab = _onset(c), _abate(c)
                if (on is None or on <= hi) and (ab is None or ab >= lo):
                    res_.append(c)
        return res_

    def encs_of(vs, lo, hi):
        return [e for e in encs if e.get("status") not in ("cancelled", "planned")
                and _in(e.get("type"), vs) and _overlaps(e, lo, hi)]

    def procs(vs, lo, hi):
        return [p for p in by("Procedure") + by("ServiceRequest")
                if _in(p.get("code"), vs) and p.get("status") not in BAD
                and not p.get("doNotPerform") and _overlaps(p, lo, hi)]

    def obs_yes(code, lo, hi):
        for o in by("Observation"):
            if _in(o.get("code"), {code}) and _overlaps(o, lo, hi) and \
                    "373066001" in {k[1] for k in _codes(o.get("valueCodeableConcept"))}:
                return True
        return False

    dd = {(SNOMED, "428371000124100"), (SNOMED, "428361000124107")}
    hospice = bool(
        encs_of(V("Hospice Encounter"), ps, pe) or procs(V("Hospice Care Ambulatory"), ps, pe)
        or conds(V("Hospice Diagnosis"), ps, pe) or obs_yes((LOINC, "45755-6"), ps, pe)
        or any(_overlaps(e, ps, pe) and
               _codes((e.get("hospitalization") or {}).get("dischargeDisposition")) & dd
               for e in encs))
    palliative = bool(
        conds(V("Palliative Care Diagnosis"), ps, pe)
        or encs_of(V("Palliative Care Encounter"), ps, pe)
        or procs(V("Palliative Care Intervention"), ps, pe)
        or obs_yes((LOINC, "71007-9"), ps, pe))
    excl = hospice or palliative

    if age >= 66 and not excl:
        if conds({(SNOMED, "160734000")}, "0000-01-01", pe):
            excl = True
        else:
            fd = V("Frailty Device")
            frail = bool(
                conds(V("Frailty Diagnosis"), ps, pe)
                or conds(V("Frailty Symptom"), ps, pe)
                or encs_of(V("Frailty Encounter"), ps, pe)
                or [o for o in by("Observation")
                    if (_in(o.get("code"), V("Frailty Symptom")) or _in(o.get("code"), fd))
                    and _overlaps(o, ps, pe)]
                or [d for d in by("DeviceRequest") + by("Procedure") + by("ServiceRequest")
                    if _in(d.get("codeCodeableConcept") or d.get("code"), fd)
                    and d.get("status") not in BAD and _overlaps(d, ps, pe)])
            if frail:
                adv = bool(conds(V("Advanced Illness"), prior, pe))
                if not adv:
                    for m in by("MedicationRequest") + by("MedicationDispense") + by("MedicationStatement"):
                        if m.get("status") in BAD:
                            continue
                        if _in(m.get("medicationCodeableConcept"), V("Dementia Medications")):
                            s = _d(m.get("authoredOn")) or _d(m.get("whenHandedOver")) or _span(m)[0]
                            if s is None or prior <= s <= pe:
                                adv = True
                                break
                excl = adv
    out["denominator-exclusion"] = excl
    if excl:
        return out

    tests = V("HbA1c Laboratory Test") | {(LOINC, "97506-0")}
    byday = {}
    for o in by("Observation"):
        if o.get("status") not in ("final", "amended", "corrected") or not _in(o.get("code"), tests):
            continue
        s, e = _span(o)
        day = e or s
        if not day or not ps <= day <= pe:
            continue
        q = o.get("valueQuantity")
        val = None
        if q and q.get("value") is not None and q.get("unit", "%") in ("%", "percent") \
                and q.get("code", "%") in ("%", "percent"):
            val = float(q["value"])
        byday.setdefault(day, []).append(val)
    if not byday:
        out["numerator"] = True
        return out
    nums = [v for v in byday[max(byday)] if v is not None]
    out["numerator"] = True if not nums else min(nums) > 9.0
    return out
