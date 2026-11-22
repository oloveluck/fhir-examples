import re
from datetime import date, timedelta

INF_LO = "0000-00-00"
INF_HI = "9999-99-99"
CLIN = "http://terminology.hl7.org/CodeSystem/condition-clinical"
OBSCAT = "http://terminology.hl7.org/CodeSystem/observation-category"
SNOMED = "http://snomed.info/sct"
LOINC = "http://loinc.org"


def _d(s):
    """Normalise a FHIR date/dateTime string to YYYY-MM-DD (day precision)."""
    if not s:
        return None
    m = re.match(r"^(\d{4})(?:-(\d{2}))?(?:-(\d{2}))?", str(s))
    if not m:
        return None
    return "%s-%s-%s" % (m.group(1), m.group(2) or "01", m.group(3) or "01")


def _codes(cc):
    out = set()
    if not isinstance(cc, dict):
        return out
    for c in cc.get("coding", []) or []:
        out.add((c.get("system"), c.get("code")))
    return out


def _in(cc, vs):
    return bool(_codes(cc) & vs)


def _add_days(ds, n):
    y, m, d = map(int, ds.split("-"))
    return (date(y, m, d) + timedelta(days=n)).isoformat()


def _add_years(ds, n):
    y, m, d = map(int, ds.split("-"))
    try:
        return date(y + n, m, d).isoformat()
    except ValueError:
        return date(y + n, m, 28).isoformat()


def _interval(res, base):
    """(low, high) day strings; None bound = unbounded; None if element absent."""
    if base + "DateTime" in res:
        d = _d(res[base + "DateTime"])
        return (d, d) if d else None
    if base + "Instant" in res:
        d = _d(res[base + "Instant"])
        return (d, d) if d else None
    if base + "Period" in res:
        p = res[base + "Period"] or {}
        return (_d(p.get("start")), _d(p.get("end")))
    if base == "period" and isinstance(res.get("period"), dict):
        p = res["period"]
        return (_d(p.get("start")), _d(p.get("end")))
    return None


def _overlaps(iv, s, e):
    if iv is None:
        return False
    lo, hi = iv
    return (lo or INF_LO) <= e and (hi or INF_HI) >= s


def _during(iv, s, e):
    if iv is None or iv[0] is None or iv[1] is None:
        return False
    return iv[0] >= s and iv[1] <= e


def _ends_during(iv, s, e):
    return iv is not None and iv[1] is not None and s <= iv[1] <= e


def _latest(iv):
    if iv is None:
        return None
    return iv[1] if iv[1] else iv[0]


def _age_date(q, birth):
    if not q or q.get("value") is None or not birth:
        return None
    return _add_years(birth, int(q["value"]))


def _prevalence(cond, birth):
    onset = _interval(cond, "onset")
    if onset is None and "onsetAge" in cond:
        d = _age_date(cond["onsetAge"], birth)
        onset = (d, _add_days(_add_years(d, 1), -1)) if d else None
    start = onset[0] if onset else None
    end = None
    known = False
    ab = _interval(cond, "abatement")
    if ab is not None:
        end, known = ab[1], ab[1] is not None
    elif "abatementAge" in cond:
        d = _age_date(cond["abatementAge"], birth)
        if d:
            end, known = _add_days(_add_years(d, 1), -1), True
    elif "abatementRange" in cond:
        d = _age_date(cond["abatementRange"].get("high"), birth)
        if d:
            end, known = _add_days(_add_years(d, 1), -1), True
    status = _codes(cond.get("clinicalStatus"))
    active = any((CLIN, c) in status for c in ("active", "recurrence", "relapse"))
    if not known and not active:
        return (start, "NOEND")
    return (start, end)


def _prev_overlaps(iv, s, e):
    if iv[1] == "NOEND":
        return False
    return _overlaps(iv, s, e)


