import datetime as _dt

LOINC = "http://loinc.org"
SNOMED = "http://snomed.info/sct"
OBS_CAT = "http://terminology.hl7.org/CodeSystem/observation-category"


# ---------- helpers ----------
def _d(s):
    """date part of a FHIR date/dateTime string"""
    if not s:
        return None
    try:
        return _dt.date.fromisoformat(str(s)[:10])
    except ValueError:
        try:
            y = str(s)[:7]
            return _dt.date.fromisoformat(y + "-01")
        except ValueError:
            return None


def _codings(cc):
    if not cc:
        return []
    return [(c.get("system"), c.get("code")) for c in cc.get("coding", []) if c.get("code")]


def _in(cc, vs):
    return any(c in vs for c in _codings(cc))


def _has_code(cc, system, code):
    return (system, code) in _codings(cc)


def _cats(res):
    out = []
    for cc in res.get("category", []) or []:
        out.extend(_codings(cc))
    return out


def _has_cat(res, code):
    return (OBS_CAT, code) in _cats(res)


def _ov(a, b):
    """overlap of closed day ranges; None = unbounded"""
    (al, ah), (bl, bh) = a, b
    if ah is not None and bl is not None and ah < bl:
        return False
    if bh is not None and al is not None and bh < al:
        return False
    return True


def _during(iv, per):
    lo, hi = iv
    pl, ph = per
    if lo is None or hi is None:
        return False
    return pl <= lo and hi <= ph


def _eff(res, names=("effective",)):
    """toInterval of effective[x]/performed[x]; returns (lo, hi) dates or None"""
    for n in names:
        if n + "DateTime" in res:
            d = _d(res[n + "DateTime"])
            return (d, d) if d else None
        if n + "Instant" in res:
            d = _d(res[n + "Instant"])
            return (d, d) if d else None
        if n + "Period" in res:
            p = res[n + "Period"]
            lo, hi = _d(p.get("start")), _d(p.get("end"))
            return (lo, hi)
    return None


def _latest(iv):
    if iv is None:
        return None
    lo, hi = iv
    return hi if hi is not None else lo


def _by_type(resources, t):
    return [r for r in resources if r.get("resourceType") == t]


def _age_years(birth, at):
    return at.year - birth.year - ((at.month, at.day) < (birth.month, birth.day))


def _add_years(birth, n):
    try:
        return birth.replace(year=birth.year + int(n))
    except ValueError:
        return birth.replace(year=birth.year + int(n), day=28)


def _prevalence(cond, birth):
    status = _codings(cond.get("clinicalStatus"))
    active = any(c[1] in ("active", "recurrence", "relapse") for c in status)
    # onset
    lo = None
    if "onsetDateTime" in cond:
        lo = _d(cond["onsetDateTime"])
    elif "onsetPeriod" in cond:
        lo = _d(cond["onsetPeriod"].get("start"))
    elif "onsetAge" in cond and birth:
        lo = _add_years(birth, cond["onsetAge"].get("value", 0))
    elif "onsetRange" in cond and birth:
        lo = _add_years(birth, (cond["onsetRange"].get("low") or {}).get("value", 0))
    # abatement
    hi = None
    if "abatementDateTime" in cond:
        hi = _d(cond["abatementDateTime"])
    elif "abatementPeriod" in cond:
        hi = _d(cond["abatementPeriod"].get("end"))
    elif "abatementAge" in cond and birth:
        hi = _add_years(birth, cond["abatementAge"].get("value", 0) + 1) - _dt.timedelta(days=1)
    elif "abatementRange" in cond and birth:
        hi = _add_years(birth, (cond["abatementRange"].get("high") or {}).get("value", 0) + 1) - _dt.timedelta(days=1)
    return (lo, hi)


def _num_days(value, unit):
    f = {"s": 1 / 86400, "min": 1 / 1440, "h": 1 / 24, "d": 1, "wk": 7, "mo": 30, "a": 365}
    u = {"second": "s", "minute": "min", "hour": "h", "day": "d", "week": "wk", "month": "mo", "year": "a"}.get(unit, unit)
    if u in f and value is not None:
        return value * f[u]
    return None


