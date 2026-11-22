from datetime import date, timedelta

UNK = "UNKNOWN"  # open-ended null boundary: comparisons are unknown -> false
OBS_CAT = "http://terminology.hl7.org/CodeSystem/observation-category"
LOINC = "http://loinc.org"
SCT = "http://snomed.info/sct"


def pdate(s, end=False):
    if not s:
        return None
    s = str(s)
    try:
        y = int(s[0:4])
        m = int(s[5:7]) if len(s) >= 7 else (12 if end else 1)
        if len(s) >= 10:
            d = int(s[8:10])
        else:
            d = 31 if end else 1
            if end and m in (4, 6, 9, 11):
                d = 30
            if end and m == 2:
                d = 29 if (y % 4 == 0 and (y % 100 != 0 or y % 400 == 0)) else 28
        return date(y, m, d)
    except Exception:
        return None


def addyears(d, n):
    try:
        return d.replace(year=d.year + n)
    except ValueError:
        return d.replace(year=d.year + n, day=28)


def codes_of(cc):
    out = set()
    if not cc:
        return out
    if isinstance(cc, list):
        for c in cc:
            out |= codes_of(c)
        return out
    for c in cc.get("coding", []) or []:
        out.add((c.get("system"), c.get("code")))
    return out


def in_vs(cc, vs):
    return bool(codes_of(cc) & vs)


def has_code(cc, system, code):
    return (system, code) in codes_of(cc)


