from datetime import date, timedelta


def _d(s, end=False):
    if not s:
        return None
    try:
        return date(int(s[0:4]), int(s[5:7]) if len(s) >= 7 else (12 if end else 1),
                    int(s[8:10]) if len(s) >= 10 else (31 if end else 1))
    except Exception:
        return None


def _codes(x):
    out = set()
    if isinstance(x, dict):
        for c in x.get("coding", []) or []:
            out.add((c.get("system"), c.get("code")))
    elif isinstance(x, list):
        for y in x:
            out |= _codes(y)
    return out


def _rcodes(r):
    out = set()
    for k in ("code", "type", "medicationCodeableConcept", "serviceType", "category",
              "codeCodeableConcept"):
        if k in r:
            out |= _codes(r[k])
    return out


def _span(r):
    t = r.get("resourceType")
    s = e = None
    for k in ("period", "effectivePeriod", "performedPeriod", "occurrencePeriod"):
        if isinstance(r.get(k), dict):
            s = _d(r[k].get("start"))
            e = _d(r[k].get("end"), True)
            break
    if s is None and e is None:
        for k in ("effectiveDateTime", "performedDateTime", "onsetDateTime", "occurrenceDateTime",
                  "authoredOn", "effectiveInstant", "recordedDate", "issued"):
            if r.get(k):
                s = e = _d(r[k])
                break
    if t == "Condition":
        s = (_d(r.get("onsetDateTime"))
             or (_d(r["onsetPeriod"].get("start")) if isinstance(r.get("onsetPeriod"), dict) else None)
             or _d(r.get("recordedDate")))
        e = _d(r.get("abatementDateTime")) or _d((r.get("abatementPeriod") or {}).get("end"), True)
        if e is None:
            st = {c for _, c in _codes(r.get("clinicalStatus"))}
            if st and not (st & {"active", "recurrence", "relapse"}):
                e = s
    if t == "MedicationRequest" and r.get("authoredOn"):
        s = _d(r["authoredOn"])
        dur = ((r.get("dispenseRequest") or {}).get("expectedSupplyDuration") or {}).get("value")
        e = s + timedelta(days=int(dur)) if dur else s
    return s, e


def _overlap(r, a, b, open_end=True):
    s, e = _span(r)
    if s is None and e is None:
        return False
    if s is None:
        s = e
    if e is None:
        e = date.max if open_end else s
    return s <= b and e >= a


