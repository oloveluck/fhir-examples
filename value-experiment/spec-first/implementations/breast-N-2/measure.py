from datetime import date

CC = "http://terminology.hl7.org/CodeSystem/condition-clinical"


def _d(s):
    if not s:
        return None
    try:
        return date.fromisoformat(str(s)[:10])
    except ValueError:
        return None


def _codes(cc):
    out = set()
    if isinstance(cc, list):
        for x in cc:
            out |= _codes(x)
    elif isinstance(cc, dict):
        for c in cc.get("coding", []) or []:
            if c.get("code"):
                out.add((c.get("system"), c.get("code")))
    return out


def _span(r):
    for k in ("performedPeriod", "period", "effectivePeriod", "occurrencePeriod"):
        p = r.get(k)
        if isinstance(p, dict):
            return _d(p.get("start")), _d(p.get("end"))
    if r.get("resourceType") == "Condition":
        s = e = None
        if r.get("onsetDateTime"):
            s = _d(r["onsetDateTime"])
        elif isinstance(r.get("onsetPeriod"), dict):
            s = _d(r["onsetPeriod"].get("start"))
            e = _d(r["onsetPeriod"].get("end"))
        if r.get("abatementDateTime"):
            e = _d(r["abatementDateTime"])
        elif isinstance(r.get("abatementPeriod"), dict):
            e = _d(r["abatementPeriod"].get("end"))
        if s is None and e is None and r.get("recordedDate"):
            s = _d(r["recordedDate"])
        return s, e
    for k in ("performedDateTime", "effectiveDateTime", "authoredOn", "issued",
              "occurrenceDateTime", "date", "recordedDate"):
        if r.get(k):
            d = _d(r[k])
            return d, d
    return None, None


def _overlaps(r, a, b):
    s, e = _span(r)
    if s is None and e is None:
        return False
    return (s or date.min) <= b and (e or date.max) >= a


def _active(r):
    cs = r.get("clinicalStatus")
    if cs:
        return not (_codes(cs) & {(CC, x) for x in ("inactive", "resolved", "remission")})
    return True


