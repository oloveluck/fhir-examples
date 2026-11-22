from datetime import date


def _d(s):
    if not s:
        return None
    try:
        return date.fromisoformat(str(s)[:10])
    except Exception:
        return None


def _codes(cc):
    out = set()
    if isinstance(cc, dict):
        for c in cc.get("coding", []) or []:
            out.add((c.get("system"), c.get("code")))
    elif isinstance(cc, list):
        for x in cc:
            out |= _codes(x)
    return out


def _in(cc, vs):
    return bool(_codes(cc) & vs)


def _rcodes(r):
    out = set()
    for k in ("code", "type", "medicationCodeableConcept", "codeCodeableConcept", "serviceType"):
        if k in r:
            out |= _codes(r[k])
    return out


def _interval(r):
    t = r.get("resourceType")
    if t == "Condition":
        s = (_d(r.get("onsetDateTime")) or _d((r.get("onsetPeriod") or {}).get("start"))
             or _d(r.get("recordedDate")))
        e = _d(r.get("abatementDateTime")) or _d((r.get("abatementPeriod") or {}).get("end"))
        return s, e
    for k in ("performedPeriod", "period", "effectivePeriod", "occurrencePeriod"):
        if k in r and isinstance(r[k], dict):
            return _d(r[k].get("start")), _d(r[k].get("end"))
    for k in ("performedDateTime", "effectiveDateTime", "occurrenceDateTime", "effectiveInstant",
              "authoredOn", "issued", "recordedDate", "date"):
        if r.get(k):
            d = _d(r[k])
            return d, d
    return None, None


def _overlaps(r, a, b):
    s, e = _interval(r)
    if s is None and e is None:
        return False
    if s is not None and s > b:
        return False
    if e is not None and e < a:
        return False
    return True


def _bad(r):
    if r.get("status") in ("entered-in-error", "cancelled", "draft", "revoked", "refused", "not-done"):
        return True
    if r.get("doNotPerform") is True:
        return True
    for e in r.get("modifierExtension", []) or []:
        if str(e.get("url", "")).endswith("doNotPerform") and e.get("valueBoolean"):
            return True
    if any(c in ("entered-in-error", "refuted") for _, c in _codes(r.get("verificationStatus"))):
        return True
    return False


def _overlaps_day(e, d):
    s, en = _interval(e)
    if s is None:
        return False
    return s <= d <= (en or s)


