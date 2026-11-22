from datetime import date, timedelta

INF_LO = date.min
INF_HI = date.max
SURVEY_SYS = "http://terminology.hl7.org/CodeSystem/observation-category"


def _d(s):
    if not s:
        return None
    try:
        return date(int(s[0:4]), int(s[5:7]) if len(s) >= 7 else 1, int(s[8:10]) if len(s) >= 10 else 1)
    except Exception:
        return None


def _codes(cc):
    out = set()
    if not isinstance(cc, dict):
        return out
    for c in cc.get("coding", []) or []:
        out.add((c.get("system"), c.get("code")))
    return out


def _in(cc, vs):
    return bool(_codes(cc) & vs)


def _add_years(d, n):
    try:
        return d.replace(year=d.year + n)
    except ValueError:
        return d.replace(year=d.year + n, day=28)


def _age_date(birth, q):
    try:
        v = int(q.get("value"))
    except Exception:
        return None
    u = q.get("code") or q.get("unit") or "a"
    if u in ("a", "year", "years"):
        return _add_years(birth, v)
    return None


def _choice(res, base, birth=None):
    """Normalize a [x] timing choice to (lo, hi) dates; None if absent."""
    for k in ("DateTime", "Instant", "Date"):
        if base + k in res:
            d = _d(res[base + k])
            return (d, d) if d else None
    if base + "Period" in res:
        p = res[base + "Period"]
        return (_d(p.get("start")), _d(p.get("end")))
    if base + "Age" in res and birth:
        lo = _age_date(birth, res[base + "Age"])
        if lo is None:
            return None
        return (lo, _add_years(lo, 1) - timedelta(days=1))
    if base + "Range" in res and birth:
        r = res[base + "Range"]
        lo = _age_date(birth, r.get("low", {}))
        hi = _age_date(birth, r.get("high", {}))
        if lo is None or hi is None:
            return None
        return (lo, _add_years(hi, 1) - timedelta(days=1))
    return None


def _overlaps(iv, a, b):
    if iv is None:
        return False
    lo, hi = iv
    if lo is None and hi is None:
        return False
    lo = lo or INF_LO
    hi = hi or INF_HI
    return lo <= b and a <= hi


def _during(iv, a, b):
    if iv is None or iv[0] is None or iv[1] is None:
        return False
    return a <= iv[0] and iv[1] <= b


