from datetime import date

SNOMED = "http://snomed.info/sct"
LOINC = "http://loinc.org"
BAD = ("entered-in-error", "cancelled", "refuted", "draft", "not-done")


def _d(s):
    if not s:
        return None
    try:
        return date.fromisoformat(str(s)[:10])
    except ValueError:
        return None


def _codes(cc):
    out = set()
    if isinstance(cc, dict):
        cc = [cc]
    for c in cc or []:
        for k in (c or {}).get("coding", []) or []:
            out.add((k.get("system"), k.get("code")))
    return out


def _in(cc, *sets):
    cs = _codes(cc)
    return any(cs & s for s in sets)


def _span(r):
    for k in ("period", "effectivePeriod", "performedPeriod", "onsetPeriod"):
        p = r.get(k)
        if isinstance(p, dict):
            s, e = _d(p.get("start")), _d(p.get("end"))
            if s or e:
                return s or e, e or s
    for k in ("effectiveDateTime", "performedDateTime", "onsetDateTime", "authoredOn",
              "recordedDate", "issued", "occurrenceDateTime", "date"):
        d = _d(r.get(k))
        if d:
            return d, d
    return None, None


def _overlap(r, a, b):
    s, e = _span(r)
    if s is None:
        return False
    return s <= b and e >= a


def _cond_active(r, a, b):
    """Condition's prevalence overlaps [a, b]."""
    s, _ = _span(r)
    if s and s > b:
        return False
    ab = _d(r.get("abatementDateTime")) or _d((r.get("abatementPeriod") or {}).get("start"))
    if ab and ab < a:
        return False
    return True


