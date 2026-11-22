BAD = {"entered-in-error", "cancelled", "not-done", "refuted", "draft", "revoked"}
HOSP_DISCH = {("http://snomed.info/sct", "428371000124100"), ("http://snomed.info/sct", "428361000124107")}
GMI = ("http://loinc.org", "97506-0")
YES = ("http://snomed.info/sct", "373066001")
NH = ("http://snomed.info/sct", "160734000")
HOSP_MDS = ("http://loinc.org", "45755-6")
FACIT = ("http://loinc.org", "71007-9")


def codes_in(cc):
    out = set()
    if isinstance(cc, list):
        for c in cc:
            out |= codes_in(c)
    elif isinstance(cc, dict):
        for c in cc.get("coding", []) or []:
            out.add((c.get("system"), c.get("code")))
    return out


def rcodes(r):
    out = set()
    for k in ("code", "type", "medicationCodeableConcept", "codeCodeableConcept", "category",
              "serviceType", "serviceCategory", "reasonCode"):
        if k in r:
            out |= codes_in(r[k])
    return out


def d(s):
    return s[:10] if isinstance(s, str) and s else None


def interval(r):
    t = r.get("resourceType")
    s = e = None
    if t == "Encounter":
        p = r.get("period") or {}
        s, e = d(p.get("start")), d(p.get("end"))
    elif t == "Condition":
        s = d(r.get("onsetDateTime")) or d((r.get("onsetPeriod") or {}).get("start")) or d(r.get("recordedDate"))
        e = d(r.get("abatementDateTime")) or d((r.get("abatementPeriod") or {}).get("end"))
    elif t == "Observation":
        s = d(r.get("effectiveDateTime")) or d((r.get("effectivePeriod") or {}).get("start")) or d(r.get("effectiveInstant")) or d(r.get("issued"))
        e = d(r.get("effectiveDateTime")) or d((r.get("effectivePeriod") or {}).get("end")) or s
    elif t == "Procedure":
        s = d(r.get("performedDateTime")) or d((r.get("performedPeriod") or {}).get("start"))
        e = d(r.get("performedDateTime")) or d((r.get("performedPeriod") or {}).get("end"))
    else:
        s = (d(r.get("authoredOn")) or d(r.get("occurrenceDateTime"))
             or d((r.get("occurrencePeriod") or {}).get("start")) or d(r.get("recordedDate")) or d(r.get("date")))
        e = d((r.get("occurrencePeriod") or {}).get("end"))
    return s, e


def overlaps(r, a, b, open_end=True):
    s, e = interval(r)
    if s is None and e is None:
        return False
    if s is None:
        s = e
    if e is None:
        e = "9999-12-31" if open_end else s
    return s <= b and e >= a


def ok(r):
    if r.get("status") in BAD:
        return False
    if r.get("doNotPerform") is True:
        return False
    for m in r.get("modifierExtension", []) or []:
        if "doNotPerform" in m.get("url", "") and m.get("valueBoolean") is True:
            return False
    if any(c[1] in ("entered-in-error", "refuted") for c in codes_in(r.get("verificationStatus"))):
        return False
    return True


