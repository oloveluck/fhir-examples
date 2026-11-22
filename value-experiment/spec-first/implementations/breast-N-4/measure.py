from datetime import date

BAD = {"entered-in-error", "cancelled", "not-done", "stopped", "draft", "declined"}
PE_INF = date(9999, 12, 31)
SCT = "http://snomed.info/sct"


def _d(s):
    if not s or not isinstance(s, str):
        return None
    try:
        return date(int(s[0:4]), int(s[5:7]) if len(s) >= 7 else 1, int(s[8:10]) if len(s) >= 10 else 1)
    except Exception:
        return None


def _cc(x, out):
    if isinstance(x, list):
        for y in x:
            _cc(y, out)
    elif isinstance(x, dict):
        for c in x.get("coding", []) or []:
            out.add((c.get("system"), c.get("code")))


def _codes(res):
    out = set()
    for k in ("code", "type", "serviceType", "medicationCodeableConcept", "valueCodeableConcept"):
        _cc(res.get(k), out)
    h = res.get("hospitalization")
    if isinstance(h, dict):
        _cc(h.get("dischargeDisposition"), out)
    return out


def _span(res):
    rt = res.get("resourceType")
    if rt == "Condition":
        s = _d(res.get("onsetDateTime") or (res.get("onsetPeriod") or {}).get("start") or res.get("recordedDate"))
        e = _d(res.get("abatementDateTime") or (res.get("abatementPeriod") or {}).get("end"))
        return s, e
    for k in ("performedPeriod", "effectivePeriod", "period", "occurrencePeriod"):
        p = res.get(k)
        if isinstance(p, dict):
            s, e = _d(p.get("start")), _d(p.get("end"))
            if s or e:
                return s, e or s
    for k in ("performedDateTime", "effectiveDateTime", "effectiveInstant", "occurrenceDateTime",
              "authoredOn", "issued", "dateAsserted", "recordedDate"):
        v = _d(res.get(k))
        if v:
            return v, v
    dr = res.get("dispenseRequest")
    if isinstance(dr, dict) and isinstance(dr.get("validityPeriod"), dict):
        return _d(dr["validityPeriod"].get("start")), _d(dr["validityPeriod"].get("end"))
    return None, None


def evaluate(resources, valuesets, period_start, period_end):
    ps, pe = _d(period_start), _d(period_end)
    prior_start = date(ps.year - 1, ps.month, ps.day)
    no = {"initial-population": False, "denominator": False,
          "denominator-exclusion": False, "numerator": False}
    res_all = [r for r in resources if isinstance(r, dict)]
    patient = next((r for r in res_all if r.get("resourceType") == "Patient"), {})
    recs = []
    for r in res_all:
        if r.get("resourceType") == "Patient" or r.get("status") in BAD:
            continue
        vs = (r.get("verificationStatus") or {}).get("coding") or []
        if any(c.get("code") in ("refuted", "entered-in-error") for c in vs):
            continue
        s, e = _span(r)
        recs.append((r, _codes(r), s, e))

    def find(names, lo=None, hi=None, types=None):
        codes = set()
        for n in names:
            codes |= valuesets.get(n, set())
        out = []
        for r, cs, s, e in recs:
            if types and r.get("resourceType") not in types:
                continue
            if not (cs & codes):
                continue
            if lo is not None or hi is not None:
                if s is None and e is None:
                    continue
                st = s or e
                en = e
                if en is None:
                    en = PE_INF if r.get("resourceType") == "Condition" else st
                if hi is not None and st > hi:
                    continue
                if lo is not None and en < lo:
                    continue
            out.append((r, s, e))
        return out

    if patient.get("gender") != "female":
        return no
    bd = _d(patient.get("birthDate"))
    if not bd:
        return no
    age = pe.year - bd.year - ((pe.month, pe.day) < (bd.month, bd.day))
    if not (52 <= age <= 74):
        return no
    visits = find(["Office Visit", "Annual Wellness Visit",
                   "Preventive Care Services Established Office Visit, 18 and Up",
                   "Preventive Care Services Initial Office Visit, 18 and Up", "Home Healthcare Services",
                   "Telephone Visits", "Virtual Encounter"], ps, pe, types={"Encounter"})
    if not visits:
        return no
    res = {"initial-population": True, "denominator": True,
           "denominator-exclusion": False, "numerator": False}

    excl = False
    # hospice
    if find(["Hospice Encounter", "Hospice Care Ambulatory", "Hospice Diagnosis"], ps, pe):
        excl = True
    hc = {(SCT, "428371000124100"), (SCT, "428361000124107")}
    for r, cs, s, e in recs:
        d = s or e
        if cs & hc and d and ps <= d <= pe:
            excl = True
        if ("http://loinc.org", "45755-6") in cs and d and ps <= d <= pe:
            if (SCT, "373066001") in cs:
                excl = True
    # palliative
    if find(["Palliative Care Encounter", "Palliative Care Intervention", "Palliative Care Diagnosis"], ps, pe):
        excl = True
    for r, cs, s, e in recs:
        d = s or e
        if ("http://loinc.org", "71007-9") in cs and d and ps <= d <= pe:
            excl = True

    # mastectomy (on or before end of period)
    def upto_end(names):
        return find(names, None, pe)

    if upto_end(["Bilateral Mastectomy", "History of bilateral mastectomy"]):
        excl = True
    left = upto_end(["Unilateral Mastectomy Left", "Status Post Left Mastectomy"])
    right = upto_end(["Unilateral Mastectomy Right", "Status Post Right Mastectomy"])
    for r, s, e in upto_end(["Unilateral Mastectomy, Unspecified Laterality"]):
        bs = set()
        _cc(r.get("bodySite"), bs)
        if (SCT, "7771000") in bs:
            left.append((r, s, e))
        if (SCT, "24028007") in bs:
            right.append((r, s, e))
    if left and right:
        excl = True

    if age >= 66:
        if find(["Frailty Device", "Frailty Diagnosis", "Frailty Encounter", "Frailty Symptom"], ps, pe):
            if find(["Advanced Illness"], prior_start, pe) or find(["Dementia Medications"], prior_start, pe):
                excl = True
        for r, cs, s, e in recs:
            if (SCT, "160734000") in cs:
                st = s or e
                if st is None or st <= pe:
                    excl = True

    res["denominator-exclusion"] = excl
    if not excl:
        lo = date(ps.year - 2, 10, 1)
        for r, s, e in find(["Mammography"], lo, pe):
            if r.get("resourceType") in ("Observation", "DiagnosticReport", "Procedure"):
                res["numerator"] = True
    return res