def evaluate(resources, valuesets, period_start, period_end):
    ps, pe = _d(period_start), _d(period_end)
    by = {}
    patient = None
    for r in resources:
        by.setdefault(r.get("resourceType"), []).append(r)
        if r.get("resourceType") == "Patient":
            patient = r
    birth = _d((patient or {}).get("birthDate"))

    def vs(n):
        return valuesets.get(n, set())

    def prevalence(c):
        on = _choice(c, "onset", birth)
        if on is None or on[0] is None:
            return None
        ab = _choice(c, "abatement", birth)
        return (on[0], ab[1] if ab is not None else None)

    def cond_overlap(name):
        for c in by.get("Condition", []):
            if _in(c.get("code"), vs(name)) and _overlaps(prevalence(c), ps, pe):
                return True
        return False

    def enc_ok(e):
        return e.get("status") in ("finished", "arrived", "triaged", "in-progress", "onleave")

    def enc_period(e):
        p = e.get("period") or {}
        return (_d(p.get("start")), _d(p.get("end")))

    def encs(name):
        return [e for e in by.get("Encounter", [])
                if enc_ok(e) and any(_in(t, vs(name)) for t in e.get("type", []) or [])]

    def obs_cat(o, cat):
        for c in o.get("category", []) or []:
            if (SURVEY_SYS, cat) in _codes(c):
                return True
        return False

    # ---- initial population
    age = None
    age_ok = False
    if birth:
        age = pe.year - birth.year - ((pe.month, pe.day) < (birth.month, birth.day))
        age_ok = 18 <= age <= 75
    qual = False
    for n in ["Office Visit", "Annual Wellness Visit",
              "Preventive Care Services Established Office Visit, 18 and Up",
              "Preventive Care Services Initial Office Visit, 18 and Up",
              "Home Healthcare Services", "Virtual Encounter", "Telephone Visits"]:
        if any(_during(enc_period(e), ps, pe) for e in encs(n)):
            qual = True
    ip = bool(age_ok and qual and cond_overlap("Diabetes"))

    # ---- exclusions
    def hospice():
        for e in encs("Encounter Inpatient"):
            dd = (e.get("hospitalization") or {}).get("dischargeDisposition")
            c = _codes(dd)
            if (("http://snomed.info/sct", "428361000124107") in c
                    or ("http://snomed.info/sct", "428371000124100") in c):
                iv = enc_period(e)
                if iv[1] and ps <= iv[1] <= pe:
                    return True
        if any(_overlaps(enc_period(e), ps, pe) for e in encs("Hospice Encounter")):
            return True
        for o in by.get("Observation", []):
            if (o.get("status") in ("final", "amended", "corrected") and obs_cat(o, "survey")
                    and ("http://loinc.org", "45755-6") in _codes(o.get("code"))
                    and ("http://snomed.info/sct", "373066001") in _codes(o.get("valueCodeableConcept"))
                    and _overlaps(_choice(o, "effective"), ps, pe)):
                return True
        for s in by.get("ServiceRequest", []):
            if (s.get("status") in ("active", "completed") and s.get("intent") == "order"
                    and _in(s.get("code"), vs("Hospice Care Ambulatory"))):
                d = _d(s.get("authoredOn"))
                if d and ps <= d <= pe:
                    return True
        for p in by.get("Procedure", []):
            if (p.get("status") == "completed" and _in(p.get("code"), vs("Hospice Care Ambulatory"))
                    and _overlaps(_choice(p, "performed", birth), ps, pe)):
                return True
        return cond_overlap("Hospice Diagnosis")

    def palliative():
        for o in by.get("Observation", []):
            if (o.get("status") in ("final", "amended", "corrected") and obs_cat(o, "survey")
                    and ("http://loinc.org", "71007-9") in _codes(o.get("code"))
                    and _overlaps(_choice(o, "effective"), ps, pe)):
                return True
        if cond_overlap("Palliative Care Diagnosis"):
            return True
        if any(_overlaps(enc_period(e), ps, pe) for e in encs("Palliative Care Encounter")):
            return True
        for p in by.get("Procedure", []):
            if (p.get("status") == "completed" and _in(p.get("code"), vs("Palliative Care Intervention"))
                    and _overlaps(_choice(p, "performed", birth), ps, pe)):
                return True
        return False

    HOURS = {"h": 1, "hour": 1, "hours": 1, "d": 24, "day": 24, "days": 24, "wk": 168, "week": 168,
             "weeks": 168, "mo": 720, "month": 720, "months": 720, "a": 8760, "year": 8760, "years": 8760}

    def med_period(m):
        dosage = m.get("dosageInstruction") or []
        dos = dosage[0] if len(dosage) == 1 else {}
        dr = dos.get("doseAndRate") or []
        dr = dr[0] if len(dr) == 1 else {}
        rep = (dos.get("timing") or {}).get("repeat") or {}
        freq = rep.get("frequencyMax") or rep.get("frequency")
        per, pu = rep.get("period"), rep.get("periodUnit")
        dpd = None
        if freq and per and pu in HOURS:
            # ToDaily: frequency * (24 / period) / (24 * days-per-unit); hour units: no further division
            dpd = freq * (24.0 / per) if HOURS[pu] == 1 else freq * (24.0 / per) / HOURS[pu]
        if dpd is None:
            tod = rep.get("timeOfDay")
            dpd = float(len(tod)) if tod else 1.0
        bounds = rep.get("boundsPeriod") or {}
        bs, be = _d(bounds.get("start")), _d(bounds.get("end"))
        dispense = m.get("dispenseRequest") or {}
        start = bs or _d(m.get("authoredOn")) or _d((dispense.get("validityPeriod") or {}).get("start"))
        dose = (dr.get("doseQuantity") or {}).get("value")
        if dose is None:
            dose = ((dr.get("doseRange") or {}).get("high") or {}).get("value")
        sup = dispense.get("expectedSupplyDuration")
        days = None
        if sup and sup.get("value") is not None:
            mult = {"d": 1, "day": 1, "days": 1, "wk": 7, "week": 7, "weeks": 7, "mo": 30, "month": 30,
                    "months": 30, "a": 365, "year": 365}.get(sup.get("code") or sup.get("unit"))
            if mult:
                days = sup["value"] * mult
        if days is None:
            q = (dispense.get("quantity") or {}).get("value")
            if q is not None and dose:
                days = q / (dose * dpd)
        total = None if days is None else days * (1 + (dispense.get("numberOfRepeatsAllowed") or 0))
        if start and total is not None:
            return (start, start + timedelta(days=int(total - 1)))
        if start and be:
            return (start, be)
        return None

    def frailty():
        for r in by.get("DeviceRequest", []):
            if (r.get("status") in ("active", "completed") and r.get("intent") == "order"
                    and _in(r.get("codeCodeableConcept"), vs("Frailty Device"))
                    and r.get("doNotPerform") is not True):
                d = _d(r.get("authoredOn"))
                if d and ps <= d <= pe:
                    return True
        for o in by.get("Observation", []):
            st = o.get("status")
            if (st in ("final", "amended", "corrected") and obs_cat(o, "survey")
                    and ("http://loinc.org", "98181-1") in _codes(o.get("code"))
                    and _in(o.get("valueCodeableConcept"), vs("Frailty Device"))):
                iv = _choice(o, "effective")
                if iv and iv[1] and ps <= iv[1] <= pe:
                    return True
            if (st in ("preliminary", "final", "amended", "corrected")
                    and _in(o.get("code"), vs("Frailty Symptom"))
                    and _overlaps(_choice(o, "effective"), ps, pe)):
                return True
        if cond_overlap("Frailty Diagnosis"):
            return True
        return any(_overlaps(enc_period(e), ps, pe) for e in encs("Frailty Encounter"))

    def advanced():
        a = _add_years(ps, -1)
        for c in by.get("Condition", []):
            if _in(c.get("code"), vs("Advanced Illness")):
                p = prevalence(c)
                if p and a <= p[0] <= pe:
                    return True
        return False

    def dementia():
        a = _add_years(ps, -1)
        for m in by.get("MedicationRequest", []):
            if (m.get("status") == "active" and m.get("intent") == "order"
                    and _in(m.get("medicationCodeableConcept"), vs("Dementia Medications"))
                    and _overlaps(med_period(m), a, pe)):
                return True
        return False

    def nursing_home():
        best = None
        for o in by.get("Observation", []):
            if (o.get("status") in ("final", "amended", "corrected") and obs_cat(o, "survey")
                    and ("http://loinc.org", "71802-3") in _codes(o.get("code"))):
                iv = _choice(o, "effective")
                if iv is None or iv[1] is None or iv[1] > pe:
                    continue
                if best is None or iv[1] >= best[0]:
                    best = (iv[1], o)
        return bool(best and ("http://snomed.info/sct", "160734000") in _codes(best[1].get("valueCodeableConcept")))

    old = bool(age is not None and age >= 66)
    excl = False
    if ip:
        excl = bool(hospice() or (old and nursing_home())
                    or (old and frailty() and (advanced() or dementia())) or palliative())

    # ---- numerator
    num = False
    if ip and not excl:
        gsa = []
        names = vs("HbA1c Laboratory Test") | {("http://loinc.org", "97506-0")}
        for o in by.get("Observation", []):
            if (o.get("status") in ("final", "amended", "corrected") and obs_cat(o, "laboratory")
                    and _codes(o.get("code")) & names):
                iv = _choice(o, "effective")
                if iv is None:
                    continue
                lat = iv[1] or iv[0]
                if lat is None or not (ps <= lat <= pe):
                    continue
                q = o.get("valueQuantity")
                val = None
                if isinstance(q, dict) and q.get("value") is not None:
                    val = (q["value"], q.get("unit") or q.get("code"))
                gsa.append((lat, val))
        if not gsa:
            num = True
        else:
            last = max(g[0] for g in gsa)
            day = [g for g in gsa if g[0] == last]
            day.sort(key=lambda g: (g[1] is not None, g[1][0] if g[1] else 0))
            low = day[0]
            if low[1] is None:
                num = True
            else:
                num = low[1][0] > 9 and low[1][1] in ("%", None)
    return {"initial-population": ip, "denominator": ip,
            "denominator-exclusion": excl, "numerator": bool(num)}
