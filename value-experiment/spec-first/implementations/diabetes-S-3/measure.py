import calendar
from datetime import date, timedelta

LOINC = "http://loinc.org"
SNOMED = "http://snomed.info/sct"
OBS_CAT = "http://terminology.hl7.org/CodeSystem/observation-category"
COND_CLIN = "http://terminology.hl7.org/CodeSystem/condition-clinical"


def pdate(s, end=False):
    if not s or not isinstance(s, str):
        return None
    try:
        p = s[:10].split("-")
        y = int(p[0])
        if len(p) == 1:
            return date(y, 12, 31) if end else date(y, 1, 1)
        m = int(p[1])
        if len(p) == 2:
            return date(y, m, calendar.monthrange(y, m)[1]) if end else date(y, m, 1)
        return date(y, m, int(p[2]))
    except Exception:
        return None


def add_years(d, n):
    try:
        return d.replace(year=d.year + n)
    except ValueError:
        return d.replace(year=d.year + n, day=28)


def qty_age_date(q, birth):
    if not birth or not isinstance(q, dict) or q.get("value") is None:
        return None
    unit = q.get("code") or q.get("unit") or "a"
    v = q["value"]
    if unit in ("mo", "month", "months"):
        mm = birth.month - 1 + int(v)
        y = birth.year + mm // 12
        m = mm % 12 + 1
        return date(y, m, min(birth.day, calendar.monthrange(y, m)[1]))
    if unit in ("wk", "week", "weeks"):
        return birth + timedelta(weeks=int(v))
    if unit in ("d", "day", "days"):
        return birth + timedelta(days=int(v))
    return add_years(birth, int(v))


def overlaps(a, b):
    if a is None or b is None:
        return False
    al, ah = a
    bl, bh = b
    if al is not None and bh is not None and al > bh:
        return False
    if bl is not None and ah is not None and bl > ah:
        return False
    return True


def during(a, b):
    if a is None or b is None:
        return False
    al, ah = a
    bl, bh = b
    if al is None or ah is None:
        return False
    return bl <= al and ah <= bh


def codings(cc):
    out = []
    if isinstance(cc, dict):
        out = cc.get("coding") or []
    elif isinstance(cc, list):
        for c in cc:
            out += codings(c)
    return out


def in_vs(cc, vs):
    return any((c.get("system"), c.get("code")) in vs for c in codings(cc))


def has_code(cc, system, code):
    return any(c.get("system") == system and c.get("code") == code for c in codings(cc))


def interval_of(res, prefix, birth):
    if res.get(prefix + "DateTime") is not None:
        s = res[prefix + "DateTime"]
        if len(s) < 10:
            return (pdate(s), pdate(s, True))
        return (pdate(s), pdate(s))
    if res.get(prefix + "Instant") is not None:
        d = pdate(res[prefix + "Instant"])
        return (d, d)
    if res.get(prefix + "Period") is not None:
        p = res[prefix + "Period"]
        return (pdate(p.get("start")), pdate(p.get("end"), True))
    if res.get(prefix + "Age") is not None:
        lo = qty_age_date(res[prefix + "Age"], birth)
        if lo is None:
            return None
        return (lo, add_years(lo, 1) - timedelta(days=1))
    if res.get(prefix + "Range") is not None:
        r = res[prefix + "Range"]
        lo = qty_age_date(r.get("low"), birth)
        hi = qty_age_date(r.get("high"), birth)
        if lo is None or hi is None:
            return None
        return (lo, add_years(hi, 1) - timedelta(days=1))
    return None


def period_iv(p):
    if not isinstance(p, dict):
        return None
    return (pdate(p.get("start")), pdate(p.get("end"), True))


def latest(iv):
    if iv is None:
        return None
    lo, hi = iv
    return hi if hi is not None else lo


def prevalence(cond, birth):
    onset = interval_of(cond, "onset", birth)
    start = onset[0] if onset else None
    ab = None
    if cond.get("abatementDateTime") is not None:
        s = cond["abatementDateTime"]
        ab = (pdate(s), pdate(s, True))
    elif cond.get("abatementAge") is not None or cond.get("abatementRange") is not None:
        ab = interval_of(cond, "abatement", birth)
    elif cond.get("abatementPeriod") is not None:
        p = cond["abatementPeriod"]
        h = pdate(p.get("end"))
        if h is not None:
            h = h - timedelta(days=1)
        ab = (pdate(p.get("start")), h)
    end = ab[1] if ab else None
    return (start, end)


