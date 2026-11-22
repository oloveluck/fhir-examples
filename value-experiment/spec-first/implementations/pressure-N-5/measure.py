from datetime import date, timedelta

SNOMED = "http://snomed.info/sct"
LOINC = "http://loinc.org"


def _d(s):
    if not s:
        return None
    try:
        return date(int(s[0:4]), int(s[5:7]) if len(s) >= 7 else 1, int(s[8:10]) if len(s) >= 10 else 1)
    except Exception:
        return None


def _codes(cc):
    out = set()
    if not cc:
        return out
    if isinstance(cc, list):
        for x in cc:
            out |= _codes(x)
        return out
    for c in cc.get("coding", []) or []:
        out.add((c.get("system"), c.get("code")))
    return out


def _inv(codes, *sets):
    for s in sets:
        if codes & set(s):
            return True
    return False


def _interval(r):
    t = r.get("resourceType")
    s = e = None
    if t == "Condition":
        if r.get("onsetDateTime"):
            s = _d(r["onsetDateTime"])
        elif r.get("onsetPeriod"):
            s = _d(r["onsetPeriod"].get("start"))
            e = _d(r["onsetPeriod"].get("end"))
        if r.get("abatementDateTime"):
            e = _d(r["abatementDateTime"])
        elif r.get("abatementPeriod"):
            e = _d(r["abatementPeriod"].get("end")) or _d(r["abatementPeriod"].get("start"))
        if s is None:
            s = _d(r.get("recordedDate"))
        return s, e
    if t == "Encounter":
        p = r.get("period") or {}
        return _d(p.get("start")), _d(p.get("end"))
    if t == "Procedure":
        if r.get("performedDateTime"):
            s = e = _d(r["performedDateTime"])
        elif r.get("performedPeriod"):
            s = _d(r["performedPeriod"].get("start"))
            e = _d(r["performedPeriod"].get("end"))
        return s, e
    if t == "Observation":
        if r.get("effectiveDateTime"):
            s = e = _d(r["effectiveDateTime"])
        elif r.get("effectiveInstant"):
            s = e = _d(r["effectiveInstant"])
        elif r.get("effectivePeriod"):
            s = _d(r["effectivePeriod"].get("start"))
            e = _d(r["effectivePeriod"].get("end"))
        if s is None and e is None:
            s = e = _d(r.get("issued"))
        return s, e
    if t in ("ServiceRequest", "DeviceRequest"):
        s = e = _d(r.get("authoredOn"))
        if t == "ServiceRequest" and r.get("occurrencePeriod"):
            s = _d(r["occurrencePeriod"].get("start")) or s
            e = _d(r["occurrencePeriod"].get("end")) or e
        return s, e
    if t == "MedicationRequest":
        s = _d(r.get("authoredOn"))
        e = s
        dr = r.get("dispenseRequest") or {}
        dur = (dr.get("expectedSupplyDuration") or {}).get("value")
        vp = dr.get("validityPeriod")
        if vp:
            s = _d(vp.get("start")) or s
            e = _d(vp.get("end")) or e
        elif s and dur:
            e = s + timedelta(days=int(dur))
        return s, e
    return None, None


def _overlaps(r, a, b):
    s, e = _interval(r)
    if s is None and e is None:
        return False
    if s is None:
        s = e
    if s > b:
        return False
    if e is not None and e < a:
        return False
    return True


def _during(r, a, b):
    s, e = _interval(r)
    if s is None:
        return False
    e = e or s
    return s >= a and e <= b


def _start_by(r, b):
    s = _interval(r)[0]
    return s is not None and s <= b