def _med_period(m):
    di = m.get("dosageInstruction") or []
    dosage = di[0] if di else {}
    timing = (dosage.get("timing") or {}).get("repeat") or {}
    bounds = timing.get("boundsPeriod") or {}
    dr = m.get("dispenseRequest") or {}
    start = (_d(bounds.get("start")) or _d(m.get("authoredOn"))
             or _d((dr.get("validityPeriod") or {}).get("start")))
    days = None
    esd = dr.get("expectedSupplyDuration")
    if esd and esd.get("value") is not None:
        u = (esd.get("code") or esd.get("unit") or "d").lower()
        v = esd["value"]
        mult = {"d": 1, "day": 1, "days": 1, "wk": 7, "week": 7, "weeks": 7,
                "mo": 30, "month": 30, "months": 30, "h": 1 / 24.0, "hour": 1 / 24.0}.get(u)
        if mult:
            days = v * mult
    if days is None:
        qty = (dr.get("quantity") or {}).get("value")
        dar = (dosage.get("doseAndRate") or [{}])[0]
        dose = None
        if "doseRange" in dar:
            dose = (dar["doseRange"].get("high") or {}).get("value")
        elif "doseQuantity" in dar:
            dose = dar["doseQuantity"].get("value")
        freq = timing.get("frequencyMax") or timing.get("frequency")
        per = timing.get("period")
        perdays = {"d": 1, "wk": 7, "mo": 30, "a": 365, "h": 1 / 24.0}.get(timing.get("periodUnit"))
        if freq and per and perdays:
            dpd = freq / (per * perdays)
        elif timing.get("timeOfDay"):
            dpd = len(timing["timeOfDay"])
        else:
            dpd = 1.0
        if qty is not None and dose:
            days = qty / (dose * dpd)
    if start and days is not None:
        refills = dr.get("numberOfRepeatsAllowed") or 0
        return (start, _add_days(start, int(days * (1 + refills) - 1)))
    if start and bounds.get("end"):
        return (start, _d(bounds["end"]))
    return None