def evaluate(resources, valuesets, period_start, period_end):
    A, B = _d(period_start), _d(period_end)

    def V(n):
        return valuesets.get(n, set())

    res = {"initial-population": False, "denominator": False,
           "denominator-exclusion": False, "numerator": False}
    pat = next((r for r in resources if r.get("resourceType") == "Patient"), None)
    if not pat:
        return res
    bd = _d(pat.get("birthDate"))
    if not bd:
        return res
    age = B.year - bd.year - ((B.month, B.day) < (bd.month, bd.day))
    if not (18 <= age <= 85):
        return res

    by = {}
    for r in resources:
        by.setdefault(r.get("resourceType"), []).append(r)
    enc = by.get("Encounter", [])

    visit_vs = set()
    for n in ("Office Visit", "Annual Wellness Visit",
              "Preventive Care Services Established Office Visit, 18 and Up",
              "Preventive Care Services Initial Office Visit, 18 and Up", "Home Healthcare Services",
              "Telephone Visits", "Virtual Encounter"):
        visit_vs |= V(n)
    if not any(e.get("status") == "finished" and _in(e.get("type"), visit_vs) and _overlaps(e, A, B)
               for e in enc):
        return res

    m = A.month + 6
    y = A.year + (m - 1) // 12
    m = (m - 1) % 12 + 1
    cutoff = date(y, m, A.day)  # exclusive
    htn = False
    for c in by.get("Condition", []):
        if _bad(c) or not _in(c.get("code"), V("Essential Hypertension")):
            continue
        s, e = _interval(c)
        if s is not None and s >= cutoff:
            continue
        if e is not None and e < A:
            continue
        htn = True
    if not htn:
        return res
    res["initial-population"] = res["denominator"] = True

    def conds(vsnames, a, b):
        vs = set()
        for n in vsnames:
            vs |= V(n)
        out = []
        for c in by.get("Condition", []):
            if _bad(c) or not _in(c.get("code"), vs):
                continue
            s, e = _interval(c)
            if s is not None and s > b:
                continue
            if e is not None and e < a:
                continue
            out.append(c)
        return out

    def anyres(types, vsnames, a, b):
        vs = set()
        for n in vsnames:
            vs |= V(n)
        for t in types:
            for r in by.get(t, []):
                if _bad(r) or not (_rcodes(r) & vs):
                    continue
                if _overlaps(r, a, b):
                    return True
        return False

    ex = False
    # hospice
    if anyres(["Encounter", "Procedure", "ServiceRequest", "Observation", "Task", "CarePlan"],
              ["Hospice Encounter", "Hospice Care Ambulatory"], A, B):
        ex = True
    if conds(["Hospice Diagnosis"], A, B):
        ex = True
    hosp_disp = {("http://snomed.info/sct", "428371000124100"), ("http://snomed.info/sct", "428361000124107")}
    for e in enc:
        if _bad(e) or not _overlaps(e, A, B):
            continue
        if _codes((e.get("hospitalization") or {}).get("dischargeDisposition")) & hosp_disp:
            ex = True
    for o in by.get("Observation", []):
        if ("http://loinc.org", "45755-6") in _codes(o.get("code")) and not _bad(o) and _overlaps(o, A, B):
            if ("http://snomed.info/sct", "373066001") in _codes(o.get("valueCodeableConcept")):
                ex = True
    # ESRD / dialysis / transplant, before or during the period
    FAR = date(1900, 1, 1)
    if conds(["End Stage Renal Disease", "Chronic Kidney Disease, Stage 5", "Kidney Transplant Recipient"], FAR, B):
        ex = True
    if anyres(["Procedure", "Encounter", "ServiceRequest", "Observation"],
              ["Dialysis Services", "Kidney Transplant", "ESRD Monthly Outpatient Services"], FAR, B):
        ex = True
    # pregnancy
    if conds(["Pregnancy"], A, B):
        ex = True
    # palliative care
    if conds(["Palliative Care Diagnosis"], A, B):
        ex = True
    if anyres(["Encounter", "Procedure", "ServiceRequest", "Observation", "Task", "CarePlan"],
              ["Palliative Care Encounter", "Palliative Care Intervention", "Palliative Care Diagnosis"], A, B):
        ex = True
    for o in by.get("Observation", []):
        if ("http://loinc.org", "71007-9") in _codes(o.get("code")) and not _bad(o) and _overlaps(o, A, B):
            ex = True
    if age >= 66:
        # nursing home
        NH = ("http://snomed.info/sct", "160734000")
        for o in by.get("Observation", []):
            if not _bad(o) and ("http://loinc.org", "71802-3") in _codes(o.get("code")):
                s, _ = _interval(o)
                if (s is None or s <= B) and NH in _codes(o.get("valueCodeableConcept")):
                    ex = True
        for c in by.get("Condition", []):
            if not _bad(c) and NH in _codes(c.get("code")):
                s, _ = _interval(c)
                if s is None or s <= B:
                    ex = True
        # frailty
        fr = False
        if conds(["Frailty Diagnosis", "Frailty Symptom"], A, B):
            fr = True
        if anyres(["Encounter", "Procedure", "ServiceRequest", "Observation"],
                  ["Frailty Encounter", "Frailty Symptom", "Frailty Diagnosis"], A, B):
            fr = True
        fdev = V("Frailty Device")
        for t in ("DeviceRequest", "DeviceUseStatement", "Procedure", "ServiceRequest"):
            for r in by.get(t, []):
                if _bad(r):
                    continue
                cs = _codes(r.get("codeCodeableConcept")) | _codes(r.get("code"))
                dv = r.get("device")
                if isinstance(dv, dict):
                    cs |= _codes(dv)
                if cs & fdev and _overlaps(r, A, B):
                    fr = True
        for o in by.get("Observation", []):
            if not _bad(o) and _overlaps(o, A, B) and (
                    _codes(o.get("code")) & fdev or _codes(o.get("valueCodeableConcept")) & fdev):
                fr = True
        if fr:
            if age >= 81:
                ex = True
            else:
                a1 = date(A.year - 1, A.month, A.day)
                adv = bool(conds(["Advanced Illness"], a1, B)) or anyres(["Encounter"], ["Advanced Illness"], a1, B)
                if not adv:
                    dm = V("Dementia Medications")
                    meds = (by.get("MedicationRequest", []) + by.get("MedicationStatement", [])
                            + by.get("MedicationDispense", []))
                    for mr in meds:
                        if _bad(mr) or mr.get("status") == "stopped":
                            continue
                        if not (_codes(mr.get("medicationCodeableConcept")) & dm):
                            continue
                        d = _d(mr.get("authoredOn") or mr.get("whenHandedOver") or mr.get("effectiveDateTime"))
                        if d is None:
                            d = _interval(mr)[0]
                        if d is None:
                            continue
                        if a1 <= d <= B:
                            adv = True
                        elif d < a1:
                            dur = ((mr.get("dispenseRequest") or {}).get("expectedSupplyDuration") or {}).get("value")
                            if dur and d.toordinal() + int(dur) >= a1.toordinal():
                                adv = True
                if adv:
                    ex = True
    if ex:
        res["denominator-exclusion"] = True
        return res

    # numerator
    edvs = V("Emergency Department Evaluation and Management Visit")
    ipvs = V("Encounter Inpatient")
    extra = {("http://snomed.info/sct", "4525004"), ("http://snomed.info/sct", "32485007")}

    def is_ed_ip(e):
        if (e.get("class") or {}).get("code") in ("EMER", "IMP", "ACUTE", "NONAC"):
            return True
        return _in(e.get("type"), edvs | ipvs | extra)

    edip = [e for e in enc if not _bad(e) and is_ed_ip(e)]
    edip_ids = {e.get("id") for e in edip}

    SYS, DIA = ("http://loinc.org", "8480-6"), ("http://loinc.org", "8462-4")
    readings = {}

    def val(x):
        q = x.get("valueQuantity")
        if isinstance(q, dict) and isinstance(q.get("value"), (int, float)):
            return q["value"]
        return None

    for o in by.get("Observation", []):
        if o.get("status") not in ("final", "amended", "corrected") or _bad(o):
            continue
        s, e = _interval(o)
        d = e or s
        if d is None or not (A <= d <= B):
            continue
        ref = (o.get("encounter") or {}).get("reference", "")
        if ref and ref.split("/")[-1] in edip_ids:
            continue
        if any(_overlaps_day(x, d) for x in edip):
            continue
        for it in [o] + list(o.get("component", []) or []):
            cs = _codes(it.get("code"))
            v = val(it)
            if v is None:
                continue
            ent = readings.setdefault(d, ([], []))
            if SYS in cs:
                ent[0].append(v)
            elif DIA in cs:
                ent[1].append(v)
    for d in sorted(readings, reverse=True):
        sy, di = readings[d]
        if sy and di:
            res["numerator"] = min(sy) < 140 and min(di) < 90
            break
    return res
