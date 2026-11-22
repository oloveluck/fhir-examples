from datetime import datetime, timedelta, timezone, date

INF_LO = datetime(1, 1, 1, tzinfo=timezone.utc)
INF_HI = datetime(9999, 12, 31, tzinfo=timezone.utc)
MS = timedelta(milliseconds=1)
OBS_CAT = "http://terminology.hl7.org/CodeSystem/observation-category"
FINAL = ("final", "amended", "corrected")
ENC_OK = ("finished", "arrived", "triaged", "in-progress", "onleave")


def _parse(s, end=False):
    """FHIR date/dateTime -> aware UTC datetime; partial dates give day/month/year bounds."""
    if not s:
        return None
    if len(s) <= 10:
        parts = [int(x) for x in s.split("-")]
        y = parts[0]
        if len(parts) == 1:
            a, b = datetime(y, 1, 1, tzinfo=timezone.utc), datetime(y + 1, 1, 1, tzinfo=timezone.utc)
        elif len(parts) == 2:
            m = parts[1]
            a = datetime(y, m, 1, tzinfo=timezone.utc)
            b = datetime(y + (m == 12), m % 12 + 1, 1, tzinfo=timezone.utc)
        else:
            a = datetime(y, parts[1], parts[2], tzinfo=timezone.utc)
            b = a + timedelta(days=1)
        return b - MS if end else a
    t = s.replace("Z", "+00:00")
    try:
        dt = datetime.fromisoformat(t)
    except ValueError:
        dt = datetime.fromisoformat(t[:19])
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def _codes(cc):
    out = []
    if not cc:
        return out
    if isinstance(cc, list):
        for c in cc:
            out += _codes(c)
        return out
    for c in cc.get("coding", []) or []:
        out.append((c.get("system"), c.get("code")))
    return out


def _in(cc, vs):
    return any(c in vs for c in _codes(cc))


def _interval(r, name):
    if name + "DateTime" in r:
        v = r[name + "DateTime"]
        return _parse(v), _parse(v, True)
    if name + "Instant" in r:
        v = r[name + "Instant"]
        return _parse(v), _parse(v, True)
    if name + "Period" in r:
        p = r[name + "Period"]
        return _parse(p.get("start")), _parse(p.get("end"), True)
    if name in r and isinstance(r[name], dict):
        p = r[name]
        return _parse(p.get("start")), _parse(p.get("end"), True)
    return None


def _latest(iv):
    if iv is None:
        return None
    return iv[1] if iv[1] is not None else iv[0]


def _overlaps(iv, lo, hi):
    if iv is None or (iv[0] is None and iv[1] is None):
        return False
    s = iv[0] or INF_LO
    e = iv[1] or INF_HI
    return s <= hi and e >= lo


def _during(iv, lo, hi):
    if iv is None or iv[0] is None or iv[1] is None:
        return False
    return iv[0] >= lo and iv[1] <= hi


def _age_at(birth, d):
    b = date.fromisoformat(birth[:10])
    return d.year - b.year - ((d.month, d.day) < (b.month, b.day))


def _plus_years(birth, n):
    b = date.fromisoformat(birth[:10])
    try:
        return datetime(b.year + n, b.month, b.day, tzinfo=timezone.utc)
    except ValueError:
        return datetime(b.year + n, b.month, 28, tzinfo=timezone.utc)


def _onset_start(c, birth):
    if "onsetDateTime" in c:
        return _parse(c["onsetDateTime"])
    if "onsetPeriod" in c:
        return _parse(c["onsetPeriod"].get("start"))
    if "onsetAge" in c and birth:
        try:
            return _plus_years(birth, int(c["onsetAge"]["value"]))
        except Exception:
            return None
    return None


def _abatement_end(c, birth):
    if "abatementDateTime" in c:
        return _parse(c["abatementDateTime"], True)
    if "abatementPeriod" in c:
        return _parse(c["abatementPeriod"].get("end"), True)
    if "abatementAge" in c and birth:
        try:
            return _plus_years(birth, int(c["abatementAge"]["value"]) + 1) - MS
        except Exception:
            return None
    return None


def _prevalence(c, birth):
    s = _onset_start(c, birth)
    if s is None:
        return None
    return (s, _abatement_end(c, birth))


def _obs_cat(o, code):
    return (OBS_CAT, code) in _codes(o.get("category"))