def _med_period(mr):
    """medicationRequestPeriod -> (lo, hi) dates or None"""
    di = mr.get("dosageInstruction") or []
    dosage = di[0] if len(di) == 1 else ({} if not di else None)
    if dosage is None:
        return None
    dr = dosage.get("doseAndRate") or []
    dar = dr[0] if len(dr) == 1 else {}
    timing = dosage.get("timing") or {}
    rep = timing.get("repeat") or {}
    freq = rep.get("frequencyMax", rep.get("frequency"))
    per = None
    if rep.get("period") is not None:
        per = _num_days(rep["period"], rep.get("periodUnit"))
    dose = None
    if "doseQuantity" in dar:
        dose = dar["doseQuantity"].get("value")
    elif "doseRange" in dar:
        dose = (dar["doseRange"].get("high") or {}).get("value")
    daily = None
    if freq is not None and per:
        daily = freq / per
    if daily is None:
        daily = len(rep["timeOfDay"]) if rep.get("timeOfDay") else 1.0
    bounds = rep.get("boundsPeriod") or {}
    dreq = mr.get("dispenseRequest") or {}
    sup = dreq.get("expectedSupplyDuration")
    days_supply = None
    if sup:
        days_supply = _num_days(sup.get("value"), sup.get("code") or sup.get("unit"))
    qty = (dreq.get("quantity") or {}).get("value")
    refills = dreq.get("numberOfRepeatsAllowed", 0) or 0
    start = _d(bounds.get("start")) or _d(mr.get("authoredOn")) or _d((dreq.get("validityPeriod") or {}).get("start"))
    total = None
    if days_supply is not None:
        total = days_supply * (1 + refills)
    elif qty is not None and dose:
        total = qty / (dose * daily) * (1 + refills)
    bend = _d(bounds.get("end"))
    if start is not None and total is not None:
        return (start, start + _dt.timedelta(days=int(total - 1)))
    if start is not None and bend is not None:
        return (start, bend)
    return None


