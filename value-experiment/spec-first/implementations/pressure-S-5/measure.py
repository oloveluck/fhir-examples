from datetime import datetime, timedelta
import re

LOINC = "http://loinc.org"
SNOMED = "http://snomed.info/sct"
OBS_CAT = "http://terminology.hl7.org/CodeSystem/observation-category"


def pdt(s, high=False):
    """Parse FHIR date/dateTime/instant to naive UTC datetime."""
    if not s:
        return None
    s = str(s)
    m = re.match(r"^(\d{4})(?:-(\d\d))?(?:-(\d\d))?(?:T(\d\d)(?::(\d\d))?(?::(\d\d)(?:\.(\d+))?)?)?\s*(Z|[+-]\d\d:?\d\d)?$", s)
    if not m:
        return None
    y, mo, d, h, mi, se, fr, tz = m.groups()
    y = int(y)
    if h is None:
        if mo is None:
            lo, hi = datetime(y, 1, 1), datetime(y, 12, 31, 23, 59, 59, 999000)
        elif d is None:
            lo = datetime(y, int(mo), 1)
            nxt = datetime(y + (int(mo) == 12), int(mo) % 12 + 1, 1)
            hi = nxt - timedelta(milliseconds=1)
        else:
            lo = datetime(y, int(mo), int(d))
            hi = lo + timedelta(days=1) - timedelta(milliseconds=1)
        return hi if high else lo
    dt = datetime(y, int(mo or 1), int(d or 1), int(h), int(mi or 0), int(se or 0),
                  int((fr or "0").ljust(6, "0")[:6]))
    if tz and tz != "Z":
        sign = 1 if tz[0] == "+" else -1
        t = tz[1:].replace(":", "")
        dt -= sign * timedelta(hours=int(t[:2]), minutes=int(t[2:]))
    return dt


def interval_of(r, base):
    """toInterval of a choice element (effective, performed, onset)."""
    if r.get(base + "DateTime") is not None:
        return (pdt(r[base + "DateTime"]), pdt(r[base + "DateTime"], True))
    if r.get(base + "Instant") is not None:
        t = pdt(r[base + "Instant"])
        return (t, t)
    p = r.get(base + "Period")
    if p is not None:
        return (pdt(p.get("start")), pdt(p.get("end"), True) if p.get("end") else None)
    return None


def latest(iv):
    if iv is None:
        return None
    return iv[1] if iv[1] is not None else iv[0]


def overlaps(iv, lo, hi):
    """iv=(start,end), None end = ongoing; [lo,hi] closed."""
    if iv is None or (iv[0] is None and iv[1] is None):
        return False
    s, e = iv
    if s is not None and s > hi:
        return False
    if e is not None and e < lo:
        return False
    return True


def codes_of(cc):
    out = set()
    if not cc:
        return out
    for c in cc.get("coding", []) or []:
        out.add((c.get("system"), c.get("code")))
    return out


def in_vs(cc, vs):
    return bool(codes_of(cc) & vs)


def has_code(cc, system, code):
    return (system, code) in codes_of(cc)


