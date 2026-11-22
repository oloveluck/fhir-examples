from datetime import date, timedelta
import re

SNOMED = "http://snomed.info/sct"
LOINC = "http://loinc.org"
BAD_STATUS = ("entered-in-error", "not-done", "revoked", "cancelled", "draft")


def _d(s):
    if not s or not isinstance(s, str):
        return None
    m = re.match(r"(\d{4})(?:-(\d{2}))?(?:-(\d{2}))?", s)
    if not m:
        return None
    return date(int(m.group(1)), int(m.group(2) or 1), int(m.group(3) or 1))


def _dend(s):
    if not s:
        return None
    d = _d(s)
    if d and len(s) == 4:
        return date(d.year, 12, 31)
    if d and len(s) == 7:
        nm = date(d.year + (d.month == 12), d.month % 12 + 1, 1)
        return nm - timedelta(days=1)
    return d


def _codings(cc):
    out = set()
    if isinstance(cc, dict):
        for c in cc.get("coding", []) or []:
            out.add((c.get("system"), c.get("code")))
    elif isinstance(cc, list):
        for x in cc:
            out |= _codings(x)
    return out


def _rcodes(r, with_value=True):
    out = set()
    for k in ("code", "type", "medicationCodeableConcept", "codeCodeableConcept"):
        if k in r:
            out |= _codings(r[k])
    if with_value:
        out |= _codings(r.get("valueCodeableConcept"))
    return out


def _interval(r):
    t = r.get("resourceType")
    if t == "Condition":
        s = _d(r.get("onsetDateTime")) or _d((r.get("onsetPeriod") or {}).get("start"))
        e = _dend(r.get("abatementDateTime")) or _dend((r.get("abatementPeriod") or {}).get("end"))
        if s is None:
            s = _d(r.get("recordedDate"))
        return s, e
    for k in ("effectiveDateTime", "effectiveInstant", "performedDateTime", "occurrenceDateTime", "authoredOn"):
        if r.get(k):
            return _d(r[k]), _dend(r[k])
    for k in ("effectivePeriod", "performedPeriod", "period", "occurrencePeriod"):
        if isinstance(r.get(k), dict):
            p = r[k]
            return _d(p.get("start")), _dend(p.get("end"))
    return None, None


def _overlaps(iv, a, b, open_end=True):
    s, e = iv
    if s is None and e is None:
        return False
    if s is None:
        s = e
    if e is None:
        e = b if open_end else s
    return s <= b and e >= a


