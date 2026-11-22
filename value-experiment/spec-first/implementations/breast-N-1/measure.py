from datetime import date

SNOMED = "http://snomed.info/sct"
LOINC = "http://loinc.org"
NOT_ACTIVE = ("entered-in-error", "cancelled", "draft", "revoked", "rejected", "stopped", "not-done")


def _d(s):
    if not s:
        return None
    try:
        return date(int(s[:4]), int(s[5:7]) if len(s) >= 7 else 1, int(s[8:10]) if len(s) >= 10 else 1)
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
    for k in ("period", "performedPeriod", "effectivePeriod"):
        p = r.get(k)
        if isinstance(p, dict):
            return _d(p.get("start")), _d(p.get("end"))
    if r.get("onsetDateTime") or r.get("onsetPeriod"):
        if r.get("onsetPeriod"):
            s = _d(r["onsetPeriod"].get("start"))
        else:
            s = _d(r["onsetDateTime"])
        e = _d(r.get("abatementDateTime")) if r.get("abatementDateTime") else None
        if r.get("abatementPeriod"):
            e = _d(r["abatementPeriod"].get("end"))
        return s, e
    for k in ("performedDateTime", "effectiveDateTime", "authoredOn", "issued",
              "occurrenceDateTime", "recordedDate", "date"):
        if r.get(k):
            d = _d(r[k])
            return d, d
    return None, None


def _overlaps(r, a, b):
    s, e = _interval(r)
    if s is None and e is None:
        return False
    return (s or date.min) <= b and (e or date.max) >= a