def evaluate(resources, valuesets, period_start, period_end):
    ps, pe = period_start, period_end

    def V(*names):
        return set().union(*[valuesets.get(n, set()) for n in names])

    pat = next((r for r in resources if r.get("resourceType") == "Patient"), {})
    res = [r for r in resources if r.get("resourceType") != "Patient" and ok(r)]
    prior = str(int(ps[:4]) - 1) + ps[4:]

    def find(vs, a, b, types=None, valcheck=False):
        out = []
        for r in res:
            if types and r.get("resourceType") not in types:
                continue
            cs = rcodes(r)
            if valcheck:
                cs = cs | codes_in(r.get("valueCodeableConcept"))
            if cs & vs and overlaps(r, a, b):
                out.append(r)
        return out

    bd = pat.get("birthDate")
    age = None
    if bd:
        y, m, dd = int(bd[:4]), int(bd[5:7]), int(bd[8:10])
        ey, em, ed = int(pe[:4]), int(pe[5:7]), int(pe[8:10])
        age = ey - y - ((em, ed) < (m, dd))
    out = {"initial-population": False, "denominator": False,
           "denominator-exclusion": False, "numerator": False}
    if age is None or not (18 <= age <= 75):
        return out

    dm = False
    for r in res:
        if r.get("resourceType") != "Condition":
            continue
        if rcodes(r) & V("Diabetes") and overlaps(r, ps, pe):
            cs = {c[1] for c in codes_in(r.get("clinicalStatus"))}
            if cs & {"inactive", "resolved", "remission"} and not interval(r)[1]:
                continue
            dm = True
    visit_vs = V("Office Visit", "Annual Wellness Visit",
                 "Preventive Care Services Established Office Visit, 18 and Up",
                 "Preventive Care Services Initial Office Visit, 18 and Up",
                 "Home Healthcare Services", "Telephone Visits", "Virtual Encounter")
    visit = any(r.get("status", "finished") == "finished" for r in
                find(visit_vs, ps, pe, {"Encounter"}))
    if not (dm and visit):
        return out
    out["initial-population"] = out["denominator"] = True

    excl = False
    if find(V("Hospice Encounter"), ps, pe, {"Encounter"}):
        excl = True
    if find(V("Hospice Care Ambulatory"), ps, pe):
        excl = True
    if find(V("Hospice Diagnosis"), ps, pe, {"Condition"}):
        excl = True
    for r in res:
        if r.get("resourceType") == "Encounter" and overlaps(r, ps, pe, False):
            if codes_in((r.get("hospitalization") or {}).get("dischargeDisposition")) & HOSP_DISCH:
                excl = True
        if r.get("resourceType") == "Observation" and overlaps(r, ps, pe) \
                and YES in codes_in(r.get("valueCodeableConcept")):
            cs = rcodes(r)
            if HOSP_MDS in cs or FACIT in cs:
                excl = True
    if find(V("Palliative Care Encounter"), ps, pe, {"Encounter"}):
        excl = True
    if find(V("Palliative Care Diagnosis"), ps, pe, {"Condition"}):
        excl = True
    if find(V("Palliative Care Intervention"), ps, pe, {"Procedure", "ServiceRequest", "Observation"}):
        excl = True
    if age >= 66 and not excl:
        for r in res:
            if NH in rcodes(r) | codes_in(r.get("valueCodeableConcept")):
                s, e = interval(r)
                if s is None or s <= pe:
                    excl = True
        fvs = V("Frailty Device", "Frailty Diagnosis", "Frailty Encounter", "Frailty Symptom")
        if find(fvs, ps, pe, None, valcheck=True):
            adv = find(V("Advanced Illness"), prior, pe, {"Condition", "Encounter", "Procedure", "Observation"})
            dem = find(V("Dementia Medications"), prior, pe,
                       {"MedicationRequest", "MedicationStatement", "MedicationDispense", "MedicationAdministration"})
            if adv or dem:
                excl = True
    if excl:
        out["denominator-exclusion"] = True
        return out

    tests = V("HbA1c Laboratory Test") | {GMI}
    byday = {}
    for r in res:
        if r.get("resourceType") != "Observation" or r.get("status") not in ("final", "amended", "corrected"):
            continue
        if not (rcodes(r) & tests):
            continue
        s, e = interval(r)
        day = e or s
        if not day or not (ps <= day <= pe):
            continue
        q = r.get("valueQuantity")
        if not q or q.get("value") is None:
            continue
        u = q.get("unit") or q.get("code")
        if u not in (None, "%"):
            continue
        byday.setdefault(day, []).append(float(q["value"]))
    if not byday:
        out["numerator"] = True
    else:
        out["numerator"] = min(byday[max(byday)]) > 9.0
    return out
