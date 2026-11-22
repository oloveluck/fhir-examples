BAD_STATUS = {"entered-in-error", "cancelled", "draft", "revoked", "unknown", "not-done"}
NH = ("http://snomed.info/sct", "160734000")
SYS = ("http://loinc.org", "8480-6")
DIA = ("http://loinc.org", "8462-4")
HOSP_DISP = {("http://snomed.info/sct", "428371000124100"),
             ("http://snomed.info/sct", "428361000124107")}


def _d(s):
    return s[:10] if isinstance(s, str) and len(s) >= 10 else None


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


def _span(r, n):
    v = r.get(n + "DateTime") or r.get(n + "Instant") or r.get(n + "Date")
    if v:
        return _d(v), _d(v)
    p = r.get(n + "Period")
    if p:
        return _d(p.get("start")), _d(p.get("end"))
    return None, None


def _overlaps(s, e, lo, hi):
    if s is None and e is None:
        return False
    if s is not None and s > hi:
        return False
    if e is not None and e < lo:
        return False
    return True


def evaluate(resources, valuesets, period_start, period_end):
    ps, pe = period_start[:10], period_end[:10]
    prior_start = "%04d%s" % (int(ps[:4]) - 1, ps[4:])
    V = lambda n: valuesets.get(n, set())
    by = {}
    for r in resources:
        by.setdefault(r.get("resourceType"), []).append(r)
    res = {"initial-population": False, "denominator": False,
           "denominator-exclusion": False, "numerator": False}

    pat = (by.get("Patient") or [{}])[0]
    bd = pat.get("birthDate")
    if not bd:
        return res
    by_ = int(bd[:4])
    bm = int(bd[5:7]) if len(bd) >= 7 else 1
    bdd = int(bd[8:10]) if len(bd) >= 10 else 1
    ey, em, ed = int(pe[:4]), int(pe[5:7]), int(pe[8:10])
    age = ey - by_ - ((em, ed) < (bm, bdd))

    # ---- encounters
    encs = {}
    for e in by.get("Encounter", []):
        if e.get("status") in ("cancelled", "entered-in-error", "planned", "draft"):
            continue
        p = e.get("period") or {}
        s = _d(p.get("start"))
        en = _d(p.get("end")) or s
        encs[e.get("id")] = (e, s, en)

    def enc_codes(e):
        return _codes(e.get("type")) | _codes(e.get("serviceType"))

    visit_codes = set()
    for n in ("Office Visit", "Annual Wellness Visit",
              "Preventive Care Services Established Office Visit, 18 and Up",
              "Preventive Care Services Initial Office Visit, 18 and Up",
              "Telephone Visits", "Virtual Encounter", "Home Healthcare Services"):
        visit_codes |= V(n)
    has_visit = any(e.get("status") == "finished" and enc_codes(e) & visit_codes
                    and _overlaps(s, en, ps, pe) for e, s, en in encs.values())

    # ---- conditions
    def cond_ok(c):
        return not any(x[1] in ("entered-in-error", "refuted")
                       for x in _codes(c.get("verificationStatus")))

    def cond_span(c):
        s, _ = _span(c, "onset")
        if s is None:
            s = _d(c.get("recordedDate"))
        _, a = _span(c, "abatement")
        return s, a

    conds = [c for c in by.get("Condition", []) if cond_ok(c)]
    mid = "%s-06-30" % ps[:4]
    has_htn = False
    for c in conds:
        if _in(c.get("code"), V("Essential Hypertension")):
            s, a = cond_span(c)
            if s is not None and s <= mid and (a is None or a >= ps):
                has_htn = True

    if not (18 <= age <= 85 and has_visit and has_htn):
        return res
    res["initial-population"] = res["denominator"] = True

    # ---- exclusions
    def cond_overlap(vsname, lo=ps, hi=pe):
        for c in conds:
            if _in(c.get("code"), V(vsname)):
                s, a = cond_span(c)
                if s is not None and _overlaps(s, a, lo, hi):
                    return True
        return False

    def enc_overlap(vsname):
        return any(enc_codes(e) & V(vsname) and _overlaps(s, en, ps, pe)
                   for e, s, en in encs.values())

    def proc_dates(p):
        s, e = _span(p, "performed")
        if s is None:
            for x in p.get("extension", []) or []:
                if x.get("valueDateTime"):
                    s = e = _d(x["valueDateTime"])
        return s, e

    def proc_overlap(vsname, before_ok=False):
        for p in by.get("Procedure", []):
            if p.get("status") in BAD_STATUS or not _in(p.get("code"), V(vsname)):
                continue
            s, e = proc_dates(p)
            if s is None:
                continue
            if before_ok:
                if s <= pe:
                    return True
            elif _overlaps(s, e, ps, pe):
                return True
        return False

    def sr_overlap(vsname):
        for r in by.get("ServiceRequest", []):
            if r.get("status") in BAD_STATUS or r.get("doNotPerform"):
                continue
            if _in(r.get("code"), V(vsname)):
                d = _d(r.get("authoredOn"))
                s, e = _span(r, "occurrence")
                if (d and ps <= d <= pe) or _overlaps(s, e, ps, pe):
                    return True
        return False

    def obs_overlap(pred):
        for o in by.get("Observation", []):
            if o.get("status") in BAD_STATUS or not pred(o):
                continue
            s, e = _span(o, "effective")
            if s is None:
                s = e = _d(o.get("issued"))
            if s is not None and _overlaps(s, e, ps, pe):
                return True
        return False

    excl = False
    for e, s, en in encs.values():
        dd = _codes((e.get("hospitalization") or {}).get("dischargeDisposition"))
        if dd & HOSP_DISP and _overlaps(s, en, ps, pe):
            excl = True
    if (enc_overlap("Hospice Encounter") or enc_overlap("Hospice Care Ambulatory")
            or cond_overlap("Hospice Diagnosis") or sr_overlap("Hospice Care Ambulatory")
            or proc_overlap("Hospice Care Ambulatory")
            or obs_overlap(lambda o: _in(o.get("code"), V("Hospice Care Ambulatory")))):
        excl = True
    # palliative
    if (cond_overlap("Palliative Care Diagnosis") or enc_overlap("Palliative Care Encounter")
            or proc_overlap("Palliative Care Intervention") or sr_overlap("Palliative Care Intervention")
            or obs_overlap(lambda o: _in(o.get("code"), V("Palliative Care Intervention"))
                           or _in(o.get("valueCodeableConcept"), V("Palliative Care Diagnosis")))):
        excl = True
    # ESRD / dialysis / transplant
    for c in conds:
        if _codes(c.get("code")) & (V("End Stage Renal Disease") | V("Chronic Kidney Disease, Stage 5")
                                    | V("Kidney Transplant Recipient")):
            s, a = cond_span(c)
            if s is not None and s <= pe:
                excl = True
    if (proc_overlap("Dialysis Services", True) or proc_overlap("Kidney Transplant", True)
            or proc_overlap("ESRD Monthly Outpatient Services", True)):
        excl = True
    for e, s, en in encs.values():
        if enc_codes(e) & (V("ESRD Monthly Outpatient Services") | V("Dialysis Services")) and s and s <= pe:
            excl = True
    if cond_overlap("Pregnancy"):
        excl = True

    # frailty
    frail = False
    if age >= 66:
        if cond_overlap("Frailty Diagnosis") or cond_overlap("Frailty Symptom") or enc_overlap("Frailty Encounter"):
            frail = True
        for r in by.get("DeviceRequest", []):
            if r.get("status") in BAD_STATUS or r.get("doNotPerform"):
                continue
            if any(x.get("valueBoolean") for x in r.get("modifierExtension", []) or []
                   if "doNotPerform" in x.get("url", "")):
                continue
            if _in(r.get("codeCodeableConcept"), V("Frailty Device")):
                d = _d(r.get("authoredOn"))
                s, e = _span(r, "occurrence")
                if (d and ps <= d <= pe) or _overlaps(s, e, ps, pe):
                    frail = True
        if obs_overlap(lambda o: _in(o.get("code"), V("Frailty Symptom") | V("Frailty Diagnosis") | V("Frailty Device"))
                       or _in(o.get("valueCodeableConcept"), V("Frailty Device") | V("Frailty Symptom"))):
            frail = True
        if proc_overlap("Frailty Encounter"):
            frail = True
    if frail:
        if age >= 81:
            excl = True
        else:
            adv = cond_overlap("Advanced Illness", prior_start, pe)
            if not adv:
                for m in by.get("MedicationRequest", []):
                    if m.get("status") in BAD_STATUS or m.get("doNotPerform"):
                        continue
                    if _in(m.get("medicationCodeableConcept"), V("Dementia Medications")):
                        d = _d(m.get("authoredOn"))
                        if d and prior_start <= d <= pe:
                            adv = True
            if adv:
                excl = True

    # nursing home
    if age >= 66:
        for o in by.get("Observation", []):
            if o.get("status") in BAD_STATUS:
                continue
            if NH in _codes(o.get("valueCodeableConcept")) or NH in _codes(o.get("code")):
                s, e = _span(o, "effective")
                if s is None or s <= pe:
                    excl = True
        for c in conds:
            if NH in _codes(c.get("code")):
                s, a = cond_span(c)
                if s is None or s <= pe:
                    excl = True

    res["denominator-exclusion"] = excl
    if excl:
        return res

    # ---- numerator
    def bad_setting(o):
        ref = (o.get("encounter") or {}).get("reference") or ""
        eid = ref.split("/")[-1] if ref else None
        if eid and eid in encs:
            cands = [encs[eid]]
        elif eid:
            cands = []
        else:
            od = _span(o, "effective")[0]
            cands = [x for x in encs.values() if od and x[1] and x[1] <= od <= (x[2] or x[1])]
        for e, s, en in cands:
            cls = (e.get("class") or {}).get("code")
            if cls in ("IMP", "ACUTE", "NONAC", "EMER") or \
                    enc_codes(e) & (V("Encounter Inpatient") | V("Emergency Department Evaluation and Management Visit")):
                return True
        return False

    readings = {}
    for o in by.get("Observation", []):
        if o.get("status") not in ("final", "amended", "corrected"):
            continue
        day = _span(o, "effective")[0] or _d(o.get("issued"))
        if not day or not (ps <= day <= pe) or bad_setting(o):
            continue
        sv = dv = None
        items = [(o.get("code"), o.get("valueQuantity"))]
        for c in o.get("component", []) or []:
            items.append((c.get("code"), c.get("valueQuantity")))
        for code, q in items:
            if not isinstance(q, dict) or q.get("value") is None or q.get("comparator"):
                continue
            cs = _codes(code)
            if SYS in cs:
                sv = q["value"]
            elif DIA in cs:
                dv = q["value"]
        if sv is not None or dv is not None:
            ent = readings.setdefault(day, ([], []))
            if sv is not None:
                ent[0].append(sv)
            if dv is not None:
                ent[1].append(dv)
    if readings:
        s, d = readings[max(readings)]
        if s and d:
            res["numerator"] = min(s) < 140 and min(d) < 90
    return res