def evaluate(resources, valuesets, period_start, period_end):
    vs = lambda n: valuesets.get(n, set())
    ps, pe = _d(period_start), _d(period_end)
    MP = (ps, pe)
    patient = (_by_type(resources, "Patient") or [{}])[0]
    birth = _d(patient.get("birthDate"))

    res = {"initial-population": False, "denominator": False,
           "denominator-exclusion": False, "numerator": False}
    if birth is None:
        return res

    # ---- initial population ----
    age = _age_years(birth, pe)
    ok_age = 18 <= age <= 75

    enc_sets = ["Office Visit", "Annual Wellness Visit",
                "Preventive Care Services Established Office Visit, 18 and Up",
                "Preventive Care Services Initial Office Visit, 18 and Up",
                "Home Healthcare Services", "Virtual Encounter", "Telephone Visits"]
    enc_ok = {"finished", "arrived", "triaged", "in-progress", "onleave"}
    encounters = _by_type(resources, "Encounter")

    def enc_in(e, names):
        return any(_in(t, vs(n)) for t in e.get("type", []) or [] for n in names)

    def enc_period(e):
        p = e.get("period")
        if not p:
            return None
        return (_d(p.get("start")), _d(p.get("end")))

    qual_enc = any(
        e.get("status") in enc_ok and enc_in(e, enc_sets)
        and enc_period(e) and _during(enc_period(e), MP)
        for e in encounters)

    conditions = _by_type(resources, "Condition")
    diabetes = any(_in(c.get("code"), vs("Diabetes")) and _ov(_prevalence(c, birth), MP)
                   for c in conditions)

    ip = ok_age and qual_enc and diabetes
    res["initial-population"] = ip
    res["denominator"] = ip
    if not ip:
        return res

    # ---- exclusions ----
    observations = _by_type(resources, "Observation")
    procedures = _by_type(resources, "Procedure")

    def obs_status(o, sts):
        return o.get("status") in sts

    def assessment(o):
        return obs_status(o, ("final", "amended", "corrected")) and _has_cat(o, "survey")

    def obs_code(o, system, code):
        return _has_code(o.get("code"), system, code)

    def cc_val(o):
        return o.get("valueCodeableConcept")

    def proc_iv(p):
        return _eff(p, ("performed",))

    # hospice
    hospice = False
    for e in encounters:
        if e.get("status") not in enc_ok:
            continue
        if enc_in(e, ["Encounter Inpatient"]):
            dd = (e.get("hospitalization") or {}).get("dischargeDisposition")
            if dd and (_has_code(dd, SNOMED, "428361000124107") or _has_code(dd, SNOMED, "428371000124100")):
                p = enc_period(e)
                if p and p[1] is not None and ps <= p[1] <= pe:
                    hospice = True
        if enc_in(e, ["Hospice Encounter"]):
            p = enc_period(e)
            if p and _ov(p, MP):
                hospice = True
    for o in observations:
        if assessment(o) and obs_code(o, LOINC, "45755-6") and cc_val(o) and _has_code(cc_val(o), SNOMED, "373066001"):
            iv = _eff(o)
            if iv and _ov(iv, MP):
                hospice = True
    for s in _by_type(resources, "ServiceRequest"):
        if s.get("status") in ("active", "completed") and s.get("intent") == "order" \
                and _in(s.get("code"), vs("Hospice Care Ambulatory")):
            a = _d(s.get("authoredOn"))
            if a and ps <= a <= pe:
                hospice = True
    for p in procedures:
        if p.get("status") == "completed" and _in(p.get("code"), vs("Hospice Care Ambulatory")):
            iv = proc_iv(p)
            if iv and _ov(iv, MP):
                hospice = True
    for c in conditions:
        if _in(c.get("code"), vs("Hospice Diagnosis")) and _ov(_prevalence(c, birth), MP):
            hospice = True

    # palliative
    palliative = False
    for o in observations:
        if assessment(o) and obs_code(o, LOINC, "71007-9"):
            iv = _eff(o)
            if iv and _ov(iv, MP):
                palliative = True
    for c in conditions:
        if _in(c.get("code"), vs("Palliative Care Diagnosis")) and _ov(_prevalence(c, birth), MP):
            palliative = True
    for e in encounters:
        if e.get("status") in enc_ok and enc_in(e, ["Palliative Care Encounter"]):
            p = enc_period(e)
            if p and _ov(p, MP):
                palliative = True
    for p in procedures:
        if p.get("status") == "completed" and _in(p.get("code"), vs("Palliative Care Intervention")):
            iv = proc_iv(p)
            if iv and _ov(iv, MP):
                palliative = True

    # nursing home / frailty / advanced illness (age >= 66)
    nursing = frail_ai = False
    if age >= 66:
        hs = []
        for o in observations:
            if assessment(o) and obs_code(o, LOINC, "71802-3"):
                iv = _eff(o)
                if iv and iv[1] is not None and iv[1] <= pe:
                    hs.append((iv[1], o))
        if hs:
            hs.sort(key=lambda x: x[0])
            last = hs[-1][1]
            if cc_val(last) and _has_code(cc_val(last), SNOMED, "160734000"):
                nursing = True

        frailty = False
        for d in _by_type(resources, "DeviceRequest"):
            if d.get("status") in ("active", "completed") and d.get("intent") == "order" \
                    and d.get("doNotPerform") is not True and _in(d.get("codeCodeableConcept"), vs("Frailty Device")):
                a = _d(d.get("authoredOn"))
                if a and ps <= a <= pe:
                    frailty = True
        for o in observations:
            if assessment(o) and obs_code(o, LOINC, "98181-1") and _in(cc_val(o), vs("Frailty Device")):
                iv = _eff(o)
                if iv and iv[1] is not None and ps <= iv[1] <= pe:
                    frailty = True
            if o.get("status") in ("preliminary", "final", "amended", "corrected") \
                    and _in(o.get("code"), vs("Frailty Symptom")):
                iv = _eff(o)
                if iv and _ov(iv, MP):
                    frailty = True
        for c in conditions:
            if _in(c.get("code"), vs("Frailty Diagnosis")) and _ov(_prevalence(c, birth), MP):
                frailty = True
        for e in encounters:
            if e.get("status") in enc_ok and enc_in(e, ["Frailty Encounter"]):
                p = enc_period(e)
                if p and _ov(p, MP):
                    frailty = True

        adv = False
        wide = (_dt.date(ps.year - 1, ps.month, ps.day), pe)
        for c in conditions:
            if _in(c.get("code"), vs("Advanced Illness")):
                lo = _prevalence(c, birth)[0]
                if lo is not None and wide[0] <= lo <= wide[1]:
                    adv = True
        meds = {m.get("id"): m for m in _by_type(resources, "Medication")}
        for m in _by_type(resources, "MedicationRequest"):
            if m.get("status") != "active" or m.get("intent") != "order":
                continue
            cc = m.get("medicationCodeableConcept")
            if cc is None and m.get("medicationReference"):
                ref = m["medicationReference"].get("reference", "").split("/")[-1]
                cc = (meds.get(ref) or {}).get("code")
            if _in(cc, vs("Dementia Medications")):
                mp = _med_period(m)
                if mp and _ov(mp, wide):
                    adv = True
        frail_ai = frailty and adv

    excl = hospice or nursing or frail_ai or palliative
    res["denominator-exclusion"] = excl
    if excl:
        return res

    # ---- numerator ----
    a1c = vs("HbA1c Laboratory Test")
    gsa = []
    for o in observations:
        if o.get("status") not in ("final", "amended", "corrected") or not _has_cat(o, "laboratory"):
            continue
        if not (_in(o.get("code"), a1c) or obs_code(o, LOINC, "97506-0")):
            continue
        iv = _eff(o)
        lat = _latest(iv)
        if lat is None or not (ps <= lat <= pe):
            continue
        gsa.append((lat, o))
    if not gsa:
        res["numerator"] = True
        return res
    recent = max(d for d, _ in gsa)

    def qval(o):
        q = o.get("valueQuantity")
        if q is None or q.get("value") is None:
            return None
        return q["value"]

    day = [o for d, o in gsa if d == recent]
    vals = [qval(o) for o in day]
    if any(v is None for v in vals):
        res["numerator"] = True  # null sorts lowest: result-less reading is chosen
        return res
    res["numerator"] = min(vals) > 9
    return res