def evaluate(resources, valuesets, period_start, period_end):
    ps, pe = _d(period_start), _d(period_end)
    py = date(ps.year - 1, ps.month, ps.day)
    origin = date(1900, 1, 1)
    vs = lambda n: valuesets.get(n, set())
    res = {"initial-population": False, "denominator": False,
           "denominator-exclusion": False, "numerator": False}

    patient = next((r for r in resources if r.get("resourceType") == "Patient"), None)
    if not patient:
        return res
    bd = _d(patient.get("birthDate"))
    if not bd:
        return res
    age = pe.year - bd.year - ((pe.month, pe.day) < (bd.month, bd.day))
    if not (18 <= age <= 85):
        return res

    def of(t):
        return [r for r in resources if r.get("resourceType") == t]

    def has(r, names, with_value=True):
        c = _rcodes(r, with_value)
        return any(c & vs(n) for n in names)

    def enc_ok(e):
        return e.get("status") == "finished"

    visit_sets = ["Office Visit", "Annual Wellness Visit", "Home Healthcare Services",
                  "Preventive Care Services Established Office Visit, 18 and Up",
                  "Preventive Care Services Initial Office Visit, 18 and Up",
                  "Telephone Visits", "Virtual Encounter"]
    if not any(enc_ok(e) and has(e, visit_sets) and _overlaps(_interval(e), ps, pe, False)
               for e in of("Encounter")):
        return res

    # essential hypertension: starts before and continues into, or starts during, first 6 months
    m = ps.month + 6
    end6 = date(ps.year + (m - 1) // 12, (m - 1) % 12 + 1, 1) - timedelta(days=1)
    htn = False
    for c in of("Condition"):
        if not has(c, ["Essential Hypertension"]):
            continue
        if any(x.get("code") in ("entered-in-error", "refuted")
               for x in (c.get("verificationStatus") or {}).get("coding", [])):
            continue
        s, e = _interval(c)
        if s is None or s > end6:
            continue
        status = {x.get("code") for x in (c.get("clinicalStatus") or {}).get("coding", [])}
        if e is None and status & {"inactive", "resolved", "remission"}:
            continue
        if e is not None and e < ps:
            continue
        htn = True
        break
    if not htn:
        return res
    res["initial-population"] = res["denominator"] = True

    def conds(names, a, b):
        return any(has(c, names) and _overlaps(_interval(c), a, b) for c in of("Condition"))

    excl = False
    # hospice
    for e in of("Encounter"):
        if enc_ok(e) and _overlaps(_interval(e), ps, pe, False):
            if has(e, ["Hospice Encounter"]):
                excl = True
        dd = _codings((e.get("hospitalization") or {}).get("dischargeDisposition"))
        if enc_ok(e) and _overlaps(_interval(e), ps, pe, False) and \
                dd & {(SNOMED, "428371000124100"), (SNOMED, "428361000124107")}:
            excl = True
    for r in resources:
        t = r.get("resourceType")
        if t in ("ServiceRequest", "Procedure", "Observation", "DeviceRequest") and r.get("status") not in BAD_STATUS:
            iv = _interval(r)
            if t == "Observation":
                if (LOINC, "45755-6") in _rcodes(r, False) and \
                        (SNOMED, "373066001") in _codings(r.get("valueCodeableConcept")) and \
                        _overlaps(iv, ps, pe, False):
                    excl = True
            elif has(r, ["Hospice Care Ambulatory"]) and _overlaps(iv, ps, pe, False):
                excl = True
    if conds(["Hospice Diagnosis"], ps, pe):
        excl = True

    # ESRD / dialysis / transplant
    if conds(["End Stage Renal Disease", "Chronic Kidney Disease, Stage 5", "Kidney Transplant Recipient"],
             origin, pe):
        excl = True
    for r in resources:
        if r.get("resourceType") in ("Procedure", "Encounter", "ServiceRequest") and \
                r.get("status") not in BAD_STATUS and \
                has(r, ["Dialysis Services", "Kidney Transplant", "ESRD Monthly Outpatient Services"]) and \
                _overlaps(_interval(r), origin, pe, False):
            if r.get("resourceType") == "ServiceRequest":
                continue
            excl = True

    # pregnancy
    if conds(["Pregnancy"], ps, pe):
        excl = True

    # palliative
    if conds(["Palliative Care Diagnosis"], ps, pe):
        excl = True
    for r in resources:
        t = r.get("resourceType")
        if r.get("status") in BAD_STATUS:
            continue
        if t == "Encounter" and enc_ok(r) and has(r, ["Palliative Care Encounter"]) and \
                _overlaps(_interval(r), ps, pe, False):
            excl = True
        if t in ("Procedure", "ServiceRequest", "Observation") and \
                has(r, ["Palliative Care Intervention"], False) and _overlaps(_interval(r), ps, pe, False):
            excl = True
        if t == "Observation" and (LOINC, "71007-9") in _rcodes(r, False) and \
                _overlaps(_interval(r), ps, pe, False):
            excl = True

    if age >= 66:
        # nursing home
        for r in resources:
            if r.get("resourceType") in ("Condition", "Observation", "Procedure") and \
                    (SNOMED, "160734000") in _rcodes(r) and r.get("status") not in BAD_STATUS:
                s, _e = _interval(r)
                if s is None or s <= pe:
                    excl = True
        # frailty (+ advanced illness / dementia meds for 66-80)
        frail = False
        fnames = ["Frailty Device", "Frailty Diagnosis", "Frailty Encounter", "Frailty Symptom"]
        for r in resources:
            t = r.get("resourceType")
            if t == "Patient" or r.get("status") in BAD_STATUS:
                continue
            if t == "Encounter" and not enc_ok(r):
                continue
            if has(r, fnames) and _overlaps(_interval(r), ps, pe, t == "Condition"):
                frail = True
        if frail:
            if age >= 81:
                excl = True
            else:
                adv = conds(["Advanced Illness"], py, pe)
                for e in of("Encounter"):
                    pass
                for mr in of("MedicationRequest"):
                    if mr.get("doNotPerform") or mr.get("status") in ("entered-in-error", "cancelled", "draft"):
                        continue
                    if has(mr, ["Dementia Medications"]):
                        s = _d(mr.get("authoredOn"))
                        e = None
                        dr = mr.get("dispenseRequest") or {}
                        if dr.get("validityPeriod"):
                            s = _d(dr["validityPeriod"].get("start")) or s
                            e = _dend(dr["validityPeriod"].get("end"))
                        if s and e is None:
                            dur = (dr.get("expectedSupplyDuration") or {}).get("value")
                            e = s + timedelta(days=int(dur)) if dur else s
                        if s and s <= pe and (e is None or e >= py):
                            adv = True
                if adv:
                    excl = True
    res["denominator-exclusion"] = excl
    if excl:
        return res

    # numerator
    bad_enc = set()
    for e in of("Encounter"):
        cls = (e.get("class") or {}).get("code")
        if cls in ("IMP", "ACUTE", "NONAC", "EMER") or has(
                e, ["Encounter Inpatient", "Emergency Department Evaluation and Management Visit"]):
            bad_enc.add("Encounter/" + str(e.get("id")))
            bad_enc.add(str(e.get("id")))
    readings = {}
    for o in of("Observation"):
        if o.get("status") not in ("final", "amended", "corrected"):
            continue
        d = _interval(o)[0]
        if d is None or not (ps <= d <= pe):
            continue
        ref = (o.get("encounter") or {}).get("reference") or ""
        if ref and (ref in bad_enc or ref.split("/")[-1] in bad_enc):
            continue
        cats = set()
        for c in o.get("category", []) or []:
            cats |= {x.get("code") for x in c.get("coding", [])}
        if cats and "vital-signs" not in cats:
            continue
        items = [(o.get("code"), o.get("valueQuantity"))]
        for comp in o.get("component", []) or []:
            items.append((comp.get("code"), comp.get("valueQuantity")))
        for code, q in items:
            if not q or q.get("value") is None or q.get("comparator"):
                continue
            cs = _codings(code)
            slot = readings.setdefault(d, ([], []))
            if (LOINC, "8480-6") in cs:
                slot[0].append(q["value"])
            elif (LOINC, "8462-4") in cs:
                slot[1].append(q["value"])
    days = sorted(d for d, (s, di) in readings.items() if s and di)
    if days:
        s, di = readings[days[-1]]
        res["numerator"] = min(s) < 140 and min(di) < 90
    return res