def evaluate(resources, valuesets, period_start, period_end):
    VS = lambda n: valuesets.get(n, set())
    mp_lo = pdt(period_start)
    mp_hi = pdt(period_end, True)
    by = {}
    patient = None
    for r in resources:
        by.setdefault(r.get("resourceType"), []).append(r)
        if r.get("resourceType") == "Patient":
            patient = r
    G = lambda t: by.get(t, [])

    def during(iv, lo=mp_lo, hi=mp_hi):
        return iv is not None and iv[0] is not None and iv[1] is not None and iv[0] >= lo and iv[1] <= hi

    def ends_during(iv, lo=mp_lo, hi=mp_hi):
        return iv is not None and iv[1] is not None and lo <= iv[1] <= hi

    age = None
    if patient and patient.get("birthDate"):
        b = pdt(patient["birthDate"]).date()
        e = mp_hi.date()
        age = e.year - b.year - ((e.month, e.day) < (b.month, b.day))

    def prevalence(c):
        onset = interval_of(c, "onset")
        if onset is None or onset[0] is None:
            return None
        ab = None
        if c.get("abatementDateTime"):
            ab = pdt(c["abatementDateTime"])
        elif c.get("abatementPeriod"):
            ab = pdt(c["abatementPeriod"].get("end"))
        active = any(code in ("active", "recurrence", "relapse") for _, code in codes_of(c.get("clinicalStatus")))
        if ab is None and not active:
            return None
        return (onset[0], ab)

    def cond_overlaps(c, lo, hi):
        iv = prevalence(c)
        return iv is not None and overlaps(iv, lo, hi)

    def conds(n):
        vs = VS(n)
        return [c for c in G("Condition") if in_vs(c.get("code"), vs)]

    def encs(n):
        vs = VS(n)
        return [e for e in G("Encounter")
                if e.get("status") in ("finished", "arrived", "triaged", "in-progress", "onleave")
                and any(in_vs(t, vs) for t in e.get("type", []) or [])]

    def eperiod(e):
        p = e.get("period")
        if not p:
            return None
        return (pdt(p.get("start")), pdt(p.get("end"), True) if p.get("end") else None)

    def procs(n):
        vs = VS(n)
        return [p for p in G("Procedure") if p.get("status") == "completed" and in_vs(p.get("code"), vs)]

    def obs_assess(code):
        return [o for o in G("Observation")
                if o.get("status") in ("final", "amended", "corrected")
                and has_code(o.get("code"), *code)
                and any(has_code(c, OBS_CAT, "survey") for c in o.get("category", []) or [])]

    # ---- initial population
    h_hi = datetime(mp_lo.year + (mp_lo.month + 6 > 12), (mp_lo.month + 5) % 12 + 1, mp_lo.day) - timedelta(milliseconds=1)
    htn = [c for c in conds("Essential Hypertension") if cond_overlaps(c, mp_lo, h_hi)]
    qual_vs = ["Office Visit", "Annual Wellness Visit",
               "Preventive Care Services Established Office Visit, 18 and Up",
               "Preventive Care Services Initial Office Visit, 18 and Up",
               "Home Healthcare Services", "Virtual Encounter", "Telephone Visits"]
    qual = any(during(eperiod(e)) for n in qual_vs for e in encs(n))
    ip = age is not None and 18 <= age <= 85 and bool(htn) and qual
    den = ip

    def hospice():
        for e in encs("Encounter Inpatient"):
            dd = (e.get("hospitalization") or {}).get("dischargeDisposition")
            if dd and (has_code(dd, SNOMED, "428361000124107") or has_code(dd, SNOMED, "428371000124100")) \
                    and ends_during(eperiod(e)):
                return True
        if any(overlaps(eperiod(e), mp_lo, mp_hi) for e in encs("Hospice Encounter")):
            return True
        for o in obs_assess((LOINC, "45755-6")):
            v = o.get("valueCodeableConcept")
            if v and has_code(v, SNOMED, "373066001") and overlaps(interval_of(o, "effective"), mp_lo, mp_hi):
                return True
        vs = VS("Hospice Care Ambulatory")
        for s in G("ServiceRequest"):
            if s.get("status") in ("active", "completed") and s.get("intent") == "order" \
                    and in_vs(s.get("code"), vs):
                a = pdt(s.get("authoredOn"))
                if a is not None and mp_lo <= a <= mp_hi:
                    return True
        if any(overlaps(interval_of(p, "performed"), mp_lo, mp_hi) for p in procs("Hospice Care Ambulatory")):
            return True
        return any(cond_overlaps(c, mp_lo, mp_hi) for c in conds("Hospice Diagnosis"))

    def palliative():
        for o in obs_assess((LOINC, "71007-9")):
            if overlaps(interval_of(o, "effective"), mp_lo, mp_hi):
                return True
        if any(cond_overlaps(c, mp_lo, mp_hi) for c in conds("Palliative Care Diagnosis")):
            return True
        if any(overlaps(eperiod(e), mp_lo, mp_hi) for e in encs("Palliative Care Encounter")):
            return True
        return any(overlaps(interval_of(p, "performed"), mp_lo, mp_hi) for p in procs("Palliative Care Intervention"))

    def renal():
        for n in ("Pregnancy", "End Stage Renal Disease", "Kidney Transplant Recipient",
                  "Chronic Kidney Disease, Stage 5"):
            if any(cond_overlaps(c, mp_lo, mp_hi) for c in conds(n)):
                return True
        for n in ("Kidney Transplant", "Dialysis Services"):
            for p in procs(n):
                iv = interval_of(p, "performed")
                if iv is not None and iv[1] is not None and iv[1] <= mp_hi:
                    return True
        for e in encs("ESRD Monthly Outpatient Services"):
            iv = eperiod(e)
            if iv is not None and iv[0] is not None and iv[0] <= mp_hi:
                return True
        return False

    def to_days(q):
        if not q or q.get("value") is None:
            return None
        u = q.get("code") or q.get("unit")
        f = {"d": 1, "day": 1, "days": 1, "wk": 7, "week": 7, "weeks": 7, "h": 1 / 24, "hour": 1 / 24,
             "hours": 1 / 24, "mo": 30, "month": 30, "months": 30, "a": 365, "year": 365}.get(u)
        return q["value"] * f if f else None

    def med_period(m):
        di = m.get("dosageInstruction") or []
        dosage = di[0] if len(di) == 1 else None
        dr = (dosage or {}).get("doseAndRate") or []
        dar = dr[0] if len(dr) == 1 else {}
        rep = ((dosage or {}).get("timing") or {}).get("repeat") or {}
        freq = rep.get("frequencyMax") or rep.get("frequency")
        per = None
        if rep.get("period") is not None:
            pu = {"d": 1, "wk": 7, "h": 1 / 24, "mo": 30, "a": 365, "min": 1 / 1440, "s": 1 / 86400}.get(rep.get("periodUnit"))
            per = rep["period"] * pu if pu else None
        perday = freq / per if freq and per else None
        if perday is None:
            perday = len(rep.get("timeOfDay") or []) or 1.0
        dose = None
        if dar.get("doseRange"):
            dose = (dar["doseRange"].get("high") or {}).get("value")
        if dose is None and dar.get("doseQuantity"):
            dose = dar["doseQuantity"].get("value")
        bounds = rep.get("boundsPeriod") or {}
        dreq = m.get("dispenseRequest") or {}
        start = None
        for s in (bounds.get("start"), m.get("authoredOn"), (dreq.get("validityPeriod") or {}).get("start")):
            if s:
                start = pdt(s)
                break
        if start is None:
            return None
        start = datetime(start.year, start.month, start.day)
        ds = to_days(dreq.get("expectedSupplyDuration"))
        qv = (dreq.get("quantity") or {}).get("value")
        if ds is None and qv is not None and dose:
            ds = qv / (dose * perday)
        if ds is None:
            return None
        total = ds * (1 + (dreq.get("numberOfRepeatsAllowed") or 0))
        return (start, start + timedelta(days=total - 1, hours=23, minutes=59, seconds=59))

    def frailty():
        vs = VS("Frailty Device")
        for d in G("DeviceRequest"):
            if d.get("status") in ("active", "completed") and d.get("intent") == "order" \
                    and d.get("doNotPerform") is not True and in_vs(d.get("codeCodeableConcept"), vs):
                a = pdt(d.get("authoredOn"))
                if a is not None and mp_lo <= a <= mp_hi:
                    return True
        for o in obs_assess((LOINC, "98181-1")):
            if in_vs(o.get("valueCodeableConcept"), vs) and ends_during(interval_of(o, "effective")):
                return True
        if any(cond_overlaps(c, mp_lo, mp_hi) for c in conds("Frailty Diagnosis")):
            return True
        if any(overlaps(eperiod(e), mp_lo, mp_hi) for e in encs("Frailty Encounter")):
            return True
        svs = VS("Frailty Symptom")
        for o in G("Observation"):
            if o.get("status") in ("preliminary", "final", "amended", "corrected") and in_vs(o.get("code"), svs) \
                    and overlaps(interval_of(o, "effective"), mp_lo, mp_hi):
                return True
        return False

    def advanced():
        lo = mp_lo.replace(year=mp_lo.year - 1)
        for c in conds("Advanced Illness"):
            iv = prevalence(c)
            if iv and iv[0] is not None and lo <= iv[0] <= mp_hi:
                return True
        vs = VS("Dementia Medications")
        for m in G("MedicationRequest"):
            if m.get("status") == "active" and m.get("intent") == "order" \
                    and in_vs(m.get("medicationCodeableConcept"), vs):
                iv = med_period(m)
                if iv and overlaps(iv, lo, mp_hi):
                    return True
        return False

    def nursing_home():
        if age is None or age < 66:
            return False
        obs = []
        for o in obs_assess((LOINC, "71802-3")):
            iv = interval_of(o, "effective")
            if iv and iv[1] is not None and iv[1] <= mp_hi:
                obs.append((iv[1], o))
        if not obs:
            return False
        obs.sort(key=lambda x: x[0])
        return has_code(obs[-1][1].get("valueCodeableConcept"), SNOMED, "160734000")

    excl = False
    if den:
        fr = age >= 66 and frailty()
        excl = (hospice() or renal()
                or (66 <= age <= 80 and fr and advanced())
                or (age >= 81 and fr)
                or nursing_home() or palliative())

    def bp_value(o, code):
        vals = [c.get("valueQuantity") for c in o.get("component", []) or []
                if has_code(c.get("code"), LOINC, code)]
        if len(vals) != 1 or vals[0] is None or vals[0].get("value") is None:
            return None
        return vals[0]["value"]

    enc_by_id = {e.get("id"): e for e in G("Encounter")}
    readings = []
    for o in G("Observation"):
        if o.get("status") not in ("final", "amended", "corrected"):
            continue
        profs = (o.get("meta") or {}).get("profile") or []
        if not (any("observation-bp" in p for p in profs) or has_code(o.get("code"), LOINC, "85354-9")):
            continue
        ref = (o.get("encounter") or {}).get("reference")
        if ref:
            e = enc_by_id.get(ref.split("/")[-1])
            if e and (e.get("class") or {}).get("code") in ("EMER", "IMP", "ACUTE", "NONAC", "PRENC", "SS"):
                continue
        t = latest(interval_of(o, "effective"))
        if t is None or not (mp_lo <= t <= mp_hi):
            continue
        readings.append((t.date(), o))
    num = False
    if den and not excl and readings:
        day = max(d for d, _ in readings)
        today = [o for d, o in readings if d == day]
        s = [bp_value(o, "8480-6") for o in today]
        di = [bp_value(o, "8462-4") for o in today]
        # a missing value sorts first in ascending order, so the lowest is null
        if None not in s and None not in di:
            num = min(s) < 140 and min(di) < 90
    return {"initial-population": bool(ip), "denominator": bool(den),
            "denominator-exclusion": bool(excl), "numerator": bool(num)}
