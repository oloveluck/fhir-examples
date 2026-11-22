import re
from datetime import date, timedelta

SNOMED = "http://snomed.info/sct"
OBSCAT = "http://terminology.hl7.org/CodeSystem/observation-category"


def pdate(s):
    """Parse FHIR date/dateTime/instant to a date (literal calendar day)."""
    if not s or not isinstance(s, str):
        return None
    m = re.match(r"(\d{4})(?:-(\d{2}))?(?:-(\d{2}))?", s)
    if not m:
        return None
    try:
        return date(int(m.group(1)), int(m.group(2) or 1), int(m.group(3) or 1))
    except ValueError:
        return None


def pend(s):
    """Like pdate but a partial date gives its last day."""
    if not s or not isinstance(s, str):
        return None
    m = re.match(r"(\d{4})(?:-(\d{2}))?(?:-(\d{2}))?", s)
    if not m:
        return None
    y = int(m.group(1))
    if m.group(3):
        return pdate(s)
    if m.group(2):
        mo = int(m.group(2))
        if not 1 <= mo <= 12:
            return None
        return date(y + (mo == 12), mo % 12 + 1, 1) - timedelta(days=1)
    return date(y, 12, 31)


def add_years(d, n):
    try:
        return d.replace(year=d.year + n)
    except ValueError:
        return d.replace(year=d.year + n, day=28)


def concepts_codes(cc):
    out = set()
    if isinstance(cc, dict):
        for c in cc.get("coding", []) or []:
            out.add((c.get("system"), c.get("code")))
    return out


def in_vs(cc, vs):
    return bool(concepts_codes(cc) & vs)


def interval(res, base):
    """(start, end) dates of choice element base[x]; None if absent."""
    for suffix in ("DateTime", "Instant", "Date"):
        if base + suffix in res:
            s = res[base + suffix]
            return (pdate(s), pend(s))
    if base + "Period" in res:
        p = res[base + "Period"] or {}
        return (pdate(p.get("start")), pend(p.get("end")))
    return None


def ends_during(iv, a, b):
    return bool(iv and iv[1] and a <= iv[1] <= b)


def during(iv, a, b):
    return bool(iv and iv[0] and iv[1] and a <= iv[0] and iv[1] <= b)


def overlaps(iv, a, b):
    if not iv:
        return False
    s, e = iv
    if s is None and e is None:
        return False
    return (s is None or s <= b) and (e is None or e >= a)