def evaluate(resources, valuesets, period_start, period_end):
    ps, pe = _d(period_start), _d(period_end)
    V = lambda n: valuesets.get(n, set())
    out = {"initial-population": False, "denominator": False,
           "denominator-exclusion": False, "numerator": False}
    res = [r for r in resources if isinstance(r, dict)]
    pat = next((r for r in res if r.get("resourceType") == "Patient"), None)
    if not pat:
        return out
    bd = _d(pat.get("birthDate"))
    if not bd or str(pat.get("gender", "")).lower() != "female":
        return out
    age = pe.year - bd.year - ((pe.month, pe.day) < (bd.month, bd.day))
    if not (52 <= age <= 74):
        return out

    def rc(r):
        c = set()
        for k in ("code", "type", "serviceType", "medicationCodeableConcept", "category"):
            if k in r:
                c |= _codes(r[k])
        return c

    def match(r, *names):
        allc = set()
        for n in names:
            allc |= V(n)
        return bool(rc(r) & allc)

    def done(r):
        t = r.get("resourceType")
        st = r.get("status")
        if t == "Procedure":
            return st in (None, "completed", "in-progress")
        if t == "Observation":
            return st in (None, "final", "amended", "corrected", "preliminary")
        if t == "DiagnosticReport":
            return st in (None, "final", "amended", "corrected", "preliminary", "appended")
        if t == "ServiceRequest":
            return st in (None, "active", "completed", "on-hold")
        if t in ("MedicationRequest", "MedicationStatement", "MedicationDispense"):
            return st not in ("cancelled", "stopped", "draft", "not-taken")
        return True

    res = [r for r in res if r.get("status") != "entered-in-error"]

    visit_sets = ["Office Visit", "Annual Wellness Visit",
                  "Preventive Care Services Established Office Visit, 18 and Up",
                  "Preventive Care Services Initial Office Visit, 18 and Up", "Telephone Visits",
                  "Virtual Encounter", "Home Healthcare Services"]
    visit = any(r.get("resourceType") == "Encounter" and r.get("status") == "finished"
                and match(r, *visit_sets) and _overlaps(r, ps, pe) for r in res)
    if not visit:
        return out
    out["initial-population"] = out["denominator"] = True

    py = date(ps.year - 1, 1, 1)

    def any_(types, names, a, b, active=False):
        for r in res:
            if r.get("resourceType") in types and match(r, *names) and done(r) and _overlaps(r, a, b):
                if active and not _active(r):
                    continue
                return True
        return False

    excl = False
    # hospice
    if any_({"Encounter"}, ["Hospice Encounter"], ps, pe):
        excl = True
    if any_({"Procedure", "ServiceRequest", "Observation", "Encounter"}, ["Hospice Care Ambulatory"], ps, pe):
        excl = True
    if any_({"Condition"}, ["Hospice Diagnosis"], ps, pe, active=True):
        excl = True
    hosp_dis = {("http://snomed.info/sct", "428371000124100"), ("http://snomed.info/sct", "428361000124107")}
    for r in res:
        if r.get("resourceType") == "Encounter" and _overlaps(r, ps, pe):
            if _codes((r.get("hospitalization") or {}).get("dischargeDisposition")) & hosp_dis:
                excl = True
        if (r.get("resourceType") == "Observation" and ("http://loinc.org", "45755-6") in rc(r)
                and _overlaps(r, ps, pe)
                and ("http://snomed.info/sct", "373066001") in _codes(r.get("valueCodeableConcept"))):
            excl = True

    # palliative
    if any_({"Condition"}, ["Palliative Care Diagnosis"], ps, pe, active=True):
        excl = True
    if any_({"Encounter"}, ["Palliative Care Encounter"], ps, pe):
        excl = True
    if any_({"Procedure", "ServiceRequest", "Observation"}, ["Palliative Care Intervention"], ps, pe):
        excl = True
    for r in res:
        if (r.get("resourceType") == "Observation" and ("http://loinc.org", "71007-9") in rc(r)
                and _overlaps(r, ps, pe)):
            excl = True

    # mastectomy
    L = {("http://snomed.info/sct", "7771000")}
    R = {("http://snomed.info/sct", "24028007")}
    left = right = False
    for r in res:
        t = r.get("resourceType")
        if t not in ("Procedure", "Condition", "Observation", "DiagnosticReport"):
            continue
        s, e = _span(r)
        if s is not None and s > pe:
            continue
        if not done(r):
            continue
        if match(r, "Bilateral Mastectomy", "History of bilateral mastectomy"):
            excl = True
        sides = set()
        bs = r.get("bodySite")
        if isinstance(bs, list):
            for b in bs:
                sides |= _codes(b)
        elif isinstance(bs, dict):
            sides |= _codes(bs)
        if match(r, "Unilateral Mastectomy Left", "Status Post Left Mastectomy"):
            left = True
        if match(r, "Unilateral Mastectomy Right", "Status Post Right Mastectomy"):
            right = True
        if match(r, "Unilateral Mastectomy, Unspecified Laterality"):
            if sides & L:
                left = True
            if sides & R:
                right = True
    if left and right:
        excl = True

    if age >= 66:
        frail = (any_({"Device", "DeviceRequest", "DeviceUseStatement"}, ["Frailty Device"], ps, pe)
                 or any_({"Condition"}, ["Frailty Diagnosis", "Frailty Symptom"], ps, pe, active=True)
                 or any_({"Encounter", "Procedure", "ServiceRequest"}, ["Frailty Encounter"], ps, pe)
                 or any_({"Observation", "Procedure"}, ["Frailty Symptom", "Frailty Diagnosis"], ps, pe))
        if not frail:
            for r in res:
                if r.get("resourceType") in ("DeviceRequest", "DeviceUseStatement"):
                    if _codes(r.get("codeCodeableConcept")) & V("Frailty Device") and _overlaps(r, ps, pe):
                        frail = True
        if frail:
            adv = any_({"Condition", "Encounter", "Observation", "Procedure"},
                       ["Advanced Illness"], py, pe, active=True)
            if not adv:
                for r in res:
                    if r.get("resourceType") in ("MedicationRequest", "MedicationStatement", "MedicationDispense"):
                        if (_codes(r.get("medicationCodeableConcept")) & V("Dementia Medications")
                                and done(r) and _overlaps(r, py, pe)):
                            adv = True
            if adv:
                excl = True
        nh = ("http://snomed.info/sct", "160734000")
        for r in res:
            if r.get("resourceType") in ("Observation", "Condition", "Procedure") and nh in rc(r):
                s, e = _span(r)
                if (s is None or s <= pe) and _active(r):
                    excl = True

    out["denominator-exclusion"] = excl

    a = date(ps.year - 2, 10, 1)
    num = False
    for r in res:
        if (r.get("resourceType") in ("Procedure", "DiagnosticReport", "Observation")
                and match(r, "Mammography") and done(r)):
            s, e = _span(r)
            d = e or s
            if d and a <= d <= pe:
                num = True
    out["numerator"] = num and not excl
    return out
