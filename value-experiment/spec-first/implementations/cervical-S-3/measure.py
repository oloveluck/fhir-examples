from datetime import date, datetime, timedelta, timezone

OBS_CAT = "http://terminology.hl7.org/CodeSystem/observation-category"
SN = "http://snomed.info/sct"


def pdate(s):
    """FHIR date/dateTime string -> date (UTC day) or None."""
    if not s or not isinstance(s, str):
        return None
    try:
        if len(s) <= 10:
            p = s.split("-")
            return date(int(p[0]), int(p[1]) if len(p) > 1 else 1, int(p[2]) if len(p) > 2 else 1)
        dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
        if dt.tzinfo is not None:
            dt = dt.astimezone(timezone.utc)
        return dt.date()
    except Exception:
        return None


def minus_years(d, n):
    try:
        return d.replace(year=d.year - n)
    except ValueError:
        return d.replace(year=d.year - n, day=28)


def plus_years(d, n):
    return minus_years(d, -n)


def codes_of(cc):
    out = set()
    if not cc:
        return out
    for c in cc.get("coding", []) or []:
        out.add((c.get("system"), c.get("code")))
    return out


def in_vs(cc, vs):
    return bool(codes_of(cc) & set(vs))


def has_cat(obs, code):
    for cc in obs.get("category", []) or []:
        if (OBS_CAT, code) in codes_of(cc):
            return True
    return False


def period_iv(p):
    if not p:
        return None
    return (pdate(p.get("start")), pdate(p.get("end")))


def to_interval(res, prefix, birth):
    if prefix + "DateTime" in res:
        d = pdate(res[prefix + "DateTime"])
        return (d, d)
    if prefix + "Instant" in res:
        d = pdate(res[prefix + "Instant"])
        return (d, d)
    if prefix + "Period" in res:
        return period_iv(res[prefix + "Period"])
    if prefix + "Age" in res and birth:
        a = res[prefix + "Age"].get("value")
        if a is not None:
            return (plus_years(birth, int(a)), plus_years(birth, int(a) + 1) - timedelta(days=1))
    if prefix + "Range" in res and birth:
        r = res[prefix + "Range"]
        lo = (r.get("low") or {}).get("value")
        hi = (r.get("high") or {}).get("value")
        if lo is not None and hi is not None:
            return (plus_years(birth, int(lo)), plus_years(birth, int(hi) + 1) - timedelta(days=1))
    return None


def latest(iv):
    if iv is None:
        return None
    return iv[1] if iv[1] is not None else iv[0]


def overlaps(iv, a, b):
    if iv is None:
        return False
    lo, hi = iv
    if lo is None and hi is None:
        return False
    return (lo is None or lo <= b) and (hi is None or hi >= a)


def during(iv, a, b):
    if iv is None or iv[0] is None or iv[1] is None:
        return False
    return a <= iv[0] and iv[1] <= b


def prevalence(cond, birth):
    onset = to_interval(cond, "onset", birth)
    start = onset[0] if onset else None
    ab = None
    if "abatementDateTime" in cond:
        d = pdate(cond["abatementDateTime"])
        ab = (d, d)
    elif "abatementPeriod" in cond:
        ab = period_iv(cond["abatementPeriod"])
    elif "abatementAge" in cond or "abatementRange" in cond:
        ab = to_interval(cond, "abatement", birth)
    end = ab[1] if ab else None
    return (start, end), start is not None