def evaluate(resources, valuesets, period_start, period_end):
    ps, pe = pdate(period_start), pdate(period_end)

    def V(n):
        return valuesets.get(n, set())

    by = {}
    for r in resources:
        by.setdefault(r.get("resourceType"), []).append(r)
    patient = (by.get("Patient") or [{}])[0]
    birth = pdate(patient.get("birthDate"))
    age = None
    if birth:
        age = pe.year - birth.year - ((pe.month, pe.day) < (birth.month, birth.day))

    def conds(vsname):
        return [c for c in by.get("Condition", []) if in_vs(c.get("code"), V(vsname))]

    def obs(codes):
        return [o for o in by.get("Observation", []) if in_vs(o.get("code"), codes)]

    def procs(vsname):
        return [p for p in by.get("Procedure", []) if in_vs(p.get("code"), V(vsname))]

    def encs(vsname):
        return [e for e in by.get("Encounter", [])
                if any(in_vs(t, V(vsname)) for t in e.get("type", []) or [])]

    def enc_ok(e):
        return e.get("status") in ("finished", "arrived", "triaged", "in-progress", "onleave")

    def obs_perf(o):
        return o.get("status") in ("final", "amended", "corrected")

    def assess(o):
        return obs_perf(o) and any((OBSCAT, "survey") in concepts_codes(x) for x in o.get("category", []) or [])

    def proc_ok(p):
        return p.get("status") == "completed"

    def per(e):
        p = e.get("period") or {}
        return (pdate(p.get("start")), pend(p.get("end")))

    def onset_start(c):
        if "onsetDateTime" in c:
            return pdate(c["onsetDateTime"])
        if "onsetPeriod" in c:
            return pdate((c["onsetPeriod"] or {}).get("start"))
        if "onsetAge" in c and birth:
            v = c["onsetAge"].get("value")
            return add_years(birth, int(v)) if v is not None else None
        if "onsetRange" in c and birth:
            v = (c["onsetRange"].get("low") or {}).get("value")
            return add_years(birth, int(v)) if v is not None else None
        return None

    def abate_end(c):
        if "abatementDateTime" in c:
            return pend(c["abatementDateTime"])
        if "abatementPeriod" in c:
            return pend((c["abatementPeriod"] or {}).get("end"))
        if "abatementAge" in c and birth:
            v = c["abatementAge"].get("value")
            return add_years(birth, int(v) + 1) - timedelta(days=1) if v is not None else None
        if "abatementRange" in c and birth:
            v = (c["abatementRange"].get("high") or {}).get("value")
            return add_years(birth, int(v) + 1) - timedelta(days=1) if v is not None else None
        return None

    def prev(c):
        return (onset_start(c), abate_end(c))

    def starts_on_or_before(c, d):
        s = onset_start(c)
        return s is not None and s <= d

    # ---------- initial population
    qual = False
    for vs in ["Office Visit", "Annual Wellness Visit",
               "Preventive Care Services Established Office Visit, 18 and Up",
               "Preventive Care Services Initial Office Visit, 18 and Up",
               "Home Healthcare Services", "Virtual Encounter", "Telephone Visits"]:
        for e in encs(vs):
            if enc_ok(e) and during(per(e), ps, pe):
                qual = True
    ip = age is not None and 52 <= age <= 74 and patient.get("gender") == "female" and qual

    # ---------- exclusions
    def hospice():
        for e in encs("Encounter Inpatient"):
            codes = concepts_codes((e.get("hospitalization") or {}).get("dischargeDisposition"))
            if enc_ok(e) and ((SNOMED, "428361000124107") in codes or (SNOMED, "428371000124100") in codes) \
                    and ends_during(per(e), ps, pe):
                return True
        for e in encs("Hospice Encounter"):
            if enc_ok(e) and overlaps(per(e), ps, pe):
                return True
        for o in obs({("http://loinc.org", "45755-6")}):
            if assess(o) and (SNOMED, "373066001") in concepts_codes(o.get("valueCodeableConcept")) \
                    and overlaps(interval(o, "effective"), ps, pe):
                return True
        for s in by.get("ServiceRequest", []):
            if in_vs(s.get("code"), V("Hospice Care Ambulatory")) and s.get("status") in ("active", "completed") \
                    and s.get("intent") == "order":
                a = pdate(s.get("authoredOn"))
                if a and ps <= a <= pe:
                    return True
        for p in procs("Hospice Care Ambulatory"):
            if proc_ok(p) and overlaps(interval(p, "performed"), ps, pe):
                return True
        for c in conds("Hospice Diagnosis"):
            if overlaps(prev(c), ps, pe):
                return True
        return False

    def palliative():
        for o in obs({("http://loinc.org", "71007-9")}):
            if assess(o) and overlaps(interval(o, "effective"), ps, pe):
                return True
        for c in conds("Palliative Care Diagnosis"):
            if overlaps(prev(c), ps, pe):
                return True
        for e in encs("Palliative Care Encounter"):
            if enc_ok(e) and overlaps(per(e), ps, pe):
                return True
        for p in procs("Palliative Care Intervention"):
            if proc_ok(p) and overlaps(interval(p, "performed"), ps, pe):
                return True
        return False

    def side_dx(statusvs, side_code):
        out = list(conds(statusvs))
        for c in conds("Unilateral Mastectomy, Unspecified Laterality"):
            if any((SNOMED, side_code) in concepts_codes(b) for b in c.get("bodySite", []) or []):
                out.append(c)
        return [c for c in out if starts_on_or_before(c, pe)]

    def proc_dx(vsname):
        res = []
        for p in procs(vsname):
            iv = interval(p, "performed")
            if proc_ok(p) and iv and iv[1] and iv[1] <= pe:
                res.append(p)
        return res

    right = side_dx("Status Post Right Mastectomy", "24028007") or proc_dx("Unilateral Mastectomy Right")
    left = side_dx("Status Post Left Mastectomy", "7771000") or proc_dx("Unilateral Mastectomy Left")
    bilateral = [c for c in conds("History of bilateral mastectomy") if starts_on_or_before(c, pe)] \
        or proc_dx("Bilateral Mastectomy")

    def frailty():
        for d in by.get("DeviceRequest", []):
            if in_vs(d.get("codeCodeableConcept"), V("Frailty Device")) \
                    and d.get("status") in ("active", "completed") and d.get("intent") == "order":
                a = pdate(d.get("authoredOn"))
                if a and ps <= a <= pe:
                    return True
        for o in obs({("http://loinc.org", "98181-1")}):
            if assess(o) and in_vs(o.get("valueCodeableConcept"), V("Frailty Device")) \
                    and ends_during(interval(o, "effective"), ps, pe):
                return True
        for c in conds("Frailty Diagnosis"):
            if overlaps(prev(c), ps, pe):
                return True
        for e in encs("Frailty Encounter"):
            if enc_ok(e) and overlaps(per(e), ps, pe):
                return True
        for o in obs(V("Frailty Symptom")):
            if o.get("status") in ("preliminary", "final", "amended", "corrected") \
                    and overlaps(interval(o, "effective"), ps, pe):
                return True
        return False

    def advanced_illness():
        a = add_years(ps, -1)
        for c in conds("Advanced Illness"):
            s = onset_start(c)
            if s and a <= s <= pe:
                return True
        return False

    def to_days(v, u):
        if v is None:
            return None
        f = {"d": 1, "day": 1, "days": 1, "wk": 7, "week": 7, "weeks": 7, "mo": 30, "month": 30,
             "months": 30, "a": 365, "year": 365, "years": 365, "h": 1 / 24, "hour": 1 / 24,
             "min": 1 / 1440}.get(u)
        return v * f if f else None

    def med_period(m):
        dos = m.get("dosageInstruction") or []
        dosage = dos[0] if len(dos) == 1 else {}
        dr = dosage.get("doseAndRate") or []
        dar = dr[0] if len(dr) == 1 else {}
        rep = (dosage.get("timing") or {}).get("repeat") or {}
        freq = rep.get("frequencyMax", rep.get("frequency"))
        perd = to_days(rep.get("period"), rep.get("periodUnit"))
        dpd = freq / perd if freq is not None and perd else None
        if dpd is None:
            tod = rep.get("timeOfDay")
            dpd = float(len(tod)) if tod else 1.0
        dose = None
        if "doseRange" in dar:
            dose = (dar["doseRange"].get("high") or {}).get("value")
        if dose is None and "doseQuantity" in dar:
            dose = dar["doseQuantity"].get("value")
        bounds = rep.get("boundsPeriod") or {}
        disp = m.get("dispenseRequest") or {}
        ds = None
        esd = disp.get("expectedSupplyDuration")
        if esd:
            ds = to_days(esd.get("value"), esd.get("code") or esd.get("unit"))
        qty = (disp.get("quantity") or {}).get("value")
        refills = disp.get("numberOfRepeatsAllowed") or 0
        start = pdate(bounds.get("start")) or pdate(m.get("authoredOn")) \
            or pdate((disp.get("validityPeriod") or {}).get("start"))
        total = None
        if ds is not None:
            total = ds * (1 + refills)
        elif qty is not None and dose and dpd:
            total = qty / (dose * dpd) * (1 + refills)
        if start and total is not None:
            return (start, start + timedelta(days=int(total - 1)))
        if start and bounds.get("end"):
            return (start, pdate(bounds["end"]))
        return None

    def dementia_meds():
        a = add_years(ps, -1)
        meds = {m.get("id"): m for m in by.get("Medication", [])}
        for m in by.get("MedicationRequest", []):
            if m.get("status") != "active" or m.get("intent") != "order":
                continue
            cc = m.get("medicationCodeableConcept")
            if cc is None and m.get("medicationReference"):
                ref = (m["medicationReference"].get("reference") or "").split("/")[-1]
                cc = (meds.get(ref) or {}).get("code")
            if in_vs(cc, V("Dementia Medications")) and overlaps(med_period(m), a, pe):
                return True
        return False

    def nursing_home():
        best = None
        for o in obs({("http://loinc.org", "71802-3")}):
            iv = interval(o, "effective")
            if assess(o) and iv and iv[1] and iv[1] <= pe:
                if best is None or iv[1] >= best[0]:
                    best = (iv[1], o)
        return bool(best and (SNOMED, "160734000") in concepts_codes(best[1].get("valueCodeableConcept")))

    aif = age is not None and age >= 66 and frailty() and (advanced_illness() or dementia_meds())
    nh = age is not None and age >= 66 and nursing_home()

    excl = hospice() or (bool(right) and bool(left)) or bool(bilateral) or aif or nh or palliative()

    # ---------- numerator
    a = date(ps.year - 2, 10, 1)
    num = any(obs_perf(o) and ends_during(interval(o, "effective"), a, pe) for o in obs(V("Mammography")))

    ex = bool(ip and excl)
    return {"initial-population": bool(ip), "denominator": bool(ip),
            "denominator-exclusion": ex, "numerator": bool(ip and not ex and num)}
