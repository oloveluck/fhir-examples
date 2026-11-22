import calendar
from datetime import date, timedelta

SNO = "http://snomed.info/sct"
OBSCAT = "http://terminology.hl7.org/CodeSystem/observation-category"


def _d(s, end=False):
    """Date part of an ISO date/dateTime string (partial dates padded)."""
    if not s:
        return None
    p = s[:10].split("-")
    try:
        y = int(p[0])
        m = int(p[1]) if len(p) > 1 else (12 if end else 1)
        dd = int(p[2]) if len(p) > 2 else (calendar.monthrange(y, m)[1] if end else 1)
        return date(y, m, dd)
    except Exception:
        return None


def _add_years(d, n):
    try:
        return d.replace(year=d.year + n)
    except ValueError:
        return d.replace(year=d.year + n, day=28)


def _codes(cc):
    out = set()
    if not isinstance(cc, dict):
        return out
    for c in cc.get("coding", []) or []:
        out.add((c.get("system"), c.get("code")))
    return out


def _in(cc, vs):
    if isinstance(cc, list):
        return any(_in(x, vs) for x in cc)
    return bool(_codes(cc) & vs)


def _has(cc, system, code):
    if isinstance(cc, list):
        return any(_has(x, system, code) for x in cc)
    return (system, code) in _codes(cc)


def _interval(r, prefix, birth=None):
    """(lo, hi) dates of a choice-typed element; None bound = unbounded; None if absent."""
    if prefix + "DateTime" in r:
        d = _d(r[prefix + "DateTime"])
        return (d, d) if d else None
    if prefix + "Instant" in r:
        d = _d(r[prefix + "Instant"])
        return (d, d) if d else None
    if prefix + "Period" in r:
        p = r[prefix + "Period"]
        return (_d(p.get("start")), _d(p.get("end"), True))
    if prefix + "Age" in r and birth:
        v = r[prefix + "Age"].get("value")
        if v is not None:
            return (_add_years(birth, int(v)), _add_years(birth, int(v) + 1) - timedelta(days=1))
    if prefix + "Range" in r and birth:
        q = r[prefix + "Range"]
        try:
            return (_add_years(birth, int(q["low"]["value"])),
                    _add_years(birth, int(q["high"]["value"]) + 1) - timedelta(days=1))
        except Exception:
            return None
    return None


def _per(e):
    p = e.get("period")
    if not p:
        return None
    return (_d(p.get("start")), _d(p.get("end"), True))


def _overlaps(iv, a, b):
    if iv is None:
        return False
    lo, hi = iv
    return (lo is None or lo <= b) and (hi is None or hi >= a)


def _during(iv, a, b):
    if iv is None or iv[0] is None or iv[1] is None:
        return False
    return a <= iv[0] and iv[1] <= b


def _ends_during(iv, a, b):
    return iv is not None and iv[1] is not None and a <= iv[1] <= b


def _medperiod(m):
    di = m.get("dosageInstruction") or []
    if len(di) > 1:
        return None
    dosage = di[0] if di else {}
    dr = dosage.get("doseAndRate") or []
    if len(dr) > 1:
        return None
    dar = dr[0] if dr else {}
    rep = (dosage.get("timing") or {}).get("repeat") or {}
    freq = rep.get("frequencyMax", rep.get("frequency"))
    unit_days = {"s": 1 / 86400, "min": 1 / 1440, "h": 1 / 24, "d": 1, "wk": 7, "mo": 30, "a": 365}
    per = rep.get("period")
    pu = rep.get("periodUnit")
    perday = None
    if freq is not None and per and pu in unit_days:
        perday = freq / (per * unit_days[pu])
    if perday is None:
        perday = len(rep.get("timeOfDay") or [])
    bounds = rep.get("boundsPeriod")
    dose = None
    if "doseRange" in dar:
        dose = (dar["doseRange"].get("high") or {}).get("value")
    if dose is None and "doseQuantity" in dar:
        dose = dar["doseQuantity"].get("value")
    dispense = m.get("dispenseRequest") or {}
    ds = None
    esd = dispense.get("expectedSupplyDuration")
    if esd and esd.get("value") is not None:
        u = esd.get("code") or esd.get("unit")
        f = {"d": 1, "day": 1, "days": 1, "wk": 7, "week": 7, "weeks": 7, "mo": 30, "month": 30, "a": 365}.get(u)
        if f:
            ds = esd["value"] * f
    q = (dispense.get("quantity") or {}).get("value")
    refills = dispense.get("numberOfRepeatsAllowed") or 0
    start = _d(bounds.get("start")) if bounds else None
    if start is None:
        start = _d(m.get("authoredOn"))
    if start is None:
        start = _d((dispense.get("validityPeriod") or {}).get("start"))
    base = ds
    if base is None and q is not None and dose and perday:
        base = q / (dose * perday)
    total = base * (1 + refills) if base is not None else None
    if start is not None and total is not None:
        return (start, start + timedelta(days=int(total - 1)))
    if start is not None and bounds and bounds.get("end"):
        return (start, _d(bounds["end"], True))
    return None


