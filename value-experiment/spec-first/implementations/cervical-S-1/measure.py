from datetime import date, datetime, timezone

INF = date(9999, 12, 31)
NINF = date(1, 1, 1)
OBS_CAT = "http://terminology.hl7.org/CodeSystem/observation-category"
SNOMED = "http://snomed.info/sct"


def pdate(s):
    """FHIR date/dateTime string -> date (UTC day) or None."""
    if not s:
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
        return None


def interval(res, *names):
    """(low, high); high INF if open-ended; low None if unknown; None if absent."""
    for n in names:
        for suf in ("DateTime", "Instant", "Date"):
            if n + suf in res:
                d = pdate(res[n + suf])
                return (d, d) if d else None
        if n + "Period" in res:
            p = res[n + "Period"] or {}
            lo = pdate(p.get("start"))
            hi = pdate(p.get("end"))
            if lo is None and hi is None:
                return None
            return (lo, hi if hi else INF) if lo else (None, hi)
    return None


def latest(iv):
    if iv is None:
        return None
    lo, hi = iv
    return hi if hi != INF else lo


def has_code(cc, vs):
    if not cc:
        return False
    return any((c.get("system"), c.get("code")) in vs for c in cc.get("coding", []) or [])


def type_in(res, vs):
    return any(has_code(t, vs) for t in res.get("type", []) or [])


def cat_is(res, code):
    return any(has_code(c, {(OBS_CAT, code)}) for c in res.get("category", []) or [])


def overlaps_mp(iv, s, e):
    if iv is None or iv[0] is None or iv[1] is None:
        return False
    return iv[0] <= e and iv[1] >= s


def during_mp(iv, s, e):
    if iv is None or iv[0] is None or iv[1] is None or iv[1] == INF:
        return False
    return iv[0] >= s and iv[1] <= e


def prevalence(c):
    cs = c.get("clinicalStatus")
    active = any(cd.get("code") in ("active", "recurrence", "relapse")
                 and cd.get("system") == "http://terminology.hl7.org/CodeSystem/condition-clinical"
                 for cd in (cs or {}).get("coding", []) or [])
    on = interval(c, "onset")
    lo = on[0] if on and on[0] else NINF
    ab = interval(c, "abatement")
    hi = ab[1] if ab and ab[1] is not None else None
    if hi == INF:
        hi = None
    if hi is None:
        return (lo, INF if active else None)
    return (lo, hi)


def period_iv(e):
    p = e.get("period")
    return interval({"performedPeriod": p}, "performed") if p else None


def evaluate(resources, valuesets, period_start, period_end):
    S = pdate(period_start)
    E = pdate(period_end)

    def V(n):
        return valuesets.get(n, set())

    by = {}
    for r in resources:
        by.setdefault(r.get("resourceType"), []).append(r)
    pat = (by.get("Patient") or [{}])[0]
    out = {"initial-population": False, "denominator": False,
           "denominator-exclusion": False, "numerator": False}

    bd = pdate(pat.get("birthDate"))
    if not bd or pat.get("gender") != "female":
        return out
    age = E.year - bd.year - ((E.month, E.day) < (bd.month, bd.day))
    if not (24 <= age <= 64):
        return out

    ok_enc = ("finished", "arrived", "triaged", "in-progress", "onleave")
    qual = (V("Office Visit") | V("Preventive Care Services Established Office Visit, 18 and Up")
            | V("Preventive Care Services Initial Office Visit, 18 and Up") | V("Home Healthcare Services")
            | V("Telephone Visits") | V("Virtual Encounter"))
    if not any(e.get("status") in ok_enc and type_in(e, qual) and during_mp(period_iv(e), S, E)
               for e in by.get("Encounter", [])):
        return out
    out["initial-population"] = out["denominator"] = True

    excl = False
    hosp = {(SNOMED, "428371000124100"), (SNOMED, "428361000124107")}
    for e in by.get("Encounter", []):
        if e.get("status") not in ok_enc:
            continue
        per = period_iv(e)
        if (type_in(e, V("Encounter Inpatient"))
                and has_code((e.get("hospitalization") or {}).get("dischargeDisposition"), hosp)
                and per and per[1] not in (None, INF) and S <= per[1] <= E):
            excl = True
        if type_in(e, V("Hospice Encounter")) and overlaps_mp(per, S, E):
            excl = True
        if type_in(e, V("Palliative Care Encounter")) and overlaps_mp(per, S, E):
            excl = True
    for o in by.get("Observation", []):
        if o.get("status") not in ("final", "amended", "corrected") or not cat_is(o, "survey"):
            continue
        iv = interval(o, "effective")
        if (has_code(o.get("code"), {("http://loinc.org", "45755-6")})
                and has_code(o.get("valueCodeableConcept"), {(SNOMED, "373066001")})
                and overlaps_mp(iv, S, E)):
            excl = True
        if has_code(o.get("code"), {("http://loinc.org", "71007-9")}) and overlaps_mp(iv, S, E):
            excl = True
    for r in by.get("ServiceRequest", []):
        if (r.get("status") in ("active", "completed") and r.get("intent") == "order"
                and has_code(r.get("code"), V("Hospice Care Ambulatory"))):
            d = pdate(r.get("authoredOn"))
            if d and S <= d <= E:
                excl = True
    for p in by.get("Procedure", []):
        if p.get("status") != "completed":
            continue
        iv = interval(p, "performed")
        if has_code(p.get("code"), V("Hospice Care Ambulatory")) and overlaps_mp(iv, S, E):
            excl = True
        if has_code(p.get("code"), V("Palliative Care Intervention")) and overlaps_mp(iv, S, E):
            excl = True
        if (has_code(p.get("code"), V("Hysterectomy with No Residual Cervix"))
                and iv and iv[1] not in (None, INF) and iv[1] <= E):
            excl = True
    for c in by.get("Condition", []):
        pv = prevalence(c)
        if has_code(c.get("code"), V("Hospice Diagnosis")) or has_code(c.get("code"), V("Palliative Care Diagnosis")):
            if pv[1] is not None and pv[0] <= E and pv[1] >= S:
                excl = True
        if has_code(c.get("code"), V("Congenital or Acquired Absence of Cervix")) and pv[0] <= E:
            excl = True
    out["denominator-exclusion"] = excl
    if excl:
        return out

    num = False
    for o in by.get("Observation", []):
        if o.get("status") not in ("final", "amended", "corrected") or not cat_is(o, "laboratory"):
            continue
        if not any(k.startswith("value") for k in o):
            continue
        d = latest(interval(o, "effective"))
        if d is None:
            continue
        if has_code(o.get("code"), V("Pap Test")) and date(S.year - 2, S.month, S.day) <= d <= E:
            num = True
        if has_code(o.get("code"), V("HPV Test")) and date(S.year - 4, S.month, S.day) <= d <= E:
            a = d.year - bd.year - ((d.month, d.day) < (bd.month, bd.day))
            if a >= 30:
                num = True
    out["numerator"] = num
    return out
