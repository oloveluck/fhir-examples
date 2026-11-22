from datetime import date, timedelta

BIG = date(9999, 12, 31)
SMALL = date(1, 1, 1)
OBS_CAT = "http://terminology.hl7.org/CodeSystem/observation-category"


def D(s):
    if not s:
        return None
    try:
        return date(int(s[0:4]), int(s[5:7]) if len(s) >= 7 else 1, int(s[8:10]) if len(s) >= 10 else 1)
    except Exception:
        return None


def add_years(d, n):
    try:
        return d.replace(year=d.year + n)
    except ValueError:
        return d.replace(year=d.year + n, day=28)


def codes_of(cc):
    out = set()
    if not cc:
        return out
    for c in cc.get("coding", []) or []:
        out.add((c.get("system"), c.get("code")))
    return out


def in_vs(cc, vs):
    return bool(codes_of(cc) & vs)


def codes_of_any(types, vs):
    if isinstance(types, dict):
        types = [types]
    return any(codes_of(t) & vs for t in (types or []))


def per(p):
    if not p:
        return None
    return (D(p.get("start")), D(p.get("end")))


def dt_interval(r, base, birth):
    """(lo, hi) dates of choice element base[x]; None if absent."""
    if base + "DateTime" in r:
        d = D(r[base + "DateTime"])
        return (d, d) if d else None
    if base + "Instant" in r:
        d = D(r[base + "Instant"])
        return (d, d) if d else None
    if base + "Period" in r:
        p = r[base + "Period"]
        return (D(p.get("start")), D(p.get("end")))
    if base + "Age" in r and birth:
        a = r[base + "Age"].get("value")
        if a is not None:
            return (add_years(birth, int(a)), add_years(birth, int(a) + 1) - timedelta(days=1))
    if base + "Range" in r and birth:
        rg = r[base + "Range"]
        lo = (rg.get("low") or {}).get("value")
        hi = (rg.get("high") or {}).get("value")
        if lo is not None and hi is not None:
            return (add_years(birth, int(lo)), add_years(birth, int(hi) + 1) - timedelta(days=1))
    return None


def overlaps(iv, a, b):
    if not iv:
        return False
    lo, hi = iv
    if lo is None and hi is None:
        return False
    return (lo or SMALL) <= b and (hi or BIG) >= a


def during(iv, a, b):
    if not iv or iv[0] is None or iv[1] is None:
        return False
    return iv[0] >= a and iv[1] <= b


def ends_during(iv, a, b):
    return bool(iv and iv[1] and a <= iv[1] <= b)


def ends_on_or_before(iv, b):
    return bool(iv and iv[1] and iv[1] <= b)