def evaluate(resources, valuesets, period_start, period_end):
    def vs(n):
        return valuesets.get(n, set())

    lo = _parse(period_start)
    hi = _parse(period_end, True)
    by = {}
    for r in resources:
        by.setdefault(r.get("resourceType"), []).append(r)
    pat = (by.get("Patient") or [{}])[0]
    birth = pat.get("birthDate")

    res = {"initial-population": False, "denominator": False,
           "denominator-exclusion": False, "numerator": False}
    if not birth:
        return res
    age = _age_at(birth, hi.date())
    if not (24 <= age <= 64 and pat.get("gender") == "female"):
        return res

    encs = [e for e in by.get("Encounter", []) if e.get("status") in ENC_OK]
    qual_sets = ["Office Visit", "Preventive Care Services Established Office Visit, 18 and Up",
                 "Preventive Care Services Initial Office Visit, 18 and Up", "Home Healthcare Services",
                 "Telephone Visits", "Virtual Encounter"]
    qual = any(_in(e.get("type"), vs(n)) and _during(_interval(e, "period"), lo, hi)
               for e in encs for n in qual_sets)
    if not qual:
        return res
    res["initial-population"] = True
    res["denominator"] = True

    def hospice():
        hosp_codes = (("http://snomed.info/sct", "428361000124107"),
                      ("http://snomed.info/sct", "428371000124100"))
        for e in encs:
            if _in(e.get("type"), vs("Encounter Inpatient")):
                dd = _codes((e.get("hospitalization") or {}).get("dischargeDisposition"))
                if any(c in hosp_codes for c in dd):
                    iv = _interval(e, "period")
                    if iv and iv[1] is not None and lo <= iv[1] <= hi:
                        return True
            if _in(e.get("type"), vs("Hospice Encounter")) and _overlaps(_interval(e, "period"), lo, hi):
                return True
        for o in by.get("Observation", []):
            if (o.get("status") in FINAL and _obs_cat(o, "survey")
                    and ("http://loinc.org", "45755-6") in _codes(o.get("code"))
                    and ("http://snomed.info/sct", "373066001") in _codes(o.get("valueCodeableConcept"))
                    and _overlaps(_interval(o, "effective"), lo, hi)):
                return True
        for s in by.get("ServiceRequest", []):
            if (s.get("status") in ("active", "completed") and s.get("intent") == "order"
                    and _in(s.get("code"), vs("Hospice Care Ambulatory"))):
                a = _parse(s.get("authoredOn"))
                if a and lo <= a <= hi:
                    return True
        for p in by.get("Procedure", []):
            if (p.get("status") == "completed" and _in(p.get("code"), vs("Hospice Care Ambulatory"))
                    and _overlaps(_interval(p, "performed"), lo, hi)):
                return True
        for c in by.get("Condition", []):
            if _in(c.get("code"), vs("Hospice Diagnosis")) and _overlaps(_prevalence(c, birth), lo, hi):
                return True
        return False

    def palliative():
        for o in by.get("Observation", []):
            if (o.get("status") in FINAL and _obs_cat(o, "survey")
                    and ("http://loinc.org", "71007-9") in _codes(o.get("code"))
                    and _overlaps(_interval(o, "effective"), lo, hi)):
                return True
        for c in by.get("Condition", []):
            if _in(c.get("code"), vs("Palliative Care Diagnosis")) and _overlaps(_prevalence(c, birth), lo, hi):
                return True
        for e in encs:
            if _in(e.get("type"), vs("Palliative Care Encounter")) and _overlaps(_interval(e, "period"), lo, hi):
                return True
        for p in by.get("Procedure", []):
            if (p.get("status") == "completed" and _in(p.get("code"), vs("Palliative Care Intervention"))
                    and _overlaps(_interval(p, "performed"), lo, hi)):
                return True
        return False

    def no_cervix():
        for p in by.get("Procedure", []):
            if p.get("status") == "completed" and _in(p.get("code"), vs("Hysterectomy with No Residual Cervix")):
                iv = _interval(p, "performed")
                if iv and iv[1] is not None and iv[1] <= hi:
                    return True
        for c in by.get("Condition", []):
            if _in(c.get("code"), vs("Congenital or Acquired Absence of Cervix")):
                pv = _prevalence(c, birth)
                if pv and pv[0] <= hi:
                    return True
        return False

    if hospice() or no_cervix() or palliative():
        res["denominator-exclusion"] = True
        return res

    def years_back(n):
        return lo.replace(year=lo.year - n)

    for o in by.get("Observation", []):
        if o.get("status") not in FINAL or not _obs_cat(o, "laboratory"):
            continue
        if not any(k.startswith("value") for k in o):
            continue
        l = _latest(_interval(o, "effective"))
        if l is None:
            continue
        if _in(o.get("code"), vs("Pap Test")) and years_back(2) <= l <= hi:
            res["numerator"] = True
        if (_in(o.get("code"), vs("HPV Test")) and years_back(4) <= l <= hi
                and _age_at(birth, l.date()) >= 30):
            res["numerator"] = True
    return res