def evaluate(resources, valuesets, period_start, period_end):
    ps, pe = _d(period_start), _d(period_end)

    def V(n):
        return valuesets.get(n, set())

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

    by = {}
    for r in resources:
        by.setdefault(r.get("resourceType"), []).append(r)
    conds = [r for r in by.get("Condition", []) if not any(
        c in ("refuted", "entered-in-error") for _, c in _codes(r.get("verificationStatus")))]
    encs = [r for r in by.get("Encounter", []) if r.get("status") not in ("cancelled", "entered-in-error", "planned")]
    procs = [r for r in by.get("Procedure", []) if r.get("status") not in ("entered-in-error", "not-done", "preparation", "stopped")]
    obss = [r for r in by.get("Observation", []) if r.get("status") not in ("entered-in-error", "cancelled")]
    reqs = by.get("ServiceRequest", [])

    # initial population
    visit_sets = [V(n) for n in ("Office Visit", "Annual Wellness Visit",
                                 "Preventive Care Services Established Office Visit, 18 and Up",
                                 "Preventive Care Services Initial Office Visit, 18 and Up",
                                 "Home Healthcare Services", "Telephone Visits", "Virtual Encounter")]
    visit = any(e.get("status") == "finished" and _inv(_codes(e.get("type")), *visit_sets)
                and _during(e, ps, pe) for e in encs)
    first_half_end = ps + timedelta(days=181)  # Jul 1 start of 2nd half exclusive -> Jun 30
    first_half_end = date(ps.year, ps.month, ps.day)
    m = ps.month + 6
    y = ps.year + (m - 1) // 12
    m = (m - 1) % 12 + 1
    first_half_end = date(y, m, 1) - timedelta(days=1)
    htn = False
    for c in conds:
        if _inv(_codes(c.get("code")), V("Essential Hypertension")):
            s, e = _interval(c)
            if s is not None and s <= first_half_end and (e is None or e >= ps):
                htn = True
    if not (visit and htn):
        return res
    res["initial-population"] = res["denominator"] = True

    def any_overlap(items, vs, a, b, field=None, extra=None):
        for r in items:
            if field:
                codes = _codes(r.get(field))
            else:
                codes = _codes(r.get("code")) | _codes(r.get("type"))
            if _inv(codes, *vs) and _overlaps(r, a, b) and (extra is None or extra(r)):
                return True
        return False

    def active_req(r):
        return r.get("status") in ("active", "completed", "on-hold") and not r.get("doNotPerform")

    hospice_obs = any(_inv(_codes(o.get("code")), [(LOINC, "45755-6")]) and
                      _inv(_codes(o.get("valueCodeableConcept")), [(SNOMED, "373066001")]) and _overlaps(o, ps, pe)
                      for o in obss)
    hospice_disp = False
    for e in encs:
        if _inv(_codes((e.get("hospitalization") or {}).get("dischargeDisposition")),
                [(SNOMED, "428371000124100"), (SNOMED, "428361000124107")]):
            end = _interval(e)[1]
            if end is not None and ps <= end <= pe:
                hospice_disp = True
    hospice = (
        any_overlap(encs, [V("Hospice Encounter")], ps, pe)
        or any_overlap(procs, [V("Hospice Care Ambulatory")], ps, pe)
        or any_overlap(reqs, [V("Hospice Care Ambulatory")], ps, pe, extra=active_req)
        or any_overlap(conds, [V("Hospice Diagnosis")], ps, pe)
        or hospice_obs or hospice_disp
    )
    esrd = (
        any(_inv(_codes(c.get("code")), V("End Stage Renal Disease"), V("Chronic Kidney Disease, Stage 5"),
                 V("Kidney Transplant Recipient")) and _start_by(c, pe) for c in conds)
        or any(_inv(_codes(p.get("code")), V("Dialysis Services"), V("Kidney Transplant"))
               and _start_by(p, pe) for p in procs)
        or any(_inv(_codes(e.get("type")), V("ESRD Monthly Outpatient Services"))
               and _start_by(e, pe) for e in encs)
    )
    pregnant = any_overlap(conds, [V("Pregnancy")], ps, pe)
    palliative = (
        any_overlap(conds, [V("Palliative Care Diagnosis")], ps, pe)
        or any_overlap(encs, [V("Palliative Care Encounter")], ps, pe)
        or any_overlap(procs, [V("Palliative Care Intervention")], ps, pe)
        or any_overlap(reqs, [V("Palliative Care Intervention")], ps, pe, extra=active_req)
        or any(_inv(_codes(o.get("code")), [(LOINC, "71007-9")]) and _overlaps(o, ps, pe) for o in obss)
    )

    def dev_ok(r):
        if r.get("status") in ("entered-in-error", "cancelled", "draft") or r.get("doNotPerform"):
            return False
        return not any(x.get("valueBoolean") for x in r.get("modifierExtension", []) or [])

    frail = (
        any(_inv(_codes(r.get("codeCodeableConcept")) | _codes(r.get("code")), V("Frailty Device"))
            and _overlaps(r, ps, pe) and dev_ok(r) for r in by.get("DeviceRequest", []))
        or any(_inv(_codes(o.get("code")) | _codes(o.get("valueCodeableConcept")), V("Frailty Device"))
               and _overlaps(o, ps, pe) for o in obss)
        or any_overlap(conds, [V("Frailty Diagnosis")], ps, pe)
        or any_overlap(encs, [V("Frailty Encounter")], ps, pe)
        or any(_inv(_codes(o.get("code")), V("Frailty Symptom")) and _overlaps(o, ps, pe) for o in obss)
        or any(_inv(_codes(p.get("code")), V("Frailty Encounter"), V("Frailty Device")) and _overlaps(p, ps, pe)
               for p in procs)
    )
    back = date(ps.year - 1, ps.month, ps.day)
    adv = any_overlap(conds, [V("Advanced Illness")], back, pe) or any_overlap(
        encs, [V("Advanced Illness")], back, pe, field="reasonCode")
    dem = any(_inv(_codes(mr.get("medicationCodeableConcept")), V("Dementia Medications"))
              and mr.get("status") not in ("entered-in-error", "cancelled", "draft") and not mr.get("doNotPerform")
              and _overlaps(mr, back, pe) for mr in by.get("MedicationRequest", []))
    nh = [(SNOMED, "160734000")]
    nursing = age >= 66 and (
        any(_inv(_codes(o.get("valueCodeableConcept")), nh) and _start_by(o, pe) for o in obss)
        or any(_inv(_codes(c.get("code")), nh) and _start_by(c, pe) for c in conds))

    excl = hospice or esrd or pregnant or palliative or nursing
    if 66 <= age <= 80 and frail and (adv or dem):
        excl = True
    if age >= 81 and frail:
        excl = True
    res["denominator-exclusion"] = bool(excl)
    if excl:
        return res

    # numerator
    enc_by_id = {"Encounter/" + str(e.get("id")): e for e in by.get("Encounter", [])}

    def acute(o):
        e = enc_by_id.get((o.get("encounter") or {}).get("reference"))
        if not e:
            return False
        if (e.get("class") or {}).get("code") in ("IMP", "ACUTE", "NONAC", "EMER"):
            return True
        return _inv(_codes(e.get("type")), V("Encounter Inpatient"),
                    V("Emergency Department Evaluation and Management Visit"))

    SYS, DIA = (LOINC, "8480-6"), (LOINC, "8462-4")
    days = {}
    for o in obss:
        if o.get("status") not in ("final", "amended", "corrected"):
            continue
        s, e = _interval(o)
        day = e or s
        if day is None or not (ps <= day <= pe) or acute(o):
            continue
        sv = dv = None
        for it in [o] + list(o.get("component", []) or []):
            cs = _codes(it.get("code"))
            q = it.get("valueQuantity")
            if q is None or q.get("value") is None:
                continue
            if SYS in cs:
                sv = q["value"]
            elif DIA in cs:
                dv = q["value"]
        rec = days.setdefault(day, [[], []])
        if sv is not None:
            rec[0].append(sv)
        if dv is not None:
            rec[1].append(dv)
    ok_days = [d for d, (s, dd) in days.items() if s and dd]
    if ok_days:
        d = max(ok_days)
        res["numerator"] = min(days[d][0]) < 140 and min(days[d][1]) < 90
    return res
