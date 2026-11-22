from datetime import datetime, timedelta
import re


def pdt(s):
    """Parse FHIR date/dateTime/instant to naive datetime (offset ignored)."""
    if not s or not isinstance(s, str):
        return None
    m = re.match(r"(\d{4})(?:-(\d\d))?(?:-(\d\d))?(?:T(\d\d)(?::(\d\d))?(?::(\d\d))?(?:\.(\d+))?)?", s)
    if not m:
        return None
    y, mo, d, h, mi, sec, fr = m.groups()
    us = int((fr or "0")[:6].ljust(6, "0"))
    try:
        return datetime(int(y), int(mo or 1), int(d or 1), int(h or 0), int(mi or 0), int(sec or 0), us)
    except ValueError:
        return None


def add_months(dt, n):
    y = dt.year + (dt.month - 1 + n) // 12
    mo = (dt.month - 1 + n) % 12 + 1
    d = dt.day
    while True:
        try:
            return dt.replace(year=y, month=mo, day=d)
        except ValueError:
            d -= 1


def codes_of(cc):
    out = []
    if isinstance(cc, dict):
        for c in cc.get("coding", []) or []:
            out.append((c.get("system"), c.get("code")))
    return out


def in_vs(cc, vs):
    if cc is None:
        return False
    if isinstance(cc, list):
        return any(in_vs(x, vs) for x in cc)
    return any((s, c) in vs for s, c in codes_of(cc))


def has_code(cc, system, code):
    return (system, code) in codes_of(cc)


def interval_of(res, name):
    """(lo, hi) naive datetimes of a choice element; None if absent."""
    for suf in ("DateTime", "Instant"):
        if res.get(name + suf):
            v = pdt(res[name + suf])
            return (v, v) if v else None
    p = res.get(name + "Period")
    if isinstance(p, dict):
        return (pdt(p.get("start")), pdt(p.get("end")))
    return None


def end_of_day(dt):
    return dt.replace(hour=23, minute=59, second=59, microsecond=999000)


def overlaps(iv, lo, hi):
    if iv is None:
        return False
    a, b = iv
    return (a is None or a <= hi) and (b is None or b >= lo)


FIN = ("final", "amended", "corrected")
CAT = "http://terminology.hl7.org/CodeSystem/observation-category"
SNO = "http://snomed.info/sct"
LOINC = "http://loinc.org"


