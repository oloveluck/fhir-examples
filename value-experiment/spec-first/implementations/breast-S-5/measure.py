from datetime import date, timedelta

SNOMED = "http://snomed.info/sct"
HOSPICE_DISCH = {(SNOMED, "428371000124100"), (SNOMED, "428361000124107")}
LEFT = {(SNOMED, "7771000")}
RIGHT = {(SNOMED, "24028007")}
SURVEY = ("http://terminology.hl7.org/CodeSystem/observation-category", "survey")
UNITS_DAYS = {"d": 1, "day": 1, "days": 1, "wk": 7, "week": 7, "weeks": 7,
              "mo": 30, "month": 30, "months": 30, "a": 365, "year": 365}
UNITS_PERIOD = {"s": 1 / 86400, "min": 1 / 1440, "h": 1 / 24, "d": 1, "wk": 7, "mo": 30, "a": 365}


def D(s):
    if not s or not isinstance(s, str):
        return None
    try:
        return date(int(s[:4]), int(s[5:7]) if len(s) >= 7 else 1, int(s[8:10]) if len(s) >= 10 else 1)
    except ValueError:
        return None


def codes(cc):
    out = set()
    if isinstance(cc, dict):
        for c in cc.get("coding", []) or []:
            if c.get("code") is not None:
                out.add((c.get("system"), c.get("code")))
    return out


def anyin(cc, vs):
    return bool(codes(cc) & vs)


def interval(res, base):
    """normalized (low, high) of a choice element; None if absent."""
    v = res.get(base + "DateTime", res.get(base + "Instant", res.get(base + "Date")))
    if v is not None:
        d = D(v)
        return (d, d) if d else None
    p = res.get(base + "Period")
    if isinstance(p, dict):
        return (D(p.get("start")), D(p.get("end")))
    return None


def ends_by(iv, end):
    return iv is not None and iv[1] is not None and iv[1] <= end


def overlaps(iv, s, e):
    if iv is None:
        return False
    lo, hi = iv
    return (lo is None or lo <= e) and (hi is None or hi >= s)


def during(iv, s, e):
    return iv is not None and iv[0] is not None and iv[1] is not None and iv[0] >= s and iv[1] <= e


def prevalence(c):
    on = interval(c, "onset")
    if on is None or on[0] is None:
        return None
    ab = interval(c, "abatement")
    return (on[0], ab[1] if ab else None)


