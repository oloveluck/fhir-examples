from datetime import date, timedelta

SNOMED = "http://snomed.info/sct"
SURVEY = ("http://terminology.hl7.org/CodeSystem/observation-category", "survey")
ACTIVE_STATUS = {"active", "recurrence", "relapse"}


def _d(s):
    """Date part of a FHIR date/dateTime string, as a date."""
    if not s:
        return None
    try:
        p = s[:10].split("-")
        y = int(p[0]); m = int(p[1]) if len(p) > 1 else 1; dd = int(p[2]) if len(p) > 2 else 1
        return date(y, m, dd)
    except Exception:
        return None


def _is_end(s):
    return s


def _codes(cc):
    out = []
    if not isinstance(cc, dict):
        return out
    for c in cc.get("coding", []) or []:
        out.append((c.get("system"), c.get("code")))
    return out


def _in(cc, vs):
    return any(c in vs for c in _codes(cc))


def _is(cc, code):
    return code in _codes(cc)


def _interval(res, base):
    """(low, high, high_open_unknown) from base[x]; dates. Returns None if no value."""
    if base + "DateTime" in res:
        d = _d(res[base + "DateTime"]); return (d, d) if d else None
    if base + "Instant" in res:
        d = _d(res[base + "Instant"]); return (d, d) if d else None
    if base + "Period" in res:
        p = res[base + "Period"]
        return (_d(p.get("start")), _d(p.get("end")))
    if base + "Date" in res:
        d = _d(res[base + "Date"]); return (d, d) if d else None
    return None


def _overlaps(iv, s, e):
    if iv is None:
        return False
    lo, hi = iv
    if lo is None and hi is None:
        return False
    return (lo is None or lo <= e) and (hi is None or hi >= s)


def _during(iv, s, e):
    if iv is None or iv[0] is None or iv[1] is None:
        return False
    return s <= iv[0] and iv[1] <= e


def _ends_during(iv, s, e):
    return iv is not None and iv[1] is not None and s <= iv[1] <= e


def _prevalence(c):
    """(low, high, high_known_or_closed). Returns (low, high, unknown_end)"""
    onset = None
    if "onsetDateTime" in c:
        onset = _d(c["onsetDateTime"])
    elif "onsetPeriod" in c:
        onset = _d(c["onsetPeriod"].get("start"))
    ab = None
    if "abatementDateTime" in c:
        ab = _d(c["abatementDateTime"])
    elif "abatementPeriod" in c:
        ab = _d(c["abatementPeriod"].get("end"))
    status = [x[1] for x in _codes(c.get("clinicalStatus"))]
    active = any(s in ACTIVE_STATUS for s in status)
    unknown_end = (ab is None and not active)
    return onset, ab, unknown_end


def _prev_overlaps(c, s, e):
    lo, hi, unk = _prevalence(c)
    if lo is None or unk:
        return False
    return lo <= e and (hi is None or hi >= s)


def _prev_starts_before(c, e):
    lo, _, _ = _prevalence(c)
    return lo is not None and lo <= e


