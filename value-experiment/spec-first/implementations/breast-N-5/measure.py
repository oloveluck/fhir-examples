from datetime import date

FAR = date(1, 1, 1)
FOREVER = date(9999, 1, 1)


def _d(s):
    if not s or not isinstance(s, str):
        return None
    try:
        return date(int(s[0:4]), int(s[5:7]) if len(s) >= 7 else 1, int(s[8:10]) if len(s) >= 10 else 1)
    except Exception:
        return None


def _codes(x):
    out = set()
    if isinstance(x, dict):
        if isinstance(x.get("code"), str) and "system" in x:
            out.add((x["system"], x["code"]))
        for v in x.values():
            if isinstance(v, (dict, list)):
                out |= _codes(v)
    elif isinstance(x, list):
        for i in x:
            out |= _codes(i)
    return out


def _own_codes(r):
    out = set()
    for k in ("code", "type", "serviceType", "medicationCodeableConcept", "valueCodeableConcept",
              "category", "reasonCode", "vaccineCode"):
        if k in r:
            out |= _codes(r[k])
    if r.get("resourceType") == "Encounter":
        out |= _codes(r.get("diagnosis", []))
    return out


def _interval(r):
    rt = r.get("resourceType")
    s = e = None
    for k in ("performedPeriod", "effectivePeriod", "period", "onsetPeriod", "occurrencePeriod"):
        if isinstance(r.get(k), dict):
            s, e = _d(r[k].get("start")), _d(r[k].get("end"))
            break
    if s is None and e is None:
        for k in ("performedDateTime", "effectiveDateTime", "onsetDateTime", "occurrenceDateTime",
                  "authoredOn", "issued", "recordedDate", "date"):
            if r.get(k):
                s = e = _d(r[k])
                break
    if rt == "Condition":
        if s is not None:
            ab = _d(r.get("abatementDateTime"))
            if ab is None and isinstance(r.get("abatementPeriod"), dict):
                ab = _d(r["abatementPeriod"].get("start"))
            e = ab if ab else FOREVER
    if rt == "MedicationRequest" and r.get("authoredOn"):
        s = _d(r["authoredOn"])
        e = _d(r.get("dispenseRequest", {}).get("validityPeriod", {}).get("end")) or s
    if s is None and e is not None:
        s = e
    if e is None and s is not None:
        e = s
    return s, e


def evaluate(resources, valuesets, period_start, period_end):
    ps, pe = _d(period_start), _d(period_end)
    res = {"initial-population": False, "denominator": False,
           "denominator-exclusion": False, "numerator": False}
    pat = next((r for r in resources if r.get("resourceType") == "Patient"), None)
    if not pat:
        return res
    bd = _d(pat.get("birthDate"))
    if not bd or (pat.get("gender") or "").lower() != "female":
        return res
    age = pe.year - bd.year - ((pe.month, pe.day) < (bd.month, bd.day))
    if not (52 <= age <= 74):
        return res

    def vs(names):
        if isinstance(names, set):
            return names
        s = set()
        for n in names:
            s |= valuesets.get(n, set())
        return s

    items = []
    for r in resources:
        if r.get("resourceType") == "Patient":
            continue
        s, e = _interval(r)
        items.append((r, _own_codes(r), s, e))

    BAD = ("entered-in-error", "cancelled", "not-done", "refuted")

    def find(names, within=None, overlap=None, types=None, bad=BAD):
        v = vs(names)
        for r, c, s, e in items:
            if types and r["resourceType"] not in types:
                continue
            if r.get("status") in bad or not (c & v):
                continue
            if overlap is not None:
                if s is None or not (s <= overlap[1] and e >= overlap[0]):
                    continue
            if within is not None:
                if s is None or not (within[0] <= s <= within[1] or within[0] <= e <= within[1]):
                    continue
            yield r, s, e

    def any_(names, **kw):
        return next(iter(find(names, **kw)), None) is not None

    visit_vs = ("Office Visit", "Annual Wellness Visit",
                "Preventive Care Services Established Office Visit, 18 and Up",
                "Preventive Care Services Initial Office Visit, 18 and Up", "Home Healthcare Services",
                "Telephone Visits", "Virtual Encounter")
    per = (ps, pe)
    if not any_(visit_vs, types=("Encounter",), overlap=per, bad=BAD + ("planned",)):
        return res
    res["initial-population"] = res["denominator"] = True

    excl = False
    hospice_extra = {("http://snomed.info/sct", "428371000124100"), ("http://snomed.info/sct", "428361000124107"),
                     ("http://loinc.org", "45755-6")}
    if any_(("Hospice Encounter", "Hospice Care Ambulatory", "Hospice Diagnosis"), overlap=per) or \
            any_(hospice_extra, overlap=per):
        excl = True
    if any_(("Palliative Care Diagnosis", "Palliative Care Encounter", "Palliative Care Intervention"),
            overlap=per) or any_({("http://loinc.org", "71007-9")}, overlap=per):
        excl = True

    far = (FAR, pe)
    if any_(("Bilateral Mastectomy", "History of bilateral mastectomy"), overlap=far):
        excl = True
    left = any_(("Unilateral Mastectomy Left", "Status Post Left Mastectomy"), overlap=far)
    right = any_(("Unilateral Mastectomy Right", "Status Post Right Mastectomy"), overlap=far)
    for r, s, e in find(("Unilateral Mastectomy, Unspecified Laterality",), overlap=far):
        bs = _codes(r.get("bodySite", []))
        left = left or ("http://snomed.info/sct", "7771000") in bs
        right = right or ("http://snomed.info/sct", "24028007") in bs
    if left and right:
        excl = True

    if age >= 66:
        if any_(("Frailty Device", "Frailty Diagnosis", "Frailty Encounter", "Frailty Symptom"), overlap=per):
            prior = (date(ps.year - 1, 1, 1), pe)
            if any_(("Advanced Illness",), overlap=prior) or any_(("Dementia Medications",), overlap=prior):
                excl = True
        if any_({("http://snomed.info/sct", "160734000")}, overlap=far):
            excl = True
    res["denominator-exclusion"] = excl
    if excl:
        return res
    win = (date(ps.year - 2, 10, 1), pe)
    res["numerator"] = any_(("Mammography",), within=win,
                            bad=BAD + ("registered", "preliminary"))
    return res