def evaluate(resources, valuesets, period_start, period_end):
    PS = pdate(period_start)
    PE = pdate(period_end, True)

    def V(n):
        return valuesets.get(n, set())

    by = {}
    patient = None
    for r in resources:
        by.setdefault(r.get("resourceType"), []).append(r)
        if r.get("resourceType") == "Patient":
            patient = r
    birth = pdate((patient or {}).get("birthDate"))

    age = None
    if birth:
        age = PE.year - birth.year - ((PE.month, PE.day) < (birth.month, birth.day))

    def age_q(q):
        if birth is None or not q or q.get("value") is None:
            return None
        return addyears(birth, int(q["value"]))

    def to_interval(r, prefix):
        for k in (prefix + "DateTime", prefix + "Instant"):
            if r.get(k):
                return (pdate(r[k]), pdate(r[k], True))
        if prefix + "Period" in r:
            p = r[prefix + "Period"]
            return (pdate(p.get("start")), pdate(p.get("end"), True))
        if prefix + "Age" in r:
            d = age_q(r[prefix + "Age"])
            if d:
                return (d, addyears(d, 1) - timedelta(days=1))
        return None

    def during(iv):
        return bool(iv) and iv[0] not in (None, UNK) and iv[1] not in (None, UNK) \
            and iv[0] >= PS and iv[1] <= PE

    def overlaps(iv, a=None, b=None):
        a = a or PS
        b = b or PE
        if not iv or iv[0] == UNK or iv[1] == UNK:
            return False
        return (iv[0] is None or iv[0] <= b) and (iv[1] is None or iv[1] >= a)

    def prevalence(c):
        onset = to_interval(c, "onset")
        lo = onset[0] if onset else None
        ab = None
        if c.get("abatementDateTime"):
            ab = (pdate(c["abatementDateTime"]), pdate(c["abatementDateTime"], True))
        elif "abatementAge" in c:
            d = age_q(c["abatementAge"])
            ab = (d, addyears(d, 1) - timedelta(days=1)) if d else None
        elif "abatementPeriod" in c:
            p = c["abatementPeriod"]
            ab = (pdate(p.get("start")), pdate(p.get("end")))
        hi = ab[1] if ab else None
        status = codes_of(c.get("clinicalStatus"))
        active = any(s[1] in ("active", "recurrence", "relapse") for s in status)
        if active:
            return (lo, hi)
        if hi is None:
            return (lo, UNK)
        return (lo, hi)

    def cond_overlap(name):
        return any(in_vs(c.get("code"), V(name)) and overlaps(prevalence(c))
                   for c in by.get("Condition", []))

    def enc_ok(e):
        return e.get("status") in ("finished", "arrived", "triaged", "in-progress", "onleave")

    def enc_iv(e):
        p = e.get("period") or {}
        return (pdate(p.get("start")), pdate(p.get("end"), True))

    def encs(name):
        return [e for e in by.get("Encounter", []) if enc_ok(e) and (codes_of(e.get("type")) & V(name))]

    def obs_cat(o, cat):
        return (OBS_CAT, cat) in codes_of(o.get("category"))

    def obs_final(o):
        return o.get("status") in ("final", "amended", "corrected")

    def obs_by_code(codeset):
        return [o for o in by.get("Observation", []) if codes_of(o.get("code")) & codeset]

    def eff(o):
        return to_interval(o, "effective")

    def latest(iv):
        if not iv:
            return None
        return iv[1] if iv[1] is not None else iv[0]

    # ---- initial population
    in_age = age is not None and 18 <= age <= 75
    qualifying = any(during(enc_iv(e)) for n in (
        "Office Visit", "Annual Wellness Visit",
        "Preventive Care Services Established Office Visit, 18 and Up",
        "Preventive Care Services Initial Office Visit, 18 and Up",
        "Home Healthcare Services", "Virtual Encounter", "Telephone Visits") for e in encs(n))
    ip = bool(in_age and qualifying and cond_overlap("Diabetes"))

    # ---- exclusions
    def hospice():
        for e in encs("Encounter Inpatient"):
            d = (e.get("hospitalization") or {}).get("dischargeDisposition")
            if has_code(d, SCT, "428361000124107") or has_code(d, SCT, "428371000124100"):
                iv = enc_iv(e)
                if iv[1] is not None and PS <= iv[1] <= PE:
                    return True
        for e in encs("Hospice Encounter"):
            if overlaps(enc_iv(e)):
                return True
        for o in obs_by_code({(LOINC, "45755-6")}):
            if obs_final(o) and obs_cat(o, "survey") and has_code(o.get("valueCodeableConcept"), SCT, "373066001") \
                    and overlaps(eff(o)):
                return True
        for s in by.get("ServiceRequest", []):
            if in_vs(s.get("code"), V("Hospice Care Ambulatory")) and s.get("status") in ("active", "completed") \
                    and s.get("intent") == "order":
                d = pdate(s.get("authoredOn"))
                if d and PS <= d <= PE:
                    return True
        for p in by.get("Procedure", []):
            if in_vs(p.get("code"), V("Hospice Care Ambulatory")) and p.get("status") == "completed" \
                    and overlaps(to_interval(p, "performed")):
                return True
        return cond_overlap("Hospice Diagnosis")

    def nursing_home():
        if age is None or age < 66:
            return False
        cands = []
        for o in obs_by_code({(LOINC, "71802-3")}):
            if obs_final(o) and obs_cat(o, "survey"):
                iv = eff(o)
                if iv and iv[1] is not None and iv[1] <= PE:
                    cands.append((iv[1], o))
        if not cands:
            return False
        cands.sort(key=lambda t: t[0])
        return has_code(cands[-1][1].get("valueCodeableConcept"), SCT, "160734000")

    def do_not_perform(r):
        vals = [e.get("valueBoolean") for e in r.get("modifierExtension", []) or []
                if e.get("url") == "http://hl7.org/fhir/us/qicore/StructureDefinition/qicore-doNotPerform"]
        return len(vals) == 1 and vals[0] is True

    def med_period(m):
        di = m.get("dosageInstruction") or []
        dosage = di[0] if len(di) == 1 else {}
        dr = dosage.get("doseAndRate") or []
        dar = dr[0] if len(dr) == 1 else {}
        rep = (dosage.get("timing") or {}).get("repeat") or {}
        freq = rep.get("frequencyMax") or rep.get("frequency")
        per = rep.get("period")
        unit = rep.get("periodUnit")
        days = {"d": 1, "wk": 7, "mo": 30, "a": 365, "h": 1 / 24, "min": 1 / 1440, "s": 1 / 86400}.get(unit)
        perday = None
        if freq and per and days:
            perday = freq / (per * days)
        if perday is None:
            tod = rep.get("timeOfDay")
            perday = len(tod) if tod else 1.0
        bounds = rep.get("boundsPeriod")
        bstart = pdate(bounds.get("start")) if bounds else None
        bend = pdate(bounds.get("end")) if bounds and bounds.get("end") else None
        dose = None
        d = dar.get("doseRange")
        if d and d.get("high"):
            dose = d["high"].get("value")
        if dose is None and dar.get("doseQuantity"):
            dose = dar["doseQuantity"].get("value")
        disp = m.get("dispenseRequest") or {}
        supply = None
        es = disp.get("expectedSupplyDuration")
        if es and es.get("value") is not None:
            u = es.get("code") or es.get("unit")
            f = {"d": 1, "day": 1, "days": 1, "wk": 7, "week": 7, "mo": 30, "month": 30,
                 "a": 365, "year": 365}.get(u)
            if f:
                supply = es["value"] * f
        qty = (disp.get("quantity") or {}).get("value")
        refills = disp.get("numberOfRepeatsAllowed") or 0
        start = bstart or pdate(m.get("authoredOn")) or pdate((disp.get("validityPeriod") or {}).get("start"))
        total = supply
        if total is None and qty is not None and dose:
            total = qty / (dose * perday)
        if total is not None:
            total = total * (1 + refills)
        if start and total is not None:
            return (start, start + timedelta(days=int(total - 1) if total >= 1 else 0))
        if start and bend:
            return (start, bend)
        return None

    def frailty():
        for r in by.get("DeviceRequest", []):
            if in_vs(r.get("codeCodeableConcept"), V("Frailty Device")) and r.get("status") in ("active", "completed") \
                    and r.get("intent") == "order" and not do_not_perform(r):
                d = pdate(r.get("authoredOn"))
                if d and PS <= d <= PE:
                    return True
        for o in obs_by_code({(LOINC, "98181-1")}):
            if obs_final(o) and obs_cat(o, "survey") and in_vs(o.get("valueCodeableConcept"), V("Frailty Device")):
                iv = eff(o)
                if iv and iv[1] is not None and PS <= iv[1] <= PE:
                    return True
        if cond_overlap("Frailty Diagnosis"):
            return True
        for e in encs("Frailty Encounter"):
            if overlaps(enc_iv(e)):
                return True
        for o in obs_by_code(V("Frailty Symptom")):
            if o.get("status") in ("preliminary", "final", "amended", "corrected") and overlaps(eff(o)):
                return True
        return False

    def advanced():
        lo = addyears(PS, -1)
        for c in by.get("Condition", []):
            if in_vs(c.get("code"), V("Advanced Illness")):
                s = prevalence(c)[0]
                if s is not None and lo <= s <= PE:
                    return True
        for m in by.get("MedicationRequest", []):
            if in_vs(m.get("medicationCodeableConcept"), V("Dementia Medications")) \
                    and m.get("status") == "active" and m.get("intent") == "order":
                if overlaps(med_period(m), lo, PE):
                    return True
        return False

    def palliative():
        for o in obs_by_code({(LOINC, "71007-9")}):
            if obs_final(o) and obs_cat(o, "survey") and overlaps(eff(o)):
                return True
        if cond_overlap("Palliative Care Diagnosis"):
            return True
        for e in encs("Palliative Care Encounter"):
            if overlaps(enc_iv(e)):
                return True
        for p in by.get("Procedure", []):
            if in_vs(p.get("code"), V("Palliative Care Intervention")) and p.get("status") == "completed" \
                    and overlaps(to_interval(p, "performed")):
                return True
        return False

    excl = False
    if ip:
        excl = bool(hospice() or nursing_home()
                    or (age >= 66 and frailty() and advanced())
                    or palliative())

    # ---- numerator
    gsa = []
    for o in obs_by_code(V("HbA1c Laboratory Test") | {(LOINC, "97506-0")}):
        if obs_final(o) and obs_cat(o, "laboratory"):
            d = latest(eff(o))
            if d is not None and PS <= d <= PE:
                gsa.append((d, o))
    num = False
    if not gsa:
        num = True
    else:
        recent = max(d for d, _ in gsa)
        same = [o for d, o in gsa if d == recent]

        def val(o):
            q = o.get("valueQuantity")
            if q is None or q.get("value") is None:
                return None
            return q

        same.sort(key=lambda o: (val(o) is not None, val(o)["value"] if val(o) else 0))
        q = val(same[0])
        if q is None:
            num = True
        else:
            u = q.get("code") or q.get("unit")
            num = q["value"] > 9 and u in ("%", None, "")

    return {"initial-population": ip, "denominator": ip,
            "denominator-exclusion": ip and excl,
            "numerator": ip and not excl and num}
