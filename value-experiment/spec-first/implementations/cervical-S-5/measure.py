from datetime import date, datetime, timezone

INF = date(9999, 12, 31)
NINF = date(1, 1, 1)
OBS_CAT = "http://terminology.hl7.org/CodeSystem/observation-category"
LAB = (OBS_CAT, "laboratory")
SURVEY = (OBS_CAT, "survey")
SNOMED = "http://snomed.info/sct"
LOINC = "http://loinc.org"
ENC_OK = ("finished", "arrived", "triaged", "in-progress", "onleave")
OBS_OK = ("final", "amended", "corrected")


def pdate(s):
    """ISO date/dateTime string -> date (UTC day), or None."""
    if not s or not isinstance(s, str):
        return None
    try:
        if len(s) <= 10:
            p = s.split("-")
            return date(int(p[0]), int(p[1]) if len(p) > 1 else 1, int(p[2]) if len(p) > 2 else 1)
        d = datetime.fromisoformat(s.replace("Z", "+00:00"))
        if d.tzinfo is not None:
            d = d.astimezone(timezone.utc)
        return d.date()
    except Exception:
        try:
            return date.fromisoformat(s[:10])
        except Exception:
            return None


def codings(cc):
    out = []
    if isinstance(cc, list):
        for c in cc:
            out += codings(c)
    elif isinstance(cc, dict):
        for c in cc.get("coding", []) or []:
            out.append((c.get("system"), c.get("code")))
    return out


def invs(cc, vs):
    return any(c in vs for c in codings(cc))


def interval(r, base):
    """(lo, hi) dates from base[x]; None if absent."""
    for k in (base + "DateTime", base + "Instant"):
        if k in r:
            d = pdate(r[k])
            return (d, d) if d else None
    if base + "Period" in r:
        p = r[base + "Period"] or {}
        return (pdate(p.get("start")), pdate(p.get("end")))
    return None


def during(iv, lo, hi):
    return bool(iv and iv[0] and iv[1] and lo <= iv[0] and iv[1] <= hi)


def overlaps(iv, lo, hi):
    if not iv:
        return False
    return (iv[0] or NINF) <= hi and (iv[1] or INF) >= lo