def evaluate(resources, valuesets, period_start, period_end):
    ps, pe = _d(period_start), _d(period_end)
    vs = lambda n: valuesets.get(n, set())
    by = {}
    for r in resources:
        by.setdefault(r.get("resourceType"), []).append(r)
    patient = (by.get("Patient") or [{}])[0]

    def of(rt, name, path="code"):
        v = vs(name)
        return [r for r in by.get(rt, []) if _in(r.get(path), v)]

    # --- initial population
    bd = _d(patient.get("birthDate"))
    age = None
    if bd:
        age = pe.year - bd.year - ((pe.month, pe.day) < (bd.month, bd.day))
    enc_status = {"finished", "arrived", "triaged", "in-progress", "onleave"}

    def enc_type_in(e, name):
        v = vs(name)
        return any(_in(t, v) for t in e.get("type", []) or [])

    qual_sets = ["Office Visit", "Annual Wellness Visit",
                 "Preventive Care Services Established Office Visit, 18 and Up",
                 "Preventive Care Services Initial Office Visit, 18 and Up",
                 "Home Healthcare Services", "Virtual Encounter", "Telephone Visits"]
    qualifying = any(
        e.get("status") in enc_status and any(enc_type_in(e, n) for n in qual_sets)
        and _during(_interval(e, "period") if False else _period(e), ps, pe)
        for e in by.get("Encounter", [])
    ) if False else None

    def _period(e):
        p = e.get("period")
        if not p:
            return None
        return (_d(p.get("start")), _d(p.get("end")))

    qualifying = any(
        e.get("status") in enc_status and any(enc_type_in(e, n) for n in qual_sets)
        and _during(_period(e), ps, pe)
        for e in by.get("Encounter", [])
    )
    ip = (age is not None and 52 <= age <= 74 and patient.get("gender") == "female" and qualifying)
    res = {"initial-population": bool(ip), "denominator": bool(ip),
           "denominator-exclusion": False, "numerator": False}
    if not ip:
        return res

    # --- exclusions
    def performed_ok(p):
        return p.get("status") == "completed"

    def proc_before_end(name):
        for p in of("Procedure", name):
            if performed_ok(p):
                iv = _interval(p, "performed")
                if iv and iv[1] is not None and iv[1] <= pe:
                    return True
        return False

    def cond_before_end(name):
        return [c for c in of("Condition", name) if _prev_starts_before(c, pe)]

    def uni_diag(side_vs, side_code):
        out = cond_before_end(side_vs)
        for c in cond_before_end("Unilateral Mastectomy, Unspecified Laterality"):
            if any((SNOMED, side_code) in _codes(b) for b in c.get("bodySite", []) or []):
                out.append(c)
        return out

    right = bool(uni_diag("Status Post Right Mastectomy", "24028007")) or proc_before_end("Unilateral Mastectomy Right")
    left = bool(uni_diag("Status Post Left Mastectomy", "7771000")) or proc_before_end("Unilateral Mastectomy Left")
    bilateral = bool(cond_before_end("History of bilateral mastectomy")) or proc_before_end("Bilateral Mastectomy")

    # hospice
    hospice_codes = {(SNOMED, "428371000124100"), (SNOMED, "428361000124107")}
    hospice = False
    for e in by.get("Encounter", []):
        if e.get("status") not in enc_status:
            continue
        per = _period(e)
        if _in(e.get("type") and {"coding": [c for t in e["type"] for c in t.get("coding", [])]}, vs("Encounter Inpatient")):
            dd = (e.get("hospitalization") or {}).get("dischargeDisposition")
            if any(c in hospice_codes for c in _codes(dd)) and _ends_during(per, ps, pe):
                hospice = True
        if enc_type_in(e, "Hospice Encounter") and _overlaps(per, ps, pe):
            hospice = True
    for o in by.get("Observation", []):
        if o.get("status") in ("final", "amended", "corrected") and any(SURVEY == (c.get("system"), c.get("code")) for cat in o.get("category", []) or [] for c in cat.get("coding", [])):
            if _is(o.get("code"), ("http://loinc.org", "45755-6")) and (SNOMED, "373066001") in _codes(o.get("valueCodeableConcept")) \
                    and _overlaps(_interval(o, "effective"), ps, pe):
                hospice = True
    for sr in of("ServiceRequest", "Hospice Care Ambulatory"):
        if sr.get("status") in ("active", "completed") and sr.get("intent") == "order":
            a = _d(sr.get("authoredOn"))
            if a and ps <= a <= pe:
                hospice = True
    for p in of("Procedure", "Hospice Care Ambulatory"):
        if p.get("status") == "completed" and _overlaps(_interval(p, "performed"), ps, pe):
            hospice = True
    for c in of("Condition", "Hospice Diagnosis"):
        if _prev_overlaps(c, ps, pe):
            hospice = True

    # palliative
    pal = False
    for o in by.get("Observation", []):
        if o.get("status") in ("final", "amended", "corrected") and any(SURVEY == (c.get("system"), c.get("code")) for cat in o.get("category", []) or [] for c in cat.get("coding", [])):
            if _is(o.get("code"), ("http://loinc.org", "71007-9")) and _overlaps(_interval(o, "effective"), ps, pe):
                pal = True
    for c in of("Condition", "Palliative Care Diagnosis"):
        if _prev_overlaps(c, ps, pe):
            pal = True
    for e in by.get("Encounter", []):
        if e.get("status") in enc_status and enc_type_in(e, "Palliative Care Encounter") and _overlaps(_period(e), ps, pe):
            pal = True
    for p in of("Procedure", "Palliative Care Intervention"):
        if p.get("status") == "completed" and _overlaps(_interval(p, "performed"), ps, pe):
            pal = True

    # frailty / advanced illness
    adv = bool(age is not None and age >= 66)
    frail_excl = False
    nursing = False
    if adv:
        frail = False
        for d in by.get("DeviceRequest", []):
            if _in(d.get("codeCodeableConcept"), vs("Frailty Device")) and d.get("status") in ("active", "completed") \
                    and d.get("intent") == "order":
                dnp = False
                for x in d.get("modifierExtension", []) or []:
                    if x.get("url") == "http://hl7.org/fhir/us/qicore/StructureDefinition/qicore-doNotPerform" and x.get("valueBoolean") is True:
                        dnp = True
                a = _d(d.get("authoredOn"))
                if not dnp and a and ps <= a <= pe:
                    frail = True
        for o in by.get("Observation", []):
            st = o.get("status")
            iv = _interval(o, "effective")
            if st in ("final", "amended", "corrected") and any(SURVEY == (c.get("system"), c.get("code")) for cat in o.get("category", []) or [] for c in cat.get("coding", [])):
                if _is(o.get("code"), ("http://loinc.org", "98181-1")) and _in(o.get("valueCodeableConcept"), vs("Frailty Device")) \
                        and _ends_during(iv, ps, pe):
                    frail = True
            if st in ("preliminary", "final", "amended", "corrected") and _in(o.get("code"), vs("Frailty Symptom")) \
                    and _overlaps(iv, ps, pe):
                frail = True
        for c in of("Condition", "Frailty Diagnosis"):
            if _prev_overlaps(c, ps, pe):
                frail = True
        for e in by.get("Encounter", []):
            if e.get("status") in enc_status and enc_type_in(e, "Frailty Encounter") and _overlaps(_period(e), ps, pe):
                frail = True
        ys = date(ps.year - 1, ps.month, ps.day)
        illness = any(ys <= (_prevalence(c)[0] or date.min) <= pe and _prevalence(c)[0] is not None
                      for c in of("Condition", "Advanced Illness"))
        meds = {m.get("id"): m for m in by.get("Medication", [])}
        dem = False
        for m in by.get("MedicationRequest", []):
            if m.get("status") != "active" or m.get("intent") != "order":
                continue
            cc = m.get("medicationCodeableConcept")
            if cc is None and m.get("medicationReference"):
                ref = m["medicationReference"].get("reference", "").split("/")[-1].lstrip("#")
                cc = (meds.get(ref) or {}).get("code")
            if not _in(cc, vs("Dementia Medications")):
                continue
            lo = _d(m.get("authoredOn")); hi = None
            dr = m.get("dispenseRequest") or {}
            vp = dr.get("validityPeriod")
            bp = None
            for di in m.get("dosageInstruction", []) or []:
                bp = ((di.get("timing") or {}).get("repeat") or {}).get("boundsPeriod") or bp
            if bp:
                lo, hi = _d(bp.get("start")) or lo, _d(bp.get("end"))
            elif vp:
                lo, hi = _d(vp.get("start")) or lo, _d(vp.get("end"))
            if lo is None:
                continue
            if hi is None:
                hi = date.max
            if lo <= pe and hi >= ys:
                dem = True
        frail_excl = frail and (illness or dem)
        # nursing home
        best = None
        for o in by.get("Observation", []):
            if o.get("status") in ("final", "amended", "corrected") and any(SURVEY == (c.get("system"), c.get("code")) for cat in o.get("category", []) or [] for c in cat.get("coding", [])) \
                    and _is(o.get("code"), ("http://loinc.org", "71802-3")):
                iv = _interval(o, "effective")
                if iv and iv[1] is not None and iv[1] <= pe:
                    if best is None or iv[1] >= best[0]:
                        best = (iv[1], o)
        if best and (SNOMED, "160734000") in _codes(best[1].get("valueCodeableConcept")):
            nursing = True

    excl = hospice or (right and left) or bilateral or frail_excl or nursing or pal
    res["denominator-exclusion"] = bool(excl)

    # numerator
    oct1 = date(ps.year - 2, 10, 1)
    num = False
    for o in of("Observation", "Mammography"):
        if o.get("status") in ("final", "amended", "corrected") and _ends_during(_interval(o, "effective"), oct1, pe):
            num = True
    res["numerator"] = bool(num and not excl)
    return res
