from datetime import date


def _d(s):
    if not s:
        return None
    try:
        return date.fromisoformat(str(s)[:10])
    except ValueError:
        return None


def _codings(x):
    out = []
    if isinstance(x, dict):
        for c in x.get("coding", []) or []:
            out.append((c.get("system"), c.get("code")))
    elif isinstance(x, list):
        for i in x:
            out += _codings(i)
    return out


def _all_codes(r):
    out = []
    for k in ("code", "type", "serviceType", "medicationCodeableConcept", "codeCodeableConcept",
              "category", "reasonCode"):
        v = r.get(k)
        if v is not None:
            out += _codings(v)
    c = r.get("class")
    if isinstance(c, dict):
        out.append((c.get("system"), c.get("code")))
    return out


def _span(r):
    for k in ("period", "effectivePeriod", "performedPeriod"):
        if isinstance(r.get(k), dict):
            return _d(r[k].get("start")), _d(r[k].get("end"))
    for k in ("effectiveDateTime", "performedDateTime", "authoredOn", "issued", "recordedDate"):
        if r.get(k):
            d = _d(r[k])
            return d, d
    if r.get("onsetDateTime") or r.get("abatementDateTime"):
        return _d(r.get("onsetDateTime")), _d(r.get("abatementDateTime"))
    if isinstance(r.get("onsetPeriod"), dict):
        return _d(r["onsetPeriod"].get("start")), _d(r["onsetPeriod"].get("end"))
    return None, None


def _overlaps(r, a, b):
    s, e = _span(r)
    if s is None and e is None:
        return False
    if s is not None and s > b:
        return False
    if e is not None and e < a:
        return False
    return True


def _cond_active_in(r, a, b):
    st = _codings(r.get("clinicalStatus") or {})
    ab = _d(r.get("abatementDateTime")) or _d((r.get("abatementPeriod") or {}).get("start"))
    if any(c in ("inactive", "resolved", "remission") for _, c in st):
        if ab is None or ab < a:
            return False
    if any(c in ("entered-in-error", "refuted") for _, c in _codings(r.get("verificationStatus") or {})):
        return False
    on = _d(r.get("onsetDateTime")) or _d((r.get("onsetPeriod") or {}).get("start")) \
        or _d(r.get("recordedDate"))
    if on is not None and on > b:
        return False
    if ab is not None and ab < a:
        return False
    return True


