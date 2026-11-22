BAD = {"entered-in-error", "cancelled", "not-done", "draft", "revoked", "refuted", "unknown", "stopped", "on-hold"}
BAD_COND = {"entered-in-error", "refuted"}
SCT = "http://snomed.info/sct"


def _d(s):
    return s[:10] if isinstance(s, str) and len(s) >= 10 else None


def _codes(cc):
    out = set()
    if isinstance(cc, dict):
        for c in cc.get("coding", []) or []:
            out.add((c.get("system"), c.get("code")))
    elif isinstance(cc, list):
        for x in cc:
            out |= _codes(x)
    return out


def _interval(r):
    t = r["resourceType"]
    s = e = None
    for k, v in r.items():
        if k.startswith(("performed", "effective", "occurrence")):
            if isinstance(v, dict):
                s, e = _d(v.get("start")), _d(v.get("end"))
            else:
                s = e = _d(v)
            if s or e:
                break
    if not (s or e):
        if t == "Condition":
            s = _d(r.get("onsetDateTime") or (r.get("onsetPeriod") or {}).get("start"))
            e = _d(r.get("abatementDateTime") or (r.get("abatementPeriod") or {}).get("end"))
            if not s:
                s = _d(r.get("recordedDate"))
        elif isinstance(r.get("period"), dict):
            s, e = _d(r["period"].get("start")), _d(r["period"].get("end"))
        elif r.get("authoredOn"):
            s = e = _d(r["authoredOn"])
        elif r.get("issued"):
            s = e = _d(r["issued"])
        elif r.get("dispenseRequest", {}).get("validityPeriod"):
            p = r["dispenseRequest"]["validityPeriod"]
            s, e = _d(p.get("start")), _d(p.get("end"))
    return s, e