def evaluate(resources, valuesets, period_start, period_end):
    ps, pe = _d(period_start), _d(period_end)
    V = lambda n: valuesets.get(n, set())
    res = [r for r in resources if isinstance(r, dict)]
    pat = next((r for r in res if r.get("resourceType") == "Patient"), {})
    no = {"initial-population": False, "denominator": False,
          "denominator-exclusion": False, "numerator": False}
    bd = _d(pat.get("birthDate"))
    if not bd:
        return no
    age = pe.year - bd.year - ((pe.month, pe.day) < (bd.month, bd.day))
    if not 18 <= age <= 75:
        return no

    def of(t):
        return [r for r in res if r.get("resourceType") == t]

    def ok(r):
        return r.get("status") not in BAD

    # diabetes
    diabetes = False
    for c in of("Condition"):
        if not _in(c.get("code"), V("Diabetes")):
            continue
        ver = {k[1] for k in _codes(c.get("verificationStatus"))}
        if ver & {"entered-in-error", "refuted"}:
            continue
        if not _cond_active(c, ps, pe):
            continue
        st = {k[1] for k in _codes(c.get("clinicalStatus"))}
        if st & {"inactive", "resolved", "remission"}:
            ab = _d(c.get("abatementDateTime"))
            if not (ab and ab >= ps):
                continue
        diabetes = True
        break

    # visit
    visit_sets = [V(n) for n in (
        "Office Visit", "Annual Wellness Visit", "Home Healthcare Services",
        "Telephone Visits", "Virtual Encounter",
        "Preventive Care Services Established Office Visit, 18 and Up",
        "Preventive Care Services Initial Office Visit, 18 and Up")]
    visit = False
    for e in of("Encounter"):
        if e.get("status") in BAD + ("planned", "in-progress", "onleave", "arrived", "triaged"):
            continue
        if _in(e.get("type"), *visit_sets) and _overlap(e, ps, pe):
            visit = True
            break

    if not (diabetes and visit):
        return no
    out = dict(no)
    out["initial-population"] = True
    out["denominator"] = True

    hospice_disp = {(SNOMED, "428371000124100"), (SNOMED, "428361000124107")}
    proc_types = ("Procedure", "ServiceRequest", "DeviceRequest")

    hospice = False
    for r in res:
        t = r.get("resourceType")
        if not ok(r):
            continue
        if t == "Encounter":
            if _in(r.get("type"), V("Hospice Encounter")) and _overlap(r, ps, pe):
                hospice = True
            disp = (r.get("hospitalization") or {}).get("dischargeDisposition")
            if disp and _in(disp, hospice_disp) and _overlap(r, ps, pe):
                hospice = True
        elif t in proc_types:
            if _in(r.get("code"), V("Hospice Care Ambulatory")) and _overlap(r, ps, pe):
                hospice = True
        elif t == "Condition":
            if _in(r.get("code"), V("Hospice Diagnosis")) and _cond_active(r, ps, pe):
                hospice = True
        elif t == "Observation" and _overlap(r, ps, pe):
            if _in(r.get("code"), {(LOINC, "45755-6")}):
                v = r.get("valueCodeableConcept")
                if v is None or _in(v, {(SNOMED, "373066001")}):
                    hospice = True
            elif _in(r.get("code"), V("Hospice Care Ambulatory")):
                hospice = True

    palliative = False
    for r in res:
        t = r.get("resourceType")
        if not ok(r):
            continue
        if t == "Encounter" and _in(r.get("type"), V("Palliative Care Encounter")) \
                and _overlap(r, ps, pe):
            palliative = True
        elif t == "Condition" and _in(r.get("code"), V("Palliative Care Diagnosis")) \
                and _cond_active(r, ps, pe):
            palliative = True
        elif t in proc_types and _in(r.get("code"), V("Palliative Care Intervention")) \
                and _overlap(r, ps, pe):
            palliative = True
        elif t == "Observation" and _overlap(r, ps, pe) and (
                _in(r.get("code"), {(LOINC, "71007-9")})
                or _in(r.get("code"), V("Palliative Care Intervention"))):
            palliative = True

    nursing = False
    nh = {(SNOMED, "160734000")}
    if age >= 66:
        for r in res:
            t = r.get("resourceType")
            if t not in ("Condition", "Observation", "Procedure", "Encounter") or not ok(r):
                continue
            codes = r.get("type") if t == "Encounter" else r.get("code")
            hit = _in(codes, nh)
            if t == "Observation" and _in(r.get("code"), {(LOINC, "71802-3")}):
                hit = hit or _in(r.get("valueCodeableConcept"), nh)
            if hit:
                s, _ = _span(r)
                if s is None or s <= pe:
                    nursing = True

    frail_excl = False
    if age >= 66:
        frail = False
        for r in res:
            t = r.get("resourceType")
            if not ok(r):
                continue
            if t == "Encounter" and _in(r.get("type"), V("Frailty Encounter")) \
                    and _overlap(r, ps, pe):
                frail = True
            elif t == "Condition" and _in(r.get("code"), V("Frailty Diagnosis")) \
                    and _cond_active(r, ps, pe):
                frail = True
            elif t in proc_types + ("Device",):
                c = r.get("code") or r.get("type") or r.get("codeCodeableConcept")
                if _in(c, V("Frailty Device")) and (t == "Device" or _overlap(r, ps, pe)):
                    frail = True
            elif t == "Observation" and _overlap(r, ps, pe) and _in(
                    r.get("code"), V("Frailty Symptom"), V("Frailty Diagnosis"),
                    V("Frailty Device")):
                frail = True
        if frail:
            py = date(ps.year - 1, ps.month, ps.day)
            for r in res:
                t = r.get("resourceType")
                if not ok(r):
                    continue
                if t == "Condition" and _in(r.get("code"), V("Advanced Illness")) \
                        and _cond_active(r, py, pe):
                    frail_excl = True
                elif t in ("MedicationRequest", "MedicationStatement", "MedicationDispense",
                           "MedicationAdministration") \
                        and _in(r.get("medicationCodeableConcept"), V("Dementia Medications")) \
                        and _overlap(r, py, pe):
                    frail_excl = True

    if hospice or palliative or nursing or frail_excl:
        out["denominator-exclusion"] = True
        return out

    tests = V("HbA1c Laboratory Test") | {(LOINC, "97506-0")}
    byday = {}
    for o in of("Observation"):
        if o.get("status") not in ("final", "amended", "corrected"):
            continue
        if not _in(o.get("code"), tests):
            continue
        s, _ = _span(o)
        if s is None or not (ps <= s <= pe):
            continue
        q = o.get("valueQuantity")
        if not q or q.get("value") is None:
            continue
        if q.get("unit") not in (None, "%") and q.get("code") not in (None, "%"):
            continue
        byday.setdefault(s, []).append(float(q["value"]))
    if not byday:
        out["numerator"] = True
    else:
        out["numerator"] = min(byday[max(byday)]) > 9.0
    return out