def evaluate(resources, valuesets, period_start, period_end):
    ps, pe = pdate(period_start), pdate(period_end)

    def vs(n):
        return valuesets.get(n, set())

    def by(t):
        return [r for r in resources if r.get("resourceType") == t]

    patient = (by("Patient") or [{}])[0]
    birth = pdate(patient.get("birthDate"))

    res = {"initial-population": False, "denominator": False,
           "denominator-exclusion": False, "numerator": False}

    if not birth or patient.get("gender") != "female":
        return res
    age = pe.year - birth.year - ((pe.month, pe.day) < (birth.month, birth.day))
    if not (24 <= age <= 64):
        return res

    enc_ok = ('finished', 'arrived', 'triaged', 'in-progress', 'onleave')
    encs = [e for e in by("Encounter") if e.get("status") in enc_ok]

    def enc_in(names):
        s = set()
        for n in names:
            s |= set(vs(n))
        return [e for e in encs if any(in_vs(t, s) for t in e.get("type", []) or [])]

    qual = enc_in(["Office Visit",
                   "Preventive Care Services Established Office Visit, 18 and Up",
                   "Preventive Care Services Initial Office Visit, 18 and Up",
                   "Home Healthcare Services", "Telephone Visits", "Virtual Encounter"])
    if not any(during(period_iv(e.get("period")), ps, pe) for e in qual):
        return res
    res["initial-population"] = True
    res["denominator"] = True

    hosp_codes = {(SN, "428361000124107"), (SN, "428371000124100")}
    excl = False
    for e in enc_in(["Encounter Inpatient"]):
        dd = (e.get("hospitalization") or {}).get("dischargeDisposition")
        iv = period_iv(e.get("period"))
        if dd and codes_of(dd) & hosp_codes and iv and iv[1] and ps <= iv[1] <= pe:
            excl = True
    for e in enc_in(["Hospice Encounter"]):
        if overlaps(period_iv(e.get("period")), ps, pe):
            excl = True
    for e in enc_in(["Palliative Care Encounter"]):
        if overlaps(period_iv(e.get("period")), ps, pe):
            excl = True
    for o in by("Observation"):
        if o.get("status") in ('final', 'amended', 'corrected') and has_cat(o, "survey"):
            iv = to_interval(o, "effective", birth)
            if (in_vs(o.get("code"), {("http://loinc.org", "45755-6")})
                    and (SN, "373066001") in codes_of(o.get("valueCodeableConcept"))
                    and overlaps(iv, ps, pe)):
                excl = True
            if in_vs(o.get("code"), {("http://loinc.org", "71007-9")}) and overlaps(iv, ps, pe):
                excl = True
    for s in by("ServiceRequest"):
        if (s.get("status") in ('active', 'completed') and s.get("intent") == 'order'
                and in_vs(s.get("code"), vs("Hospice Care Ambulatory"))):
            d = pdate(s.get("authoredOn"))
            if d and ps <= d <= pe:
                excl = True
    for p in by("Procedure"):
        if p.get("status") != "completed":
            continue
        iv = to_interval(p, "performed", birth)
        if in_vs(p.get("code"), vs("Hospice Care Ambulatory")) and overlaps(iv, ps, pe):
            excl = True
        if in_vs(p.get("code"), vs("Palliative Care Intervention")) and overlaps(iv, ps, pe):
            excl = True
        if in_vs(p.get("code"), vs("Hysterectomy with No Residual Cervix")):
            if iv and iv[1] is not None and iv[1] <= pe:
                excl = True
    for c in by("Condition"):
        iv, ok = prevalence(c, birth)
        if not ok:
            continue
        if in_vs(c.get("code"), vs("Hospice Diagnosis")) and overlaps(iv, ps, pe):
            excl = True
        if in_vs(c.get("code"), vs("Palliative Care Diagnosis")) and overlaps(iv, ps, pe):
            excl = True
        if in_vs(c.get("code"), vs("Congenital or Acquired Absence of Cervix")) and iv[0] <= pe:
            excl = True
    res["denominator-exclusion"] = excl

    num = False
    for o in by("Observation"):
        if o.get("status") not in ('final', 'amended', 'corrected') or not has_cat(o, "laboratory"):
            continue
        if not any(k.startswith("value") for k in o):
            continue
        d = latest(to_interval(o, "effective", birth))
        if d is None:
            continue
        if in_vs(o.get("code"), vs("Pap Test")) and minus_years(ps, 2) <= d <= pe:
            num = True
        if in_vs(o.get("code"), vs("HPV Test")) and minus_years(ps, 4) <= d <= pe:
            a = d.year - birth.year - ((d.month, d.day) < (birth.month, birth.day))
            if a >= 30:
                num = True
    res["numerator"] = num and not excl
    return res