def evaluate(resources, valuesets, period_start, period_end):
    ps, pe = period_start[:10], period_end[:10]
    vs = lambda n: valuesets.get(n, set())
    patient = next((r for r in resources if r.get("resourceType") == "Patient"), {})
    meds = {r.get("id"): r for r in resources if r.get("resourceType") == "Medication"}
    res = {"initial-population": False, "denominator": False,
           "denominator-exclusion": False, "numerator": False}

    bd = _d(patient.get("birthDate"))
    if not bd or str(patient.get("gender", "")).lower() != "female":
        return res
    age = int(pe[:4]) - int(bd[:4]) - (1 if pe[5:10] < bd[5:10] else 0)
    if not (52 <= age <= 74):
        return res

    def codes_of(r):
        c = set()
        for k in ("code", "type", "serviceType", "medicationCodeableConcept", "category"):
            if k in r:
                c |= _codes(r[k])
        if "medicationReference" in r:
            m = meds.get((r["medicationReference"].get("reference") or "").split("/")[-1])
            if m:
                c |= _codes(m.get("code"))
        return c

    def find(names, lo=None, hi=None, types=None):
        target = set()
        for n in names:
            target |= vs(n)
        out = []
        for r in resources:
            t = r.get("resourceType")
            if t in ("Patient", "Medication") or (types and t not in types):
                continue
            if r.get("status") in BAD:
                continue
            if t == "Condition" and any(c[1] in BAD_COND for c in _codes(r.get("verificationStatus"))):
                continue
            if not (codes_of(r) & target):
                continue
            s, e = _interval(r)
            if lo or hi:
                if not (s or e):
                    continue
                s2, e2 = s or e, e or s
                if t == "Condition":
                    e2 = e or "9999-12-31"
                if (hi and s2 > hi) or (lo and e2 < lo):
                    continue
            out.append(r)
        return out

    visits = ["Office Visit", "Annual Wellness Visit",
              "Preventive Care Services Established Office Visit, 18 and Up",
              "Preventive Care Services Initial Office Visit, 18 and Up", "Home Healthcare Services",
              "Telephone Visits", "Virtual Encounter"]
    ok = False
    for r in find(visits, ps, pe, {"Encounter"}):
        if r.get("status") in ("finished", "in-progress", None):
            s, e = _interval(r)
            if (s or e) and (s or e) >= ps and (e or s) <= pe:
                ok = True
    if not ok:
        return res
    res["initial-population"] = res["denominator"] = True

    def in_period(r):
        s, e = _interval(r)
        return bool(s or e) and (s or e) <= pe and (e or s) >= ps

    def hospice():
        if find(["Hospice Encounter"], ps, pe, {"Encounter"}):
            return True
        if find(["Hospice Care Ambulatory"], ps, pe,
                {"ServiceRequest", "Procedure", "Observation", "DeviceRequest"}):
            return True
        if find(["Hospice Diagnosis"], ps, pe, {"Condition"}):
            return True
        dis = {(SCT, "428371000124100"), (SCT, "428361000124107")}
        for r in resources:
            if r.get("resourceType") == "Encounter" and r.get("status") not in BAD:
                if _codes(r.get("hospitalization", {}).get("dischargeDisposition")) & dis:
                    s, e = _interval(r)
                    if (e or s) and ps <= (e or s) <= pe:
                        return True
            if r.get("resourceType") == "Observation" and ("http://loinc.org", "45755-6") in _codes(r.get("code")):
                if (SCT, "373066001") in _codes(r.get("valueCodeableConcept")) and in_period(r):
                    return True
        return False

    def mastectomy():
        if find(["Bilateral Mastectomy", "History of bilateral mastectomy"], None, pe):
            return True
        left = bool(find(["Status Post Left Mastectomy", "Unilateral Mastectomy Left"], None, pe))
        right = bool(find(["Status Post Right Mastectomy", "Unilateral Mastectomy Right"], None, pe))
        for r in find(["Unilateral Mastectomy, Unspecified Laterality"], None, pe):
            bs = set()
            for b in r.get("bodySite", []) or []:
                bs |= _codes(b)
            if (SCT, "7771000") in bs:
                left = True
            if (SCT, "24028007") in bs:
                right = True
        return left and right

    def frail():
        if age < 66:
            return False
        if not find(["Frailty Device", "Frailty Diagnosis", "Frailty Encounter", "Frailty Symptom"], ps, pe):
            return False
        ly = str(int(ps[:4]) - 1) + ps[4:]
        if find(["Advanced Illness"], ly, pe, {"Condition", "Encounter"}):
            return True
        return bool(find(["Dementia Medications"], ly, pe,
                         {"MedicationRequest", "MedicationStatement", "MedicationDispense",
                          "MedicationAdministration"}))

    def nursing():
        if age < 66:
            return False
        for r in resources:
            if r.get("resourceType") in ("Observation", "Condition", "Procedure", "ServiceRequest"):
                if (SCT, "160734000") in _codes(r.get("code")) and r.get("status") not in BAD:
                    s, e = _interval(r)
                    if not (s or e) or (s or e) <= pe:
                        return True
        return False

    def palliative():
        if find(["Palliative Care Diagnosis"], ps, pe, {"Condition"}):
            return True
        if find(["Palliative Care Encounter"], ps, pe, {"Encounter"}):
            return True
        if find(["Palliative Care Intervention"], ps, pe, {"Procedure", "ServiceRequest"}):
            return True
        for r in resources:
            if r.get("resourceType") == "Observation" and ("http://loinc.org", "71007-9") in _codes(r.get("code")) \
                    and r.get("status") not in BAD and in_period(r):
                return True
        return False

    if hospice() or mastectomy() or frail() or nursing() or palliative():
        res["denominator-exclusion"] = True

    lo = str(int(ps[:4]) - 2) + "-10-01"
    for r in find(["Mammography"], lo, pe, {"Procedure", "Observation", "DiagnosticReport"}):
        s, e = _interval(r)
        if (e or s) and lo <= (e or s) <= pe:
            res["numerator"] = True
    if res["denominator-exclusion"]:
        res["numerator"] = False
    return res