def evaluate(resources, valuesets, period_start, period_end):
    a, b = _d(period_start), _d(period_end)
    res = [r for r in resources if isinstance(r, dict)]
    pat = next((r for r in res if r.get("resourceType") == "Patient"), {})
    bd = _d(pat.get("birthDate"))
    out = {"initial-population": False, "denominator": False,
           "denominator-exclusion": False, "numerator": False}
    if bd is None:
        return out
    age = b.year - bd.year - ((b.month, b.day) < (bd.month, bd.day))
    if not (18 <= age <= 75):
        return out

    def of(*rts):
        return [r for r in res if r.get("resourceType") in rts]

    def has(r, *names):
        s = set()
        for n in names:
            s |= valuesets.get(n, set())
        return any(c in s for c in _all_codes(r))

    def ok(r):
        return r.get("status") not in ("entered-in-error", "cancelled", "draft", "not-done")

    diabetes = any(has(c, "Diabetes") and _cond_active_in(c, a, b) for c in of("Condition"))
    visit_names = ["Office Visit", "Annual Wellness Visit", "Home Healthcare Services",
                   "Preventive Care Services Established Office Visit, 18 and Up",
                   "Preventive Care Services Initial Office Visit, 18 and Up",
                   "Telephone Visits", "Virtual Encounter"]
    visit = any(has(e, *visit_names) and e.get("status") in (None, "finished", "in-progress", "arrived")
                and _overlaps(e, a, b) for e in of("Encounter"))
    if not (diabetes and visit):
        return out
    out["initial-population"] = out["denominator"] = True

    def any_in(rts, names, a_, b_):
        return any(has(r, *names) and ok(r) and _overlaps(r, a_, b_) for r in of(*rts))

    proc_like = ["Procedure", "ServiceRequest", "Observation", "DeviceRequest", "Encounter"]
    hospice = any_in(["Encounter"], ["Hospice Encounter"], a, b) \
        or any_in(proc_like, ["Hospice Care Ambulatory"], a, b) \
        or any(has(c, "Hospice Diagnosis") and _cond_active_in(c, a, b) for c in of("Condition"))
    hs = {("http://snomed.info/sct", "428371000124100"), ("http://snomed.info/sct", "428361000124107")}
    for e in of("Encounter"):
        dd = (e.get("hospitalization") or {}).get("dischargeDisposition")
        if dd and any(c in hs for c in _codings(dd)) and _overlaps(e, a, b):
            hospice = True
    for o in of("Observation"):
        if ("http://loinc.org", "45755-6") in _all_codes(o) and _overlaps(o, a, b):
            v = o.get("valueCodeableConcept")
            if v is None or any(c[1] == "373066001" for c in _codings(v)):
                hospice = True

    palliative = any_in(["Encounter"], ["Palliative Care Encounter"], a, b) \
        or any_in(proc_like, ["Palliative Care Intervention"], a, b) \
        or any(has(c, "Palliative Care Diagnosis") and _cond_active_in(c, a, b) for c in of("Condition")) \
        or any(("http://loinc.org", "71007-9") in _all_codes(o) and ok(o) and _overlaps(o, a, b)
               for o in of("Observation"))

    nursing = False
    nh = ("http://snomed.info/sct", "160734000")
    for r in of("Observation", "Condition", "Procedure"):
        if nh in _all_codes(r) and ok(r):
            s, _ = _span(r)
            if r.get("resourceType") == "Condition":
                s = _d(r.get("onsetDateTime")) or _d(r.get("recordedDate")) or s
            if s is None or s <= b:
                nursing = True

    frail_ex = False
    if age >= 66:
        fn = ["Frailty Device", "Frailty Symptom", "Frailty Diagnosis", "Frailty Encounter"]
        frail = any_in(["Encounter", "DeviceRequest", "Procedure", "ServiceRequest", "Observation",
                        "DeviceUseStatement"], fn, a, b) \
            or any(has(c, *fn) and _cond_active_in(c, a, b) for c in of("Condition"))
        pa = date(a.year - 1, a.month, a.day)
        adv = any(has(c, "Advanced Illness") and _cond_active_in(c, pa, b) for c in of("Condition")) \
            or any_in(["Encounter", "Observation", "Procedure"], ["Advanced Illness"], pa, b)
        dem = any(has(m, "Dementia Medications") and ok(m) and _overlaps(m, pa, b)
                  for m in of("MedicationRequest", "MedicationStatement", "MedicationDispense",
                              "MedicationAdministration"))
        frail_ex = frail and (adv or dem)

    if hospice or palliative or (age >= 66 and (nursing or frail_ex)):
        out["denominator-exclusion"] = True
        return out

    tests = valuesets.get("HbA1c Laboratory Test", set()) | {("http://loinc.org", "97506-0")}
    by_day = {}
    for o in of("Observation"):
        if not any(c in tests for c in _all_codes(o)):
            continue
        if o.get("status") not in ("final", "amended", "corrected", None):
            continue
        s, e = _span(o)
        day = e or s
        if day is None or not (a <= day <= b):
            continue
        q = o.get("valueQuantity")
        if not isinstance(q, dict) or q.get("value") is None:
            continue
        u = q.get("unit") or q.get("code")
        if u not in (None, "%", "percent"):
            continue
        by_day.setdefault(day, []).append(float(q["value"]))
    if not by_day:
        out["numerator"] = True
        return out
    out["numerator"] = min(by_day[max(by_day)]) > 9.0
    return out