def evaluate(resources, valuesets, period_start, period_end):
    S, E = D(period_start), D(period_end)

    def vs(n):
        return valuesets.get(n, set())

    by = {}
    for r in resources:
        by.setdefault(r.get("resourceType"), []).append(r)
    patient = (by.get("Patient") or [{}])[0]

    bd = D(patient.get("birthDate"))
    age = None
    if bd:
        age = E.year - bd.year - ((E.month, E.day) < (bd.month, bd.day))

    def per(e):
        p = e.get("period")
        return (D(p.get("start")), D(p.get("end"))) if isinstance(p, dict) else None

    def encs(names):
        s = set()
        for n in names:
            s |= vs(n)
        out = []
        for e in by.get("Encounter", []):
            if e.get("status") not in ("finished", "arrived", "triaged", "in-progress", "onleave"):
                continue
            if any(codes(t) & s for t in e.get("type", []) or []):
                out.append(e)
        return out

    qual = [e for e in encs(["Office Visit", "Annual Wellness Visit",
                             "Preventive Care Services Established Office Visit, 18 and Up",
                             "Preventive Care Services Initial Office Visit, 18 and Up",
                             "Home Healthcare Services", "Virtual Encounter", "Telephone Visits"])
            if during(per(e), S, E)]

    ip = age is not None and 52 <= age <= 74 and patient.get("gender") == "female" and bool(qual)

    def conds(name):
        return [c for c in by.get("Condition", []) if anyin(c.get("code"), vs(name))]

    def procs(name):
        return [p for p in by.get("Procedure", [])
                if p.get("status") == "completed" and anyin(p.get("code"), vs(name))
                and ends_by(interval(p, "performed"), E)]

    def obs(codeset, survey=False, statuses=("final", "amended", "corrected")):
        out = []
        for o in by.get("Observation", []):
            if o.get("status") not in statuses or not anyin(o.get("code"), codeset):
                continue
            if survey and not any(SURVEY in codes(c) for c in o.get("category", []) or []):
                continue
            out.append(o)
        return out

    def started_by_end(c):
        pv = prevalence(c)
        return pv is not None and pv[0] <= E

    def uni_dx(status_vs, side):
        r = [c for c in conds(status_vs) if started_by_end(c)]
        r += [c for c in conds("Unilateral Mastectomy, Unspecified Laterality")
              if started_by_end(c) and any(codes(b) & side for b in c.get("bodySite", []) or [])]
        return r

    def day_iv(s):
        d = D(s)
        return (d, d) if d else None

    def hospice():
        for e in encs(["Encounter Inpatient"]):
            dd = (e.get("hospitalization") or {}).get("dischargeDisposition")
            if codes(dd) & HOSPICE_DISCH:
                iv = per(e)
                if iv and iv[1] and S <= iv[1] <= E:
                    return True
        if any(overlaps(per(e), S, E) for e in encs(["Hospice Encounter"])):
            return True
        for o in obs({("http://loinc.org", "45755-6")}, survey=True):
            if (SNOMED, "373066001") in codes(o.get("valueCodeableConcept")) \
                    and overlaps(interval(o, "effective"), S, E):
                return True
        for r in by.get("ServiceRequest", []):
            if r.get("status") in ("active", "completed") and r.get("intent") == "order" \
                    and anyin(r.get("code"), vs("Hospice Care Ambulatory")) \
                    and during(day_iv(r.get("authoredOn")), S, E):
                return True
        for p in by.get("Procedure", []):
            if p.get("status") == "completed" and anyin(p.get("code"), vs("Hospice Care Ambulatory")) \
                    and overlaps(interval(p, "performed"), S, E):
                return True
        for c in conds("Hospice Diagnosis"):
            pv = prevalence(c)
            if pv and overlaps(pv, S, E):
                return True
        return False

    def palliative():
        for o in obs({("http://loinc.org", "71007-9")}, survey=True):
            if overlaps(interval(o, "effective"), S, E):
                return True
        for c in conds("Palliative Care Diagnosis"):
            pv = prevalence(c)
            if pv and overlaps(pv, S, E):
                return True
        if any(overlaps(per(e), S, E) for e in encs(["Palliative Care Encounter"])):
            return True
        for p in by.get("Procedure", []):
            if p.get("status") == "completed" and anyin(p.get("code"), vs("Palliative Care Intervention")) \
                    and overlaps(interval(p, "performed"), S, E):
                return True
        return False

    def med_period(m):
        dosages = m.get("dosageInstruction") or []
        dosage = dosages[0] if len(dosages) == 1 else {}
        dr = (dosage.get("timing") or {}).get("repeat") or {}
        bounds = dr.get("boundsPeriod")
        bstart = D(bounds.get("start")) if bounds else None
        bend = D(bounds.get("end")) if bounds else None
        disp = m.get("dispenseRequest") or {}
        start = bstart or D(m.get("authoredOn")) or D((disp.get("validityPeriod") or {}).get("start"))
        days = None
        esd = disp.get("expectedSupplyDuration")
        if esd and esd.get("value") is not None:
            f = UNITS_DAYS.get((esd.get("code") or esd.get("unit") or "d").lower())
            if f:
                days = esd["value"] * f
        if days is None:
            q = (disp.get("quantity") or {}).get("value")
            dar = dosage.get("doseAndRate") or []
            dose = None
            if len(dar) == 1:
                dq = dar[0].get("doseQuantity") or (dar[0].get("doseRange") or {}).get("high")
                dose = (dq or {}).get("value")
            freq = dr.get("frequencyMax", dr.get("frequency"))
            pr = dr.get("period")
            unit = UNITS_PERIOD.get(dr.get("periodUnit"))
            if freq and pr and unit:
                dpd = freq / (pr * unit)
            elif dr.get("timeOfDay"):
                dpd = len(dr["timeOfDay"])
            else:
                dpd = 1.0
            if q is not None and dose:
                days = q / (dose * dpd)
        if start is not None and days is not None:
            days = days * (1 + (disp.get("numberOfRepeatsAllowed") or 0))
            return (start, start + timedelta(days=days - 1))
        if start is not None and bend is not None:
            return (start, bend)
        return None

    def ends_in_period(iv):
        return iv is not None and iv[1] is not None and S <= iv[1] <= E

    def frailty():
        for r in by.get("DeviceRequest", []):
            if r.get("status") in ("active", "completed") and r.get("intent") == "order" \
                    and r.get("doNotPerform") is not True \
                    and anyin(r.get("codeCodeableConcept"), vs("Frailty Device")):
                d = D(r.get("authoredOn"))
                if d and S <= d <= E:
                    return True
        for o in obs({("http://loinc.org", "98181-1")}, survey=True):
            if anyin(o.get("valueCodeableConcept"), vs("Frailty Device")) \
                    and ends_in_period(interval(o, "effective")):
                return True
        for c in conds("Frailty Diagnosis"):
            pv = prevalence(c)
            if pv and overlaps(pv, S, E):
                return True
        if any(overlaps(per(e), S, E) for e in encs(["Frailty Encounter"])):
            return True
        for o in obs(vs("Frailty Symptom"), statuses=("preliminary", "final", "amended", "corrected")):
            if overlaps(interval(o, "effective"), S, E):
                return True
        return False

    def adv_illness_or_dementia():
        lo = date(S.year - 1, S.month, S.day)
        for c in conds("Advanced Illness"):
            pv = prevalence(c)
            if pv and lo <= pv[0] <= E:
                return True
        for m in by.get("MedicationRequest", []):
            if m.get("status") == "active" and m.get("intent") == "order" \
                    and anyin(m.get("medicationCodeableConcept"), vs("Dementia Medications")):
                if overlaps(med_period(m), lo, E):
                    return True
        return False

    def nursing_home():
        cand = []
        for o in obs({("http://loinc.org", "71802-3")}, survey=True):
            iv = interval(o, "effective")
            if iv and iv[1] is not None and iv[1] <= E:
                cand.append((iv[1], o))
        if not cand:
            return False
        cand.sort(key=lambda x: x[0])
        return (SNOMED, "160734000") in codes(cand[-1][1].get("valueCodeableConcept"))

    den = ip
    excl = False
    if den:
        right = uni_dx("Status Post Right Mastectomy", RIGHT) or procs("Unilateral Mastectomy Right")
        left = uni_dx("Status Post Left Mastectomy", LEFT) or procs("Unilateral Mastectomy Left")
        bil = [c for c in conds("History of bilateral mastectomy") if started_by_end(c)] \
            or procs("Bilateral Mastectomy")
        excl = bool(hospice() or (right and left) or bil
                    or (age >= 66 and frailty() and adv_illness_or_dementia())
                    or (age >= 66 and nursing_home())
                    or palliative())

    num = False
    if den and not excl:
        lo = date(S.year - 2, 10, 1)
        for o in obs(vs("Mammography")):
            iv = interval(o, "effective")
            if iv and iv[1] is not None and lo <= iv[1] <= E:
                num = True
                break
    return {"initial-population": bool(ip), "denominator": bool(den),
            "denominator-exclusion": bool(excl), "numerator": bool(num)}