def evaluate(resources, valuesets, period_start, period_end):
    ps, pe = _d(period_start), _d(period_end)
    res = {k: False for k in ("initial-population", "denominator", "denominator-exclusion", "numerator")}
    pat = next((r for r in resources if r.get("resourceType") == "Patient"), None)
    if not pat:
        return res

    def vs(*names):
        out = set()
        for n in names:
            out |= valuesets.get(n, set())
        return out

    birth = _d(pat.get("birthDate"))
    if not birth or (pat.get("gender") or "").lower() != "female":
        return res
    age = pe.year - birth.year - ((pe.month, pe.day) < (birth.month, birth.day))
    if not (52 <= age <= 74):
        return res

    def hit(r, vset, fields=("code",)):
        cs = set()
        for f in fields:
            cs |= _codes(r.get(f))
        return bool(cs & vset)

    def ok(r):
        return r.get("status") not in NOT_ACTIVE

    # ---- initial population: a qualifying visit in the period
    visit_vs = vs("Office Visit", "Annual Wellness Visit",
                  "Preventive Care Services Established Office Visit, 18 and Up",
                  "Preventive Care Services Initial Office Visit, 18 and Up",
                  "Home Healthcare Services", "Telephone Visits", "Virtual Encounter")
    visit = False
    for e in resources:
        if e.get("resourceType") == "Encounter" and e.get("status") == "finished" \
                and hit(e, visit_vs, ("type", "serviceType")) and _overlaps(e, ps, pe):
            visit = True
    if not visit:
        return res
    res["initial-population"] = res["denominator"] = True

    ex = False
    h_enc, h_amb, h_dx = vs("Hospice Encounter"), vs("Hospice Care Ambulatory"), vs("Hospice Diagnosis")
    disch = {(SNOMED, "428361000124107"), (SNOMED, "428371000124100")}
    p_dx, p_enc, p_int = vs("Palliative Care Diagnosis"), vs("Palliative Care Encounter"), vs("Palliative Care Intervention")
    orders = ("Procedure", "ServiceRequest", "Observation", "DeviceRequest", "Task")

    for r in resources:
        t = r.get("resourceType")
        if t == "Patient" or not ok(r):
            continue
        inper = _overlaps(r, ps, pe)
        if not inper:
            continue
        if t == "Encounter":
            if hit(r, h_enc | h_amb, ("type", "serviceType")) or hit(r, p_enc, ("type", "serviceType")):
                ex = True
            if _codes((r.get("hospitalization") or {}).get("dischargeDisposition")) & disch:
                ex = True
        if t in orders:
            if hit(r, h_amb | h_enc | p_int | p_enc):
                ex = True
            if t == "Observation":
                c = _codes(r.get("code"))
                if (LOINC, "71007-9") in c:
                    ex = True
                if (LOINC, "45755-6") in c:
                    vc = _codes(r.get("valueCodeableConcept"))
                    if not vc or (SNOMED, "373066001") in vc:
                        ex = True
        if t == "Condition" and hit(r, h_dx | p_dx):
            ex = True

    # ---- mastectomy (any time on or before end of period)
    bil = vs("Bilateral Mastectomy", "History of bilateral mastectomy")
    left = vs("Unilateral Mastectomy Left", "Status Post Left Mastectomy")
    right = vs("Unilateral Mastectomy Right", "Status Post Right Mastectomy")
    unsp = vs("Unilateral Mastectomy, Unspecified Laterality")
    LQ, RQ = (SNOMED, "7771000"), (SNOMED, "24028007")
    hasL = hasR = False
    for r in resources:
        t = r.get("resourceType")
        if t not in ("Procedure", "Condition", "Observation") or not ok(r):
            continue
        if _codes(r.get("verificationStatus")) & {("http://terminology.hl7.org/CodeSystem/condition-ver-status", "refuted")}:
            continue
        s, e = _interval(r)
        if s and s > pe:
            continue
        cs = _codes(r.get("code"))
        if cs & bil:
            ex = True
        if cs & left:
            hasL = True
        if cs & right:
            hasR = True
        if cs & unsp:
            sites = _codes(r.get("bodySite"))
            if LQ in sites:
                hasL = True
            if RQ in sites:
                hasR = True
    if hasL and hasR:
        ex = True

    if age >= 66:
        fr_enc, fr_dx = vs("Frailty Encounter"), vs("Frailty Diagnosis")
        fr_dev, fr_sym = vs("Frailty Device"), vs("Frailty Symptom")
        frail = False
        for r in resources:
            t = r.get("resourceType")
            if t == "Patient" or not ok(r) or not _overlaps(r, ps, pe):
                continue
            if t == "Encounter" and hit(r, fr_enc, ("type",)):
                frail = True
            elif t in ("Procedure", "ServiceRequest", "Observation", "DeviceRequest") and \
                    hit(r, fr_enc | fr_sym | fr_dev, ("code", "codeCodeableConcept")):
                frail = True
            elif t == "Condition" and hit(r, fr_dx | fr_sym):
                frail = True
            elif t in ("Device", "DeviceUseStatement") and hit(r, fr_dev, ("type", "code")):
                frail = True
        if frail:
            adv, dem = vs("Advanced Illness"), vs("Dementia Medications")
            a0 = date(ps.year - 1, 1, 1)
            for r in resources:
                t = r.get("resourceType")
                if not ok(r):
                    continue
                if t == "Condition" and hit(r, adv) and _overlaps(r, a0, pe):
                    ex = True
                elif t == "Encounter" and _overlaps(r, a0, pe):
                    for d in r.get("diagnosis", []) or []:
                        if _codes(d.get("condition")) & adv:
                            ex = True
                elif t in ("MedicationRequest", "MedicationStatement", "MedicationDispense",
                           "MedicationAdministration") and \
                        _codes(r.get("medicationCodeableConcept")) & dem:
                    s, e = _interval(r)
                    vp = (r.get("dispenseRequest") or {}).get("validityPeriod")
                    if vp:
                        s, e = _d(vp.get("start")) or s, _d(vp.get("end")) or e
                    if s and s <= pe and (e or pe) >= a0:
                        ex = True
        # long-term nursing home
        for r in resources:
            t = r.get("resourceType")
            if t in ("Condition", "Observation", "Procedure") and ok(r):
                nh = (SNOMED, "160734000")
                if nh in _codes(r.get("code")) or nh in _codes(r.get("valueCodeableConcept")):
                    s, _ = _interval(r)
                    if s is None or s <= pe:
                        ex = True
    res["denominator-exclusion"] = ex

    # ---- numerator
    mam = vs("Mammography")
    n0 = date(ps.year - 2, 10, 1)
    num = False
    for r in resources:
        t = r.get("resourceType")
        if t not in ("Procedure", "Observation", "DiagnosticReport"):
            continue
        if r.get("status") not in ("completed", "final", "amended", "corrected", "preliminary"):
            continue
        if not hit(r, mam):
            continue
        s, e = _interval(r)
        d = e or s
        if d and n0 <= d <= pe:
            num = True
    res["numerator"] = num and not ex
    return res