def evaluate(resources, valuesets, period_start, period_end):
    S, E = _d(period_start), _d(period_end)
    by = {}
    for r in resources:
        by.setdefault(r.get("resourceType"), []).append(r)

    def vs(n):
        return valuesets.get(n, set())

    patient = (by.get("Patient") or [{}])[0]
    birth = _d(patient.get("birthDate"))
    FCA = ("final", "amended", "corrected")

    def cat_has(o, code):
        return any((OBSCAT, code) in _codes(cc) for cc in o.get("category", []) or [])

    def assessment(o):
        return o.get("status") in FCA and cat_has(o, "survey")

    def enc_performed(e):
        return e.get("status") in ("finished", "arrived", "triaged", "in-progress", "onleave")

    def enc_codes(e):
        out = set()
        for t in e.get("type", []) or []:
            out |= _codes(t)
        return out

    def encs(names, pred):
        s = set()
        for n in names:
            s |= vs(n)
        return [e for e in by.get("Encounter", [])
                if enc_performed(e) and (enc_codes(e) & s) and pred(_interval(e, "period"))]

    def conds(name):
        return [c for c in by.get("Condition", []) if _in(c.get("code"), vs(name))]

    def cond_overlap(name):
        return any(_prev_overlaps(_prevalence(c, birth), S, E) for c in conds(name))

    # ---- initial population
    age = None
    if birth:
        age = int(E[:4]) - int(birth[:4]) - (1 if E[5:] < birth[5:] else 0)
    in_age = age is not None and 18 <= age <= 75
    qual = encs(["Office Visit", "Annual Wellness Visit",
                 "Preventive Care Services Established Office Visit, 18 and Up",
                 "Preventive Care Services Initial Office Visit, 18 and Up",
                 "Home Healthcare Services", "Virtual Encounter", "Telephone Visits"],
                lambda iv: _during(iv, S, E))
    ip = bool(in_age and qual and cond_overlap("Diabetes"))

    # ---- exclusions
    def hospice():
        for e in by.get("Encounter", []):
            if enc_performed(e) and (enc_codes(e) & vs("Encounter Inpatient")):
                dd = _codes((e.get("hospitalization") or {}).get("dischargeDisposition"))
                if ((SNOMED, "428361000124107") in dd or (SNOMED, "428371000124100") in dd) \
                        and _ends_during(_interval(e, "period"), S, E):
                    return True
        if encs(["Hospice Encounter"], lambda iv: _overlaps(iv, S, E)):
            return True
        for o in by.get("Observation", []):
            if (LOINC, "45755-6") in _codes(o.get("code")) and assessment(o) \
                    and (SNOMED, "373066001") in _codes(o.get("valueCodeableConcept")) \
                    and _overlaps(_interval(o, "effective"), S, E):
                return True
        for sr in by.get("ServiceRequest", []):
            if _in(sr.get("code"), vs("Hospice Care Ambulatory")) \
                    and sr.get("status") in ("active", "completed") and sr.get("intent") == "order":
                d = _d(sr.get("authoredOn"))
                if d and S <= d <= E:
                    return True
        for p in by.get("Procedure", []):
            if _in(p.get("code"), vs("Hospice Care Ambulatory")) and p.get("status") == "completed" \
                    and _overlaps(_interval(p, "performed"), S, E):
                return True
        return cond_overlap("Hospice Diagnosis")

    def palliative():
        for o in by.get("Observation", []):
            if (LOINC, "71007-9") in _codes(o.get("code")) and assessment(o) \
                    and _overlaps(_interval(o, "effective"), S, E):
                return True
        if cond_overlap("Palliative Care Diagnosis"):
            return True
        if encs(["Palliative Care Encounter"], lambda iv: _overlaps(iv, S, E)):
            return True
        for p in by.get("Procedure", []):
            if _in(p.get("code"), vs("Palliative Care Intervention")) and p.get("status") == "completed" \
                    and _overlaps(_interval(p, "performed"), S, E):
                return True
        return False

    def frailty():
        for d in by.get("DeviceRequest", []):
            if _in(d.get("codeCodeableConcept"), vs("Frailty Device")) \
                    and d.get("status") in ("active", "completed") \
                    and d.get("intent") == "order" and d.get("doNotPerform") is not True:
                a = _d(d.get("authoredOn"))
                if a and S <= a <= E:
                    return True
        for o in by.get("Observation", []):
            if (LOINC, "98181-1") in _codes(o.get("code")) and assessment(o) \
                    and _in(o.get("valueCodeableConcept"), vs("Frailty Device")) \
                    and _ends_during(_interval(o, "effective"), S, E):
                return True
            if _in(o.get("code"), vs("Frailty Symptom")) \
                    and o.get("status") in ("preliminary",) + FCA \
                    and _overlaps(_interval(o, "effective"), S, E):
                return True
        if cond_overlap("Frailty Diagnosis"):
            return True
        return bool(encs(["Frailty Encounter"], lambda iv: _overlaps(iv, S, E)))

    def advanced_illness():
        lo, hi = _add_years(S, -1), E
        for c in conds("Advanced Illness"):
            st = _prevalence(c, birth)[0]
            if st and lo <= st <= hi:
                return True
        for m in by.get("MedicationRequest", []):
            if _in(m.get("medicationCodeableConcept"), vs("Dementia Medications")) \
                    and m.get("status") == "active" and m.get("intent") == "order":
                p = _med_period(m)
                if p and _overlaps(p, lo, hi):
                    return True
        return False

    def nursing_home():
        if not (age is not None and age >= 66):
            return False
        c = []
        for o in by.get("Observation", []):
            if (LOINC, "71802-3") in _codes(o.get("code")) and assessment(o):
                iv = _interval(o, "effective")
                if iv and iv[1] is not None and iv[1] <= E:
                    c.append((iv[1], o))
        if not c:
            return False
        c.sort(key=lambda x: x[0])
        return (SNOMED, "160734000") in _codes(c[-1][1].get("valueCodeableConcept"))

    excl = False
    if ip:
        excl = bool(hospice() or nursing_home()
                    or (age >= 66 and frailty() and advanced_illness())
                    or palliative())

    # ---- numerator
    gl = []
    codes = vs("HbA1c Laboratory Test") | {(LOINC, "97506-0")}
    for o in by.get("Observation", []):
        if (_codes(o.get("code")) & codes) and o.get("status") in FCA and cat_has(o, "laboratory"):
            ld = _latest(_interval(o, "effective"))
            if ld and S <= ld <= E:
                gl.append((ld, o))

    def qty(o):
        q = o.get("valueQuantity")
        if q and q.get("value") is not None:
            unit = q.get("code") or q.get("unit")
            if unit in (None, "", "%"):
                return float(q["value"])
        return None

    num = False
    if not gl:
        num = True
    else:
        recent = max(d for d, _ in gl)
        day = [o for d, o in gl if d == recent]
        day.sort(key=lambda o: (qty(o) is not None, qty(o) or 0))
        low = day[0]
        if not any(k.startswith("value") for k in low):
            num = True
        elif qty(low) is not None and qty(low) > 9:
            num = True

    return {"initial-population": ip,
            "denominator": ip,
            "denominator-exclusion": ip and excl,
            "numerator": ip and not excl and num}