def evaluate(resources, valuesets, period_start, period_end):
    ps, pe = _d(period_start), _d(period_end, True)
    by = {}
    patient = None
    for r in resources:
        t = r.get("resourceType")
        by.setdefault(t, []).append(r)
        if t == "Patient":
            patient = r

    def vs(n):
        return valuesets.get(n, set())

    def one(system, code):
        return {(system, code)}

    birth = _d(patient.get("birthDate")) if patient else None
    age = None
    if birth:
        age = pe.year - birth.year - ((pe.month, pe.day) < (birth.month, birth.day))

    ENC_OK = {"finished", "arrived", "triaged", "in-progress", "onleave"}

    def encs(valueset):
        return [e for e in by.get("Encounter", [])
                if e.get("status") in ENC_OK and _in(e.get("type", []), valueset)]

    enc_vs = set()
    for n in ["Office Visit", "Annual Wellness Visit",
              "Preventive Care Services Established Office Visit, 18 and Up",
              "Preventive Care Services Initial Office Visit, 18 and Up",
              "Home Healthcare Services", "Virtual Encounter", "Telephone Visits"]:
        enc_vs |= vs(n)
    qual = [e for e in encs(enc_vs) if _during(_per(e), ps, pe)]
    ip = bool(age is not None and 52 <= age <= 74 and patient.get("gender") == "female" and qual)

    res = {"initial-population": ip, "denominator": ip,
           "denominator-exclusion": False, "numerator": False}
    if not ip:
        return res

    def conds(valueset):
        return [c for c in by.get("Condition", []) if _in(c.get("code"), valueset)]

    def prevalence(c):
        onset = _interval(c, "onset", birth)
        if onset is None or onset[0] is None:
            return None
        ab = _interval(c, "abatement", birth)
        return (onset[0], ab[1] if ab else None)

    def procs(valueset):
        return [p for p in by.get("Procedure", [])
                if p.get("status") == "completed" and _in(p.get("code"), valueset)]

    def obs(valueset, cat=None, statuses=("final", "amended", "corrected")):
        out = []
        for o in by.get("Observation", []):
            if o.get("status") not in statuses or not _in(o.get("code"), valueset):
                continue
            if cat and not any(_has(c, OBSCAT, cat) for c in o.get("category", []) or []):
                continue
            out.append(o)
        return out

    def starts_by_end(c):
        p = prevalence(c)
        return p is not None and p[0] <= pe

    def proc_done(p):
        iv = _interval(p, "performed")
        return iv is not None and iv[1] is not None and iv[1] <= pe

    def lateral(side):
        name = "Status Post Right Mastectomy" if side == "R" else "Status Post Left Mastectomy"
        lst = list(conds(vs(name)))
        code = "24028007" if side == "R" else "7771000"
        for c in conds(vs("Unilateral Mastectomy, Unspecified Laterality")):
            if any(_has(s, SNO, code) for s in c.get("bodySite", []) or []):
                lst.append(c)
        return any(starts_by_end(c) for c in lst)

    right = lateral("R") or any(proc_done(p) for p in procs(vs("Unilateral Mastectomy Right")))
    left = lateral("L") or any(proc_done(p) for p in procs(vs("Unilateral Mastectomy Left")))
    bilateral = (any(starts_by_end(c) for c in conds(vs("History of bilateral mastectomy")))
                 or any(proc_done(p) for p in procs(vs("Bilateral Mastectomy"))))

    def cond_overlaps(valueset):
        return any(_overlaps(prevalence(c), ps, pe) for c in conds(valueset))

    def hospice():
        for e in encs(vs("Encounter Inpatient")):
            dd = e.get("hospitalization", {}).get("dischargeDisposition")
            if (_has(dd, SNO, "428361000124107") or _has(dd, SNO, "428371000124100")) \
                    and _ends_during(_per(e), ps, pe):
                return True
        if any(_overlaps(_per(e), ps, pe) for e in encs(vs("Hospice Encounter"))):
            return True
        for o in obs(one("http://loinc.org", "45755-6"), "survey"):
            if _has(o.get("valueCodeableConcept"), SNO, "373066001") and \
                    _overlaps(_interval(o, "effective"), ps, pe):
                return True
        for s in by.get("ServiceRequest", []):
            if s.get("status") in ("active", "completed") and s.get("intent") == "order" \
                    and _in(s.get("code"), vs("Hospice Care Ambulatory")):
                d = _d(s.get("authoredOn"))
                if d and ps <= d <= pe:
                    return True
        for p in procs(vs("Hospice Care Ambulatory")):
            if _overlaps(_interval(p, "performed"), ps, pe):
                return True
        return cond_overlaps(vs("Hospice Diagnosis"))

    def palliative():
        if any(_overlaps(_interval(o, "effective"), ps, pe)
               for o in obs(one("http://loinc.org", "71007-9"), "survey")):
            return True
        if cond_overlaps(vs("Palliative Care Diagnosis")):
            return True
        if any(_overlaps(_per(e), ps, pe) for e in encs(vs("Palliative Care Encounter"))):
            return True
        return any(_overlaps(_interval(p, "performed"), ps, pe)
                   for p in procs(vs("Palliative Care Intervention")))

    def frailty():
        for d in by.get("DeviceRequest", []):
            if d.get("status") in ("active", "completed") and d.get("intent") == "order" \
                    and d.get("doNotPerform") is not True \
                    and _in(d.get("codeCodeableConcept"), vs("Frailty Device")):
                a = _d(d.get("authoredOn"))
                if a and ps <= a <= pe:
                    return True
        for o in obs(one("http://loinc.org", "98181-1"), "survey"):
            if _in(o.get("valueCodeableConcept"), vs("Frailty Device")) and \
                    _ends_during(_interval(o, "effective"), ps, pe):
                return True
        if cond_overlaps(vs("Frailty Diagnosis")):
            return True
        if any(_overlaps(_per(e), ps, pe) for e in encs(vs("Frailty Encounter"))):
            return True
        for o in obs(vs("Frailty Symptom"), None, ("preliminary", "final", "amended", "corrected")):
            if _overlaps(_interval(o, "effective"), ps, pe):
                return True
        return False

    yb = date(ps.year - 1, ps.month, ps.day)

    def advanced():
        for c in conds(vs("Advanced Illness")):
            p = prevalence(c)
            if p and yb <= p[0] <= pe:
                return True
        for m in by.get("MedicationRequest", []):
            if m.get("status") == "active" and m.get("intent") == "order" \
                    and _in(m.get("medicationCodeableConcept"), vs("Dementia Medications")):
                if _overlaps(_medperiod(m), yb, pe):
                    return True
        return False

    def nursing_home():
        cand = []
        for o in obs(one("http://loinc.org", "71802-3"), "survey"):
            iv = _interval(o, "effective")
            if iv is not None and iv[1] is not None and iv[1] <= pe:
                cand.append((iv[1], o))
        if not cand:
            return False
        cand.sort(key=lambda x: x[0])
        return _has(cand[-1][1].get("valueCodeableConcept"), SNO, "160734000")

    excl = bool(hospice() or (right and left) or bilateral
                or (age >= 66 and ((frailty() and advanced()) or nursing_home()))
                or palliative())
    res["denominator-exclusion"] = excl
    if excl:
        return res

    lo = date(ps.year - 2, 10, 1)
    res["numerator"] = any(_ends_during(_interval(o, "effective"), lo, pe)
                           for o in obs(vs("Mammography")))
    return res