def evaluate(resources, valuesets, period_start, period_end):
    PS, PE = D(period_start), D(period_end)
    by = {}
    patient = {}
    for r in resources:
        by.setdefault(r.get("resourceType"), []).append(r)
        if r.get("resourceType") == "Patient":
            patient = r
    birth = D(patient.get("birthDate"))

    def VS(n):
        return valuesets.get(n, set())

    def of(rt, vsname, field="code"):
        vs = VS(vsname)
        return [r for r in by.get(rt, []) if in_vs(r.get(field), vs)]

    def has_survey(o):
        return any((OBS_CAT, "survey") in codes_of(c) for c in o.get("category", []) or [])

    def enc_ok(e):
        return e.get("status") in ("finished", "arrived", "triaged", "in-progress", "onleave")

    def proc_ok(p):
        return p.get("status") == "completed"

    def obs_assess(o):
        return o.get("status") in ("final", "amended", "corrected") and has_survey(o)

    def eff(o):
        return dt_interval(o, "effective", birth)

    def prev(c):
        on = dt_interval(c, "onset", birth)
        lo = on[0] if on else None
        ab = dt_interval(c, "abatement", birth)
        hi = ab[1] if ab else None
        return (lo, hi) if lo is not None else (None, None)

    def cond_overlaps(c, a, b):
        lo, hi = prev(c)
        return lo is not None and lo <= b and (hi is None or hi >= a)

    def cond_starts_before(c, b):
        lo, _ = prev(c)
        return lo is not None and lo <= b

    # ---- initial population
    age = None
    if birth:
        age = PE.year - birth.year - ((PE.month, PE.day) < (birth.month, birth.day))
    ip = age is not None and 52 <= age <= 74 and patient.get("gender") == "female"
    if ip:
        names = ["Office Visit", "Annual Wellness Visit",
                 "Preventive Care Services Established Office Visit, 18 and Up",
                 "Preventive Care Services Initial Office Visit, 18 and Up",
                 "Home Healthcare Services", "Virtual Encounter", "Telephone Visits"]
        ip = any(enc_ok(e) and during(per(e.get("period")), PS, PE)
                 and any(codes_of_any(e.get("type"), VS(n)) for n in names)
                 for e in by.get("Encounter", []))
    res = {"initial-population": bool(ip), "denominator": bool(ip),
           "denominator-exclusion": False, "numerator": False}
    if not ip:
        return res

    # ---- exclusions
    def hospice():
        disp = {("http://snomed.info/sct", "428361000124107"), ("http://snomed.info/sct", "428371000124100")}
        for e in by.get("Encounter", []):
            if not enc_ok(e):
                continue
            if codes_of_any(e.get("type"), VS("Encounter Inpatient")):
                dd = (e.get("hospitalization") or {}).get("dischargeDisposition")
                if codes_of(dd) & disp and ends_during(per(e.get("period")), PS, PE):
                    return True
            if codes_of_any(e.get("type"), VS("Hospice Encounter")) and overlaps(per(e.get("period")), PS, PE):
                return True
        for o in by.get("Observation", []):
            if obs_assess(o) and ("http://loinc.org", "45755-6") in codes_of(o.get("code")):
                if ("http://snomed.info/sct", "373066001") in codes_of(o.get("valueCodeableConcept")) \
                        and overlaps(eff(o), PS, PE):
                    return True
        for s in of("ServiceRequest", "Hospice Care Ambulatory"):
            if s.get("status") in ("active", "completed") and s.get("intent") == "order":
                a = D(s.get("authoredOn"))
                if a and PS <= a <= PE:
                    return True
        for p in of("Procedure", "Hospice Care Ambulatory"):
            if proc_ok(p) and overlaps(dt_interval(p, "performed", birth), PS, PE):
                return True
        return any(cond_overlaps(c, PS, PE) for c in of("Condition", "Hospice Diagnosis"))

    def palliative():
        for o in by.get("Observation", []):
            if obs_assess(o) and ("http://loinc.org", "71007-9") in codes_of(o.get("code")) \
                    and overlaps(eff(o), PS, PE):
                return True
        if any(cond_overlaps(c, PS, PE) for c in of("Condition", "Palliative Care Diagnosis")):
            return True
        for e in by.get("Encounter", []):
            if enc_ok(e) and codes_of_any(e.get("type"), VS("Palliative Care Encounter")) \
                    and overlaps(per(e.get("period")), PS, PE):
                return True
        for p in of("Procedure", "Palliative Care Intervention"):
            if proc_ok(p) and overlaps(dt_interval(p, "performed", birth), PS, PE):
                return True
        return False

    def side_dx(statusvs, sidecode):
        out = [c for c in of("Condition", statusvs) if cond_starts_before(c, PE)]
        for c in of("Condition", "Unilateral Mastectomy, Unspecified Laterality"):
            if any(("http://snomed.info/sct", sidecode) in codes_of(b) for b in c.get("bodySite", []) or []) \
                    and cond_starts_before(c, PE):
                out.append(c)
        return out

    def procs(vsname):
        return [p for p in of("Procedure", vsname)
                if proc_ok(p) and ends_on_or_before(dt_interval(p, "performed", birth), PE)]

    right = side_dx("Status Post Right Mastectomy", "24028007") or procs("Unilateral Mastectomy Right")
    left = side_dx("Status Post Left Mastectomy", "7771000") or procs("Unilateral Mastectomy Left")
    bilat = [c for c in of("Condition", "History of bilateral mastectomy") if cond_starts_before(c, PE)] \
        or procs("Bilateral Mastectomy")

    def frailty():
        for d in of("DeviceRequest", "Frailty Device", "codeCodeableConcept"):
            if d.get("status") in ("active", "completed") and d.get("intent") == "order" \
                    and d.get("doNotPerform") is not True:
                a = D(d.get("authoredOn"))
                if a and PS <= a <= PE:
                    return True
        for o in by.get("Observation", []):
            if obs_assess(o) and ("http://loinc.org", "98181-1") in codes_of(o.get("code")):
                if in_vs(o.get("valueCodeableConcept"), VS("Frailty Device")) and ends_during(eff(o), PS, PE):
                    return True
        if any(cond_overlaps(c, PS, PE) for c in of("Condition", "Frailty Diagnosis")):
            return True
        for e in by.get("Encounter", []):
            if enc_ok(e) and codes_of_any(e.get("type"), VS("Frailty Encounter")) \
                    and overlaps(per(e.get("period")), PS, PE):
                return True
        for o in of("Observation", "Frailty Symptom"):
            if o.get("status") in ("preliminary", "final", "amended", "corrected") and overlaps(eff(o), PS, PE):
                return True
        return False

    def med_period(m):
        dos = m.get("dosageInstruction") or []
        dosage = dos[0] if len(dos) == 1 else {}
        rep = (dosage.get("timing") or {}).get("repeat") or {}
        dr = m.get("dispenseRequest") or {}
        start = None
        if rep.get("boundsPeriod"):
            start = D(rep["boundsPeriod"].get("start"))
        start = start or D(m.get("authoredOn")) or D((dr.get("validityPeriod") or {}).get("start"))
        sd = dr.get("expectedSupplyDuration") or {}
        supply = sd.get("value")
        if supply is not None:
            f = {"wk": 7, "week": 7, "weeks": 7, "mo": 30, "month": 30, "a": 365}.get(sd.get("unit") or sd.get("code"), 1)
            supply = supply * f
        else:
            q = (dr.get("quantity") or {}).get("value")
            dar = dosage.get("doseAndRate") or []
            dose = None
            if len(dar) == 1:
                dq = dar[0].get("doseQuantity") or (dar[0].get("doseRange") or {}).get("high")
                dose = (dq or {}).get("value")
            freq = rep.get("frequencyMax") or rep.get("frequency") or 1
            p_ = rep.get("period")
            if p_:
                pu = {"h": 1 / 24, "wk": 7, "mo": 30, "min": 1 / 1440, "s": 1 / 86400}.get(rep.get("periodUnit"), 1)
                dpd = freq / (p_ * pu)
            else:
                dpd = len(rep.get("timeOfDay") or []) or 1.0
            if q is not None and dose:
                supply = q / (dose * dpd)
        if start is None or supply is None:
            return None
        total = supply * (1 + (dr.get("numberOfRepeatsAllowed") or 0))
        return (start, start + timedelta(days=int(total - 1)))

    def dementia():
        a = add_years(PS, -1)
        vs = VS("Dementia Medications")
        return any(m.get("status") == "active" and m.get("intent") == "order"
                   and in_vs(m.get("medicationCodeableConcept"), vs) and overlaps(med_period(m), a, PE)
                   for m in by.get("MedicationRequest", []))

    def advanced():
        a = add_years(PS, -1)
        for c in of("Condition", "Advanced Illness"):
            lo, _ = prev(c)
            if lo and a <= lo <= PE:
                return True
        return False

    def nursing():
        best = None
        for o in by.get("Observation", []):
            if obs_assess(o) and ("http://loinc.org", "71802-3") in codes_of(o.get("code")):
                iv = eff(o)
                if iv and iv[1] and iv[1] <= PE and (best is None or iv[1] >= best[0]):
                    best = (iv[1], o)
        return bool(best and ("http://snomed.info/sct", "160734000") in codes_of(best[1].get("valueCodeableConcept")))

    excl = bool(hospice() or (right and left) or bilat or palliative())
    if not excl and age >= 66:
        if (frailty() and (advanced() or dementia())) or nursing():
            excl = True
    res["denominator-exclusion"] = excl

    # ---- numerator
    a = date(PS.year - 2, 10, 1)
    num = any(o.get("status") in ("final", "amended", "corrected") and ends_during(eff(o), a, PE)
              for o in of("Observation", "Mammography"))
    res["numerator"] = num and not excl
    return res