def evaluate(resources, valuesets, period_start, period_end):
    ps, pe = _d(period_start), _d(period_end, True)

    def vs(n):
        return valuesets.get(n, set())

    res = {"initial-population": False, "denominator": False,
           "denominator-exclusion": False, "numerator": False}
    pat = next((r for r in resources if r.get("resourceType") == "Patient"), None)
    if not pat:
        return res
    bd = _d(pat.get("birthDate"))
    if not bd:
        return res
    age = pe.year - bd.year - ((pe.month, pe.day) < (bd.month, bd.day))
    if not (18 <= age <= 85):
        return res

    def of(types, names, a=None, b=None, open_end=True, pred=None):
        codes = set()
        for n in names:
            codes |= vs(n)
        for r in resources:
            if r.get("resourceType") not in types:
                continue
            if not (_rcodes(r) & codes):
                continue
            if pred and not pred(r):
                continue
            if a is None or _overlap(r, a, b, open_end):
                yield r

    def any_(*a, **k):
        return any(True for _ in of(*a, **k))

    visit_names = ["Office Visit", "Annual Wellness Visit", "Home Healthcare Services",
                   "Telephone Visits", "Virtual Encounter",
                   "Preventive Care Services Established Office Visit, 18 and Up",
                   "Preventive Care Services Initial Office Visit, 18 and Up"]
    visit = any_({"Encounter"}, visit_names, ps, pe, False,
                 lambda r: r.get("status", "finished") == "finished")
    sixm = ps + timedelta(days=180)

    def htn(r):
        s, e = _span(r)
        if s is None or s > sixm:
            return False
        return e is None or e >= ps
    ht = any_({"Condition"}, ["Essential Hypertension"], pred=htn)
    if not (visit and ht):
        return res
    res["initial-population"] = res["denominator"] = True

    ex = False
    ALL = {"Encounter", "Condition", "Procedure", "ServiceRequest", "Observation", "DeviceRequest",
           "MedicationRequest", "Device", "Task", "CarePlan", "Communication"}
    if any_(ALL, ["Hospice Encounter", "Hospice Care Ambulatory", "Hospice Diagnosis"], ps, pe):
        ex = True
    hosp = {("http://snomed.info/sct", "428371000124100"), ("http://snomed.info/sct", "428361000124107")}
    yes = ("http://snomed.info/sct", "373066001")
    for r in resources:
        if r.get("resourceType") == "Encounter" and _overlap(r, ps, pe, False):
            if _codes((r.get("hospitalization") or {}).get("dischargeDisposition")) & hosp:
                ex = True
        if r.get("resourceType") == "Observation" and ("http://loinc.org", "45755-6") in _rcodes(r) \
                and _overlap(r, ps, pe, False):
            if yes in _codes(r.get("valueCodeableConcept")):
                ex = True
        if r.get("resourceType") == "Observation" and ("http://loinc.org", "71007-9") in _rcodes(r) \
                and _overlap(r, ps, pe, False):
            ex = True
    for names, types in ((["End Stage Renal Disease", "Chronic Kidney Disease, Stage 5",
                           "Kidney Transplant Recipient"], {"Condition"}),
                         (["Dialysis Services", "Kidney Transplant"], {"Procedure", "ServiceRequest"}),
                         (["ESRD Monthly Outpatient Services"], {"Encounter", "Procedure"})):
        if any_(types, names, date.min, pe):
            ex = True
    if any_({"Condition"}, ["Pregnancy"], ps, pe):
        ex = True
    if any_(ALL, ["Palliative Care Diagnosis", "Palliative Care Encounter",
                  "Palliative Care Intervention"], ps, pe):
        ex = True
    frail = any_(ALL, ["Frailty Device", "Frailty Diagnosis", "Frailty Encounter", "Frailty Symptom"], ps, pe)
    if age >= 81 and frail:
        ex = True
    if 66 <= age <= 80 and frail:
        py = date(ps.year - 1, ps.month, ps.day)
        if any_({"Condition", "Encounter"}, ["Advanced Illness"], py, pe) or \
                any_({"MedicationRequest", "MedicationStatement", "MedicationDispense"},
                     ["Dementia Medications"], py, pe):
            ex = True
    if age >= 66:
        nh = ("http://snomed.info/sct", "160734000")
        for r in resources:
            t = r.get("resourceType")
            if t in ("Condition", "Observation", "Procedure"):
                if nh in _rcodes(r) or nh in _codes(r.get("valueCodeableConcept")):
                    s, _e = _span(r)
                    if s is None or s <= pe:
                        ex = True
    res["denominator-exclusion"] = ex
    if ex:
        return res

    bad = []
    for r in resources:
        if r.get("resourceType") == "Encounter":
            c = _rcodes(r)
            cls = (r.get("class") or {}).get("code")
            if c & (vs("Encounter Inpatient") | vs("Emergency Department Evaluation and Management Visit")) \
                    or cls in ("EMER", "IMP", "ACUTE", "NONAC"):
                bad.append(r)
    SYS, DIA = ("http://loinc.org", "8480-6"), ("http://loinc.org", "8462-4")
    byday = {}
    for r in resources:
        if r.get("resourceType") != "Observation":
            continue
        if r.get("status") not in ("final", "amended", "corrected"):
            continue
        day = (_d(r.get("effectiveDateTime")) or _d((r.get("effectivePeriod") or {}).get("start"))
               or _d(r.get("effectiveInstant")))
        if not day or not (ps <= day <= pe):
            continue
        eid = (r.get("encounter") or {}).get("reference", "").split("/")[-1]
        if eid and any(b.get("id") == eid for b in bad):
            continue
        if any(_overlap(b, day, day, False) for b in bad):
            continue
        sv = dv = None
        comps = [(c.get("code"), c) for c in r.get("component", [])] + [(r.get("code"), r)]
        for code, o in comps:
            q = o.get("valueQuantity")
            if not q or q.get("value") is None:
                continue
            cs = _codes(code)
            if SYS in cs:
                sv = q["value"]
            elif DIA in cs:
                dv = q["value"]
        if sv is None and dv is None:
            continue
        ent = byday.setdefault(day, {"s": [], "d": []})
        if sv is not None:
            ent["s"].append(sv)
        if dv is not None:
            ent["d"].append(dv)
    for day in sorted(byday, reverse=True):
        ent = byday[day]
        if ent["s"] and ent["d"]:
            res["numerator"] = min(ent["s"]) < 140 and min(ent["d"]) < 90
            break
    return res