def evaluate(resources, valuesets, period_start, period_end):
    PS, PE = pdate(period_start), pdate(period_end)
    MP = (PS, PE)
    by = {}
    for r in resources:
        by.setdefault(r.get("resourceType"), []).append(r)
    patient = (by.get("Patient") or [{}])[0]
    birth = pdate(patient.get("birthDate"))

    def vs(name):
        return valuesets.get(name, set())

    age = None
    if birth:
        age = PE.year - birth.year - ((PE.month, PE.day) < (birth.month, birth.day))

    FINAL = ("final", "amended", "corrected")

    def has_cat(o, code):
        return any(has_code(c, OBS_CAT, code) for c in (o.get("category") or []))

    def lab_performed(o):
        return o.get("status") in FINAL and has_cat(o, "laboratory")

    def assessment(o):
        return o.get("status") in FINAL and has_cat(o, "survey")

    def enc_in(names):
        out = []
        for e in by.get("Encounter", []):
            if e.get("status") in ("finished", "arrived", "triaged", "in-progress", "onleave"):
                if any(in_vs(e.get("type"), vs(n)) for n in names):
                    out.append(e)
        return out

    def cond_in(name):
        return [c for c in by.get("Condition", []) if in_vs(c.get("code"), vs(name))]

    def obs_code(system, code):
        return [o for o in by.get("Observation", []) if has_code(o.get("code"), system, code)]

    def obs_vs(name):
        return [o for o in by.get("Observation", []) if in_vs(o.get("code"), vs(name))]

    def proc_in(name):
        return [p for p in by.get("Procedure", [])
                if p.get("status") == "completed" and in_vs(p.get("code"), vs(name))]

    # ---- initial population
    qual_names = ["Office Visit", "Annual Wellness Visit",
                  "Preventive Care Services Established Office Visit, 18 and Up",
                  "Preventive Care Services Initial Office Visit, 18 and Up",
                  "Home Healthcare Services", "Virtual Encounter", "Telephone Visits"]
    qual = any(during(period_iv(e.get("period")), MP) for e in enc_in(qual_names))
    diab = any(overlaps(prevalence(c, birth), MP) for c in cond_in("Diabetes"))
    ip = bool(age is not None and 18 <= age <= 75 and qual and diab)

    # ---- exclusions
    def hospice():
        for e in enc_in(["Encounter Inpatient"]):
            dd = (e.get("hospitalization") or {}).get("dischargeDisposition")
            if has_code(dd, SNOMED, "428361000124107") or has_code(dd, SNOMED, "428371000124100"):
                iv = period_iv(e.get("period"))
                if iv and iv[1] is not None and PS <= iv[1] <= PE:
                    return True
        for e in enc_in(["Hospice Encounter"]):
            if overlaps(period_iv(e.get("period")), MP):
                return True
        for o in obs_code(LOINC, "45755-6"):
            if assessment(o) and has_code(o.get("valueCodeableConcept"), SNOMED, "373066001") \
                    and overlaps(interval_of(o, "effective", birth), MP):
                return True
        for s in by.get("ServiceRequest", []):
            if s.get("status") in ("active", "completed") and s.get("intent") == "order" \
                    and in_vs(s.get("code"), vs("Hospice Care Ambulatory")):
                d = pdate(s.get("authoredOn"))
                if d and PS <= d <= PE:
                    return True
        for p in proc_in("Hospice Care Ambulatory"):
            if overlaps(interval_of(p, "performed", birth), MP):
                return True
        for c in cond_in("Hospice Diagnosis"):
            if overlaps(prevalence(c, birth), MP):
                return True
        return False

    def palliative():
        for o in obs_code(LOINC, "71007-9"):
            if assessment(o) and overlaps(interval_of(o, "effective", birth), MP):
                return True
        for c in cond_in("Palliative Care Diagnosis"):
            if overlaps(prevalence(c, birth), MP):
                return True
        for e in enc_in(["Palliative Care Encounter"]):
            if overlaps(period_iv(e.get("period")), MP):
                return True
        for p in proc_in("Palliative Care Intervention"):
            if overlaps(interval_of(p, "performed", birth), MP):
                return True
        return False

    def med_of(m):
        if m.get("medicationCodeableConcept") is not None:
            return m["medicationCodeableConcept"]
        ref = (m.get("medicationReference") or {}).get("reference")
        if ref:
            rid = ref.split("/")[-1].lstrip("#")
            for med in by.get("Medication", []) + (m.get("contained") or []):
                if med.get("resourceType") == "Medication" and med.get("id") == rid:
                    return med.get("code")
        return None

    def days_of(value, u):
        if value is None:
            return None
        f = {"d": 1, "day": 1, "days": 1, "wk": 7, "week": 7, "weeks": 7, "h": 1 / 24.0,
             "hour": 1 / 24.0, "mo": 30, "month": 30, "months": 30, "a": 365, "year": 365}.get(u)
        return None if f is None else value * f

    def med_period(m):
        di = m.get("dosageInstruction") or []
        if len(di) > 1:
            return None
        dosage = di[0] if di else {}
        dr = dosage.get("doseAndRate") or []
        if len(dr) > 1:
            return None
        dar = dr[0] if dr else {}
        rep = (dosage.get("timing") or {}).get("repeat") or {}
        freq = rep.get("frequencyMax") or rep.get("frequency")
        per = days_of(rep.get("period"), rep.get("periodUnit"))
        if freq is not None and per:
            dpd = freq / per
        elif rep.get("timeOfDay"):
            dpd = len(rep["timeOfDay"])
        else:
            dpd = 1.0
        dose = None
        if (dar.get("doseRange") or {}).get("high"):
            dose = dar["doseRange"]["high"].get("value")
        if dose is None and dar.get("doseQuantity"):
            dose = dar["doseQuantity"].get("value")
        bounds = rep.get("boundsPeriod")
        bstart = pdate(bounds.get("start")) if bounds else None
        bend = pdate(bounds.get("end")) if bounds else None
        dreq = m.get("dispenseRequest") or {}
        esd = dreq.get("expectedSupplyDuration") or {}
        supply = days_of(esd.get("value"), esd.get("code") or esd.get("unit"))
        qty = (dreq.get("quantity") or {}).get("value")
        refills = dreq.get("numberOfRepeatsAllowed") or 0
        start = bstart or pdate(m.get("authoredOn")) or pdate((dreq.get("validityPeriod") or {}).get("start"))
        total = None
        if supply is not None:
            total = supply * (1 + refills)
        elif qty is not None and dose and dpd:
            total = qty / (dose * dpd) * (1 + refills)
        if start is not None and total is not None:
            return (start, start + timedelta(days=int(total - 1)))
        if start is not None and bend is not None:
            return (start, bend)
        return None

    def frailty():
        for d in by.get("DeviceRequest", []):
            if d.get("status") in ("active", "completed") and d.get("intent") == "order" \
                    and d.get("doNotPerform") is not True \
                    and in_vs(d.get("codeCodeableConcept"), vs("Frailty Device")):
                a = pdate(d.get("authoredOn"))
                if a and PS <= a <= PE:
                    return True
        for o in obs_code(LOINC, "98181-1"):
            if assessment(o) and in_vs(o.get("valueCodeableConcept"), vs("Frailty Device")):
                iv = interval_of(o, "effective", birth)
                if iv and iv[1] is not None and PS <= iv[1] <= PE:
                    return True
        for c in cond_in("Frailty Diagnosis"):
            if overlaps(prevalence(c, birth), MP):
                return True
        for e in enc_in(["Frailty Encounter"]):
            if overlaps(period_iv(e.get("period")), MP):
                return True
        for o in obs_vs("Frailty Symptom"):
            if o.get("status") in ("preliminary",) + FINAL and overlaps(interval_of(o, "effective", birth), MP):
                return True
        return False

    def advanced():
        lo = add_years(PS, -1)
        for c in cond_in("Advanced Illness"):
            st = prevalence(c, birth)[0]
            if st is not None and lo <= st <= PE:
                return True
        return False

    def dementia():
        win = (add_years(PS, -1), PE)
        for m in by.get("MedicationRequest", []):
            if m.get("status") == "active" and m.get("intent") == "order" \
                    and in_vs(med_of(m), vs("Dementia Medications")):
                if overlaps(med_period(m), win):
                    return True
        return False

    def nursing_home():
        if age is None or age < 66:
            return False
        cands = []
        for o in obs_code(LOINC, "71802-3"):
            if assessment(o):
                iv = interval_of(o, "effective", birth)
                if iv and iv[1] is not None and iv[1] <= PE:
                    cands.append((iv[1], o))
        if not cands:
            return False
        cands.sort(key=lambda t: t[0])
        return has_code(cands[-1][1].get("valueCodeableConcept"), SNOMED, "160734000")

    excl = hospice() or nursing_home() or palliative()
    if not excl and age is not None and age >= 66:
        if frailty() and (advanced() or dementia()):
            excl = True

    # ---- numerator
    gsa = []
    for o in obs_vs("HbA1c Laboratory Test") + obs_code(LOINC, "97506-0"):
        if lab_performed(o):
            d = latest(interval_of(o, "effective", birth))
            if d is not None and PS <= d <= PE:
                gsa.append((d, o))
    num = False
    if not gsa:
        num = True
    else:
        recent = max(d for d, _ in gsa)
        day = [o for d, o in gsa if d == recent]

        def qv(o):
            q = o.get("valueQuantity")
            return q.get("value") if isinstance(q, dict) else None

        day.sort(key=lambda o: (qv(o) is not None, qv(o) if qv(o) is not None else 0))
        low = day[0]
        if not any(k.startswith("value") for k in low):
            num = True
        else:
            q = low.get("valueQuantity")
            if isinstance(q, dict) and q.get("value") is not None:
                unit = q.get("code") or q.get("unit")
                if unit == "%" and q["value"] > 9:
                    num = True

    den = ip
    ex = den and bool(excl)
    return {"initial-population": ip, "denominator": den,
            "denominator-exclusion": ex, "numerator": den and not ex and num}