def evaluate(resources, valuesets, period_start, period_end):
    ps, pe = pdate(period_start), pdate(period_end)

    def V(*names):
        s = set()
        for n in names:
            s |= set(map(tuple, valuesets.get(n, [])))
        return s

    by = {}
    for r in resources:
        by.setdefault(r.get("resourceType"), []).append(r)
    pat = (by.get("Patient") or [{}])[0]
    bd = pdate(pat.get("birthDate"))

    def age_at(d):
        if not bd or not d:
            return None
        return d.year - bd.year - ((d.month, d.day) < (bd.month, bd.day))

    def encs(*names):
        vs = V(*names)
        return [e for e in by.get("Encounter", [])
                if e.get("status") in ENC_OK and invs(e.get("type"), vs)]

    def eperiod(e):
        p = e.get("period") or {}
        return (pdate(p.get("start")), pdate(p.get("end")))

    qual = [e for e in encs("Office Visit",
                            "Preventive Care Services Established Office Visit, 18 and Up",
                            "Preventive Care Services Initial Office Visit, 18 and Up",
                            "Home Healthcare Services", "Telephone Visits", "Virtual Encounter")
            if during(eperiod(e), ps, pe)]

    a = age_at(pe)
    ip = bool(a is not None and 24 <= a <= 64 and pat.get("gender") == "female" and qual)
    res = {"initial-population": ip, "denominator": ip,
           "denominator-exclusion": False, "numerator": False}
    if not ip:
        return res

    def prev(c):
        on = interval(c, "onset")
        start = on[0] if on else None
        ab = None
        if "abatementDateTime" in c:
            ab = pdate(c["abatementDateTime"])
        elif "abatementPeriod" in c:
            ab = pdate((c["abatementPeriod"] or {}).get("end"))
        return (start, ab)

    def obs_ok(o, code, cat):
        return (o.get("status") in OBS_OK and cat in codings(o.get("category"))
                and code in codings(o.get("code")))

    # ---- hospice
    hospice = False
    dd = {(SNOMED, "428371000124100"), (SNOMED, "428361000124107")}
    for e in encs("Encounter Inpatient"):
        if invs((e.get("hospitalization") or {}).get("dischargeDisposition"), dd):
            iv = eperiod(e)
            if iv[1] and ps <= iv[1] <= pe:
                hospice = True
    for e in encs("Hospice Encounter"):
        if overlaps(eperiod(e), ps, pe):
            hospice = True
    for o in by.get("Observation", []):
        if (obs_ok(o, (LOINC, "45755-6"), SURVEY)
                and (SNOMED, "373066001") in codings(o.get("valueCodeableConcept"))
                and overlaps(interval(o, "effective"), ps, pe)):
            hospice = True
    hv = V("Hospice Care Ambulatory")
    for s in by.get("ServiceRequest", []):
        if (s.get("status") in ("active", "completed") and s.get("intent") == "order"
                and invs(s.get("code"), hv)):
            d = pdate(s.get("authoredOn"))
            if d and ps <= d <= pe:
                hospice = True
    for p in by.get("Procedure", []):
        if (p.get("status") == "completed" and invs(p.get("code"), hv)
                and overlaps(interval(p, "performed"), ps, pe)):
            hospice = True
    hd = V("Hospice Diagnosis")
    for c in by.get("Condition", []):
        if invs(c.get("code"), hd) and overlaps(prev(c), ps, pe):
            hospice = True

    # ---- palliative
    pal = False
    for o in by.get("Observation", []):
        if (obs_ok(o, (LOINC, "71007-9"), SURVEY)
                and overlaps(interval(o, "effective"), ps, pe)):
            pal = True
    pdx = V("Palliative Care Diagnosis")
    for c in by.get("Condition", []):
        if invs(c.get("code"), pdx) and overlaps(prev(c), ps, pe):
            pal = True
    for e in encs("Palliative Care Encounter"):
        if overlaps(eperiod(e), ps, pe):
            pal = True
    pint = V("Palliative Care Intervention")
    for p in by.get("Procedure", []):
        if (p.get("status") == "completed" and invs(p.get("code"), pint)
                and overlaps(interval(p, "performed"), ps, pe)):
            pal = True

    # ---- absence of cervix
    absent = False
    hy = V("Hysterectomy with No Residual Cervix")
    for p in by.get("Procedure", []):
        if p.get("status") == "completed" and invs(p.get("code"), hy):
            iv = interval(p, "performed")
            if iv and iv[1] and iv[1] <= pe:
                absent = True
    ac = V("Congenital or Acquired Absence of Cervix")
    for c in by.get("Condition", []):
        if invs(c.get("code"), ac):
            s, _ = prev(c)
            if s and s <= pe:
                absent = True

    excl = hospice or pal or absent
    res["denominator-exclusion"] = excl
    if excl:
        return res

    # ---- numerator
    def lab(o, vsname):
        return (o.get("status") in OBS_OK and LAB in codings(o.get("category"))
                and invs(o.get("code"), V(vsname))
                and any(k.startswith("value") for k in o))

    def latest(o):
        iv = interval(o, "effective")
        return (iv[1] or iv[0]) if iv else None

    def years_back(n):
        try:
            return date(ps.year - n, ps.month, ps.day)
        except ValueError:
            return date(ps.year - n, ps.month, 28)

    num = False
    for o in by.get("Observation", []):
        d = latest(o)
        if not d:
            continue
        if lab(o, "Pap Test") and years_back(2) <= d <= pe:
            num = True
        if lab(o, "HPV Test") and years_back(4) <= d <= pe and (age_at(d) or 0) >= 30:
            num = True
    res["numerator"] = num
    return res