def evaluate(resources, valuesets, period_start, period_end):
    def VS(n):
        return valuesets.get(n, set())

    MPS = pdt(period_start)
    MPE = end_of_day(pdt(period_end))
    by = {}
    for r in resources:
        by.setdefault(r.get("resourceType"), []).append(r)
    patient = (by.get("Patient") or [{}])[0]
    birth = pdt(patient.get("birthDate"))

    age = None
    if birth:
        age = MPE.year - birth.year - ((MPE.month, MPE.day) < (birth.month, birth.day))

    def qty_date(q):
        if not birth or not isinstance(q, dict) or q.get("value") is None:
            return None
        v = q["value"]
        u = q.get("code") or q.get("unit") or "a"
        if u in ("a", "year", "years"):
            return add_months(birth, int(round(v * 12)))
        if u in ("mo", "month", "months"):
            return add_months(birth, int(v))
        if u in ("wk", "week", "weeks"):
            return birth + timedelta(weeks=v)
        if u in ("d", "day", "days"):
            return birth + timedelta(days=v)
        return None

    def prevalence(c):
        on = interval_of(c, "onset")
        if on is None:
            d = qty_date(c.get("onsetAge"))
            on = (d, d)
        lo = on[0]
        ab = None
        if c.get("abatementDateTime"):
            v = pdt(c["abatementDateTime"])
            ab = (v, v)
        elif isinstance(c.get("abatementPeriod"), dict):
            p = c["abatementPeriod"]
            h = pdt(p.get("end"))
            ab = (pdt(p.get("start")), h - timedelta(milliseconds=1) if h else None)
        elif isinstance(c.get("abatementAge"), dict):
            d = qty_date(c["abatementAge"])
            if d:
                ab = (d, add_months(d, 12) - timedelta(milliseconds=1))
        elif isinstance(c.get("abatementRange"), dict):
            r = c["abatementRange"]
            d1 = qty_date(r.get("low"))
            d2 = qty_date(r.get("high"))
            if d2:
                ab = (d1, add_months(d2, 12) - timedelta(milliseconds=1))
        hi = ab[1] if ab else None
        active = any(s == "http://terminology.hl7.org/CodeSystem/condition-clinical" and
                     cd in ("active", "recurrence", "relapse") for s, cd in codes_of(c.get("clinicalStatus")))
        if active:
            return (lo, hi, True)
        if hi is None:
            return (lo, None, False)  # open end with unknown bound
        return (lo, hi, True)

    def cond_overlaps(c, lo, hi):
        a, b, ok = prevalence(c)
        if not ok:
            return False
        return overlaps((a, b), lo, hi)

    def conds(n):
        vs = VS(n)
        return [c for c in by.get("Condition", []) if in_vs(c.get("code"), vs)]

    def encs(n):
        vs = VS(n)
        return [e for e in by.get("Encounter", []) if in_vs(e.get("type"), vs)
                and e.get("status") in ("finished", "arrived", "triaged", "in-progress", "onleave")]

    def eperiod(e):
        p = e.get("period") or {}
        return (pdt(p.get("start")), pdt(p.get("end")))

    def procs(n):
        return [p for p in by.get("Procedure", []) if in_vs(p.get("code"), VS(n)) and p.get("status") == "completed"]

    def survey(o):
        return any(has_code(c, CAT, "survey") for c in (o.get("category") or []))

    def obs_code(system, code, statuses=FIN):
        return [o for o in by.get("Observation", []) if has_code(o.get("code"), system, code)
                and o.get("status") in statuses]

    # ---- Initial population
    htn_end = add_months(MPS, 6) - timedelta(milliseconds=1)
    htn = any(cond_overlaps(c, MPS, htn_end) for c in conds("Essential Hypertension"))
    qe = False
    for n in ["Office Visit", "Annual Wellness Visit",
              "Preventive Care Services Established Office Visit, 18 and Up",
              "Preventive Care Services Initial Office Visit, 18 and Up",
              "Home Healthcare Services", "Virtual Encounter", "Telephone Visits"]:
        for e in encs(n):
            a, b = eperiod(e)
            if a and a >= MPS and (b or a) <= MPE:
                qe = True
    ip = age is not None and 18 <= age <= 85 and htn and qe

    res = {"initial-population": ip, "denominator": ip, "denominator-exclusion": False, "numerator": False}
    if not ip:
        return res

    # ---- Exclusions: hospice
    hospice = False
    for e in encs("Encounter Inpatient"):
        dd = (e.get("hospitalization") or {}).get("dischargeDisposition")
        if has_code(dd, SNO, "428361000124107") or has_code(dd, SNO, "428371000124100"):
            a, b = eperiod(e)
            if b and MPS <= b <= MPE:
                hospice = True
    for e in encs("Hospice Encounter"):
        if overlaps(eperiod(e), MPS, MPE):
            hospice = True
    for o in obs_code(LOINC, "45755-6"):
        if survey(o) and has_code(o.get("valueCodeableConcept"), SNO, "373066001") \
                and overlaps(interval_of(o, "effective"), MPS, MPE):
            hospice = True
    for s in by.get("ServiceRequest", []):
        if in_vs(s.get("code"), VS("Hospice Care Ambulatory")) and s.get("status") in ("active", "completed") \
                and s.get("intent") == "order":
            d = pdt(s.get("authoredOn"))
            if d and MPS <= d <= MPE:
                hospice = True
    for p in procs("Hospice Care Ambulatory"):
        if overlaps(interval_of(p, "performed"), MPS, MPE):
            hospice = True
    if any(cond_overlaps(c, MPS, MPE) for c in conds("Hospice Diagnosis")):
        hospice = True

    excl = hospice
    for n in ["Pregnancy", "End Stage Renal Disease", "Kidney Transplant Recipient",
              "Chronic Kidney Disease, Stage 5"]:
        if any(cond_overlaps(c, MPS, MPE) for c in conds(n)):
            excl = True
    for n in ["Kidney Transplant", "Dialysis Services"]:
        for p in procs(n):
            iv = interval_of(p, "performed")
            if iv:
                end = iv[1] or iv[0]
                if end is not None and end <= MPE:
                    excl = True
    for e in encs("ESRD Monthly Outpatient Services"):
        a, b = eperiod(e)
        if a and a <= MPE:
            excl = True

    # ---- frailty
    frailty = False
    for d in by.get("DeviceRequest", []):
        if in_vs(d.get("codeCodeableConcept"), VS("Frailty Device")) and d.get("status") in ("active", "completed") \
                and d.get("intent") == "order":
            t = pdt(d.get("authoredOn"))
            if t and MPS <= t <= MPE:
                frailty = True
    for o in obs_code(LOINC, "98181-1"):
        if survey(o) and in_vs(o.get("valueCodeableConcept"), VS("Frailty Device")):
            iv = interval_of(o, "effective")
            if iv:
                end = iv[1] or iv[0]
                if end and MPS <= end <= MPE:
                    frailty = True
    if any(cond_overlaps(c, MPS, MPE) for c in conds("Frailty Diagnosis")):
        frailty = True
    for e in encs("Frailty Encounter"):
        if overlaps(eperiod(e), MPS, MPE):
            frailty = True
    for o in by.get("Observation", []):
        if in_vs(o.get("code"), VS("Frailty Symptom")) and o.get("status") in ("preliminary",) + FIN \
                and overlaps(interval_of(o, "effective"), MPS, MPE):
            frailty = True

    ystart = add_months(MPS, -12)
    adv = False
    for c in conds("Advanced Illness"):
        a, b, ok = prevalence(c)
        if a and ystart <= a <= MPE:
            adv = True

    def med_period(r):
        di = r.get("dosageInstruction") or []
        dosage = di[0] if len(di) == 1 else {}
        dr = dosage.get("doseAndRate") or []
        dar = dr[0] if len(dr) == 1 else {}
        rep = (dosage.get("timing") or {}).get("repeat") or {}
        freq = rep.get("frequencyMax") or rep.get("frequency")
        per = rep.get("period")
        mult = {"s": 1 / 86400, "min": 1 / 1440, "h": 1 / 24, "d": 1, "wk": 7, "mo": 30, "a": 365}.get(
            rep.get("periodUnit"))
        dpd = None
        if freq and per and mult:
            dpd = freq / (per * mult)
        elif rep.get("timeOfDay"):
            dpd = float(len(rep["timeOfDay"]))
        if dpd is None:
            dpd = 1.0
        dose = None
        if isinstance(dar.get("doseRange"), dict):
            dose = (dar["doseRange"].get("high") or {}).get("value")
        if dose is None and isinstance(dar.get("doseQuantity"), dict):
            dose = dar["doseQuantity"].get("value")
        bounds = rep.get("boundsPeriod")
        bstart = pdt(bounds.get("start")) if isinstance(bounds, dict) else None
        bend = pdt(bounds.get("end")) if isinstance(bounds, dict) else None
        dreq = r.get("dispenseRequest") or {}
        supply = None
        es = dreq.get("expectedSupplyDuration")
        if isinstance(es, dict) and es.get("value") is not None:
            f = {"d": 1, "day": 1, "days": 1, "wk": 7, "week": 7, "weeks": 7, "mo": 30, "month": 30,
                 "months": 30, "h": 1 / 24}.get(es.get("code") or es.get("unit"))
            if f:
                supply = es["value"] * f
        qv = (dreq.get("quantity") or {}).get("value")
        refills = dreq.get("numberOfRepeatsAllowed") or 0
        start = bstart or pdt(r.get("authoredOn")) or pdt((dreq.get("validityPeriod") or {}).get("start"))
        if start:
            start = start.replace(hour=0, minute=0, second=0, microsecond=0)
        total = None
        if supply is not None:
            total = supply * (1 + refills)
        elif qv is not None and dose:
            total = qv / (dose * dpd) * (1 + refills)
        if start and total is not None:
            return (start, start + timedelta(days=total - 1))
        if start and bend:
            return (start, bend)
        return None

    dem = False
    for r in by.get("MedicationRequest", []):
        if r.get("status") == "active" and r.get("intent") == "order" \
                and in_vs(r.get("medicationCodeableConcept"), VS("Dementia Medications")):
            p = med_period(r)
            if p and overlaps((p[0], end_of_day(p[1])), ystart, MPE):
                dem = True

    if (66 <= age <= 80 and frailty and (adv or dem)) or (age >= 81 and frailty):
        excl = True

    if age >= 66:
        cand = []
        for o in obs_code(LOINC, "71802-3"):
            if survey(o):
                iv = interval_of(o, "effective")
                if iv:
                    end = iv[1] or iv[0]
                    if end and end <= MPE:
                        cand.append((end, o))
        if cand:
            cand.sort(key=lambda x: x[0])
            if has_code(cand[-1][1].get("valueCodeableConcept"), SNO, "160734000"):
                excl = True

    pal = False
    for o in obs_code(LOINC, "71007-9"):
        if survey(o) and overlaps(interval_of(o, "effective"), MPS, MPE):
            pal = True
    if any(cond_overlaps(c, MPS, MPE) for c in conds("Palliative Care Diagnosis")):
        pal = True
    for e in encs("Palliative Care Encounter"):
        if overlaps(eperiod(e), MPS, MPE):
            pal = True
    for p in procs("Palliative Care Intervention"):
        if overlaps(interval_of(p, "performed"), MPS, MPE):
            pal = True
    if pal:
        excl = True

    res["denominator-exclusion"] = excl
    if excl:
        return res

    # ---- Numerator
    enc_by_id = {e.get("id"): e for e in by.get("Encounter", [])}
    BAD = {"EMER", "IMP", "ACUTE", "NONAC", "PRENC", "SS"}
    SYS = (LOINC, "8480-6")
    DIA = (LOINC, "8462-4")

    def is_bp(o):
        if any(str(p).endswith("observation-bp") for p in (o.get("meta") or {}).get("profile", [])):
            return True
        if has_code(o.get("code"), LOINC, "85354-9"):
            return True
        cs = [codes_of(c.get("code")) for c in o.get("component", []) or []]
        return any(SYS in x for x in cs) and any(DIA in x for x in cs)

    qual = []
    for o in by.get("Observation", []):
        if not is_bp(o) or o.get("status") not in FIN:
            continue
        ref = (o.get("encounter") or {}).get("reference")
        if ref:
            e = enc_by_id.get(ref.split("/")[-1])
            if e and (e.get("class") or {}).get("code") in BAD:
                continue
        iv = interval_of(o, "effective")
        if not iv:
            continue
        latest = iv[1] or iv[0]
        if latest is None or not (MPS <= latest <= MPE):
            continue
        qual.append((o, latest.date()))
    if not qual:
        return res
    day = max(d for _, d in qual)

    def lowest(code):
        vals = []
        for o, d in qual:
            if d != day:
                continue
            comps = [c for c in o.get("component", []) or [] if code in codes_of(c.get("code"))]
            if len(comps) > 1:
                raise ValueError("singleton")
            v = None
            if comps and isinstance(comps[0].get("valueQuantity"), dict):
                q = comps[0]["valueQuantity"]
                if q.get("value") is not None and (q.get("code") or q.get("unit")) in ("mm[Hg]", "mmHg"):
                    v = q["value"]
            vals.append(v)
        if not vals or any(v is None for v in vals):
            return None  # a null sorts first
        return min(vals)

    try:
        s = lowest(SYS)
        d = lowest(DIA)
    except ValueError:
        return res
    res["numerator"] = s is not None and d is not None and s < 140 and d < 90
    return res
