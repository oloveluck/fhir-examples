import re
from datetime import datetime, timedelta


def pdt(s, high=False):
    """Parse FHIR date/dateTime to naive UTC datetime; partial precision -> start (or end if high)."""
    if s is None:
        return None
    m = re.match(r'^(\d{4})(?:-(\d\d))?(?:-(\d\d))?(?:T(\d\d):(\d\d)(?::(\d\d)(?:\.(\d+))?)?)?(Z|[+-]\d\d:\d\d)?$', s)
    if not m:
        return None
    y, mo, d, hh, mi, ss, fr, tz = m.groups()
    y = int(y)
    if mo is None:
        return datetime(y, 12, 31, 23, 59, 59, 999000) if high else datetime(y, 1, 1)
    mo = int(mo)
    if d is None:
        if high:
            return datetime(y + (mo == 12), mo % 12 + 1, 1) - timedelta(milliseconds=1)
        return datetime(y, mo, 1)
    d = int(d)
    if hh is None:
        base = datetime(y, mo, d)
        return base + timedelta(days=1) - timedelta(milliseconds=1) if high else base
    base = datetime(y, mo, d, int(hh), int(mi), int(ss or 0))
    if fr:
        base = base.replace(microsecond=int((fr + '000000')[:6]))
    elif high and ss is None:
        base = base.replace(second=59, microsecond=999000)
    if tz and tz != 'Z':
        sign = 1 if tz[0] == '+' else -1
        base = base - sign * timedelta(hours=int(tz[1:3]), minutes=int(tz[4:6]))
    return base


def day_start(d):
    return datetime(d.year, d.month, d.day)


def day_end(d):
    return datetime(d.year, d.month, d.day) + timedelta(days=1) - timedelta(milliseconds=1)


def dayiv(iv):
    """expand an interval to whole days ('day of')"""
    if iv is None:
        return None
    lo, hi = iv
    return (day_start(lo) if lo else None, day_end(hi) if hi else None)


def overlaps(a, b):
    if a is None or b is None:
        return False
    alo, ahi = a
    blo, bhi = b
    if alo is not None and bhi is not None and alo > bhi:
        return False
    if blo is not None and ahi is not None and blo > ahi:
        return False
    return True


def during(a, b):
    if a is None or a[0] is None or a[1] is None:
        return False
    return b[0] <= a[0] and a[1] <= b[1]


def period_iv(p):
    if not isinstance(p, dict):
        return None
    lo = pdt(p.get('start'))
    hi = pdt(p.get('end'), True)
    if lo is None and hi is None:
        return None
    return (lo, hi)


def add_years(d, n):
    try:
        return d.replace(year=d.year + n)
    except ValueError:
        return d.replace(year=d.year + n, day=28)


def to_iv(r, prefix, birth=None):
    for k, v in r.items():
        if not k.startswith(prefix) or k == prefix:
            continue
        t = k[len(prefix):]
        if t in ('DateTime', 'Instant', 'Date'):
            return (pdt(v), pdt(v, True))
        if t == 'Period':
            return period_iv(v)
        if t == 'Age' and birth and isinstance(v, dict) and 'value' in v:
            n = int(v['value'])
            return (add_years(birth, n), add_years(birth, n + 1) - timedelta(milliseconds=1))
        if t == 'Range' and birth and isinstance(v, dict):
            l = (v.get('low') or {}).get('value')
            h = (v.get('high') or {}).get('value')
            if l is not None and h is not None:
                return (add_years(birth, int(l)), add_years(birth, int(h) + 1) - timedelta(milliseconds=1))
    return None


def latest(iv):
    if iv is None:
        return None
    return iv[1] if iv[1] is not None else iv[0]


def codes_of(cc):
    out = set()
    if isinstance(cc, dict):
        for c in cc.get('coding', []) or []:
            out.add((c.get('system'), c.get('code')))
    return out


def in_vs(cc, vs):
    return bool(codes_of(cc) & vs)


def in_vs_any(ccs, vs):
    if isinstance(ccs, dict):
        ccs = [ccs]
    return any(in_vs(c, vs) for c in (ccs or []))


def has_code(cc, system, code):
    return (system, code) in codes_of(cc)


ENC_OK = ('finished', 'arrived', 'triaged', 'in-progress', 'onleave')
OBS_CAT = 'http://terminology.hl7.org/CodeSystem/observation-category'


def evaluate(resources, valuesets, period_start, period_end):
    VS = lambda n: valuesets.get(n, set())
    ps = pdt(period_start)
    pe = pdt(period_end, True)
    MP = (ps, pe)
    DAY = dayiv(MP)
    by = {}
    for r in resources:
        by.setdefault(r.get('resourceType'), []).append(r)
    patient = (by.get('Patient') or [{}])[0]
    birth = pdt(patient.get('birthDate'))
    res = {"initial-population": False, "denominator": False,
           "denominator-exclusion": False, "numerator": False}
    if birth is None:
        return res
    age = pe.year - birth.year - ((pe.month, pe.day) < (birth.month, birth.day))

    def of(rt, vsname, path):
        vs = VS(vsname)
        return [r for r in by.get(rt, []) if in_vs_any(r.get(path), vs)]

    def prevalence(c):
        cs = codes_of(c.get('clinicalStatus'))
        active = any(sy == 'http://terminology.hl7.org/CodeSystem/condition-clinical' and
                     code in ('active', 'recurrence', 'relapse') for sy, code in cs)
        on = to_iv(c, 'onset', birth)
        lo = on[0] if on else None
        ab = None
        for k, v in c.items():
            if k.startswith('abatement') and k != 'abatement':
                t = k[len('abatement'):]
                if t == 'DateTime':
                    ab = pdt(v, True)
                elif t == 'Period':
                    ab = pdt(v.get('end'), True) if isinstance(v, dict) else None
                else:
                    iv = to_iv(c, 'abatement', birth)
                    ab = iv[1] if iv else None
        if active:
            return (lo, ab)
        if ab is None:
            return None  # open end with unknown boundary
        return (lo, ab)

    def ok(r, statuses):
        return r.get('status') in statuses

    def enc_list(names):
        out = []
        for n in names:
            out += [e for e in of('Encounter', n, 'type') if ok(e, ENC_OK)]
        return out

    def eff(o):
        return to_iv(o, 'effective', birth)

    def survey(o):
        return any(has_code(c, OBS_CAT, 'survey') for c in o.get('category', []) or [])

    def assessments(code):
        return [o for o in by.get('Observation', [])
                if ok(o, ('final', 'amended', 'corrected')) and survey(o)
                and has_code(o.get('code'), 'http://loinc.org', code)]

    # ---- initial population
    if not (18 <= age <= 85):
        return res
    sixm = (ps, datetime(ps.year + (ps.month + 5) // 12, (ps.month + 5) % 12 + 1, ps.day)
            - timedelta(milliseconds=1))
    htn = any(overlaps(prevalence(c), sixm) for c in of('Condition', 'Essential Hypertension', 'code'))
    qual = any(during(period_iv(e.get('period')), DAY) for e in enc_list([
        "Office Visit", "Annual Wellness Visit",
        "Preventive Care Services Established Office Visit, 18 and Up",
        "Preventive Care Services Initial Office Visit, 18 and Up",
        "Home Healthcare Services", "Virtual Encounter", "Telephone Visits"]))
    if not (htn and qual):
        return res
    res["initial-population"] = True
    res["denominator"] = True

    # ---- exclusions
    def hospice():
        for e in of('Encounter', 'Encounter Inpatient', 'type'):
            if not ok(e, ENC_OK):
                continue
            dd = (e.get('hospitalization') or {}).get('dischargeDisposition')
            if (has_code(dd, 'http://snomed.info/sct', '428361000124107')
                    or has_code(dd, 'http://snomed.info/sct', '428371000124100')):
                iv = period_iv(e.get('period'))
                if iv and iv[1] is not None and DAY[0] <= iv[1] <= DAY[1]:
                    return True
        for e in of('Encounter', 'Hospice Encounter', 'type'):
            if ok(e, ENC_OK) and overlaps(dayiv(period_iv(e.get('period'))), DAY):
                return True
        for o in assessments('45755-6'):
            if has_code(o.get('valueCodeableConcept'), 'http://snomed.info/sct', '373066001') \
                    and overlaps(dayiv(eff(o)), DAY):
                return True
        for s in of('ServiceRequest', 'Hospice Care Ambulatory', 'code'):
            if ok(s, ('active', 'completed')) and s.get('intent') == 'order':
                a = pdt(s.get('authoredOn'))
                if a and DAY[0] <= a <= DAY[1]:
                    return True
        for p in of('Procedure', 'Hospice Care Ambulatory', 'code'):
            if p.get('status') == 'completed' and overlaps(dayiv(to_iv(p, 'performed', birth)), DAY):
                return True
        for c in of('Condition', 'Hospice Diagnosis', 'code'):
            if overlaps(dayiv(prevalence(c)), DAY):
                return True
        return False

    def renal():
        for n in ('Pregnancy', 'End Stage Renal Disease', 'Kidney Transplant Recipient',
                  'Chronic Kidney Disease, Stage 5'):
            for c in of('Condition', n, 'code'):
                if overlaps(prevalence(c), MP):
                    return True
        for n in ('Kidney Transplant', 'Dialysis Services'):
            for p in of('Procedure', n, 'code'):
                if p.get('status') == 'completed':
                    iv = to_iv(p, 'performed', birth)
                    if iv and iv[1] is not None and iv[1] <= pe:
                        return True
        for e in of('Encounter', 'ESRD Monthly Outpatient Services', 'type'):
            if ok(e, ENC_OK):
                iv = period_iv(e.get('period'))
                if iv and iv[0] is not None and iv[0] <= pe:
                    return True
        return False

    def med_period(r):
        di = r.get('dispenseRequest') or {}
        dis = r.get('dosageInstruction') or []
        dosage = dis[0] if len(dis) == 1 else {}
        dr = dosage.get('doseAndRate') or []
        dar = dr[0] if len(dr) == 1 else {}
        rep = (dosage.get('timing') or {}).get('repeat') or {}
        freq = rep.get('frequencyMax', rep.get('frequency'))
        per, pu = rep.get('period'), rep.get('periodUnit')
        daily = None
        if freq is not None and per and pu:
            f = {'h': 24.0, 'hour': 24.0, 'hours': 24.0, 'min': 1440.0, 'minute': 1440.0, 'minutes': 1440.0,
                 'd': 1.0, 'day': 1.0, 'days': 1.0, 'wk': 1 / 7, 'week': 1 / 7, 'weeks': 1 / 7,
                 'mo': 1 / 30, 'month': 1 / 30, 'months': 1 / 30, 'a': 1 / 365, 'year': 1 / 365,
                 'years': 1 / 365}.get(pu)
            if f:
                daily = freq * f / per
        tod = rep.get('timeOfDay')
        dpd = daily if daily is not None else (len(tod) if tod else 1.0)
        dose = None
        if 'doseRange' in dar:
            dose = (dar['doseRange'].get('high') or {}).get('value')
        if dose is None and 'doseQuantity' in dar:
            dose = dar['doseQuantity'].get('value')
        bounds = rep.get('boundsPeriod')
        bstart = pdt(bounds.get('start')) if bounds else None
        bend = pdt(bounds.get('end'), True) if bounds else None
        esd = di.get('expectedSupplyDuration')
        ds = None
        if esd and esd.get('value') is not None:
            f = {'d': 1, 'day': 1, 'days': 1, 'wk': 7, 'mo': 30, 'a': 365}.get(esd.get('code') or esd.get('unit'))
            ds = esd['value'] * f if f else None
        qty = (di.get('quantity') or {}).get('value')
        refills = di.get('numberOfRepeatsAllowed') or 0
        start = bstart or pdt(r.get('authoredOn')) or pdt((di.get('validityPeriod') or {}).get('start'))
        if start is None:
            return None
        start = day_start(start)
        base = ds
        if base is None and qty is not None and dose and dpd:
            base = qty / (dose * dpd)
        if base is not None:
            return (start, day_end(start + timedelta(days=base * (1 + refills) - 1)))
        if bend is not None:
            return (start, day_end(bend))
        return None

    def frailty():
        for d in by.get('DeviceRequest', []):
            if in_vs(d.get('codeCodeableConcept'), VS('Frailty Device')) and ok(d, ('active', 'completed')) \
                    and d.get('intent') == 'order':
                dnp = any(e.get('url') == 'http://hl7.org/fhir/us/qicore/StructureDefinition/qicore-doNotPerform'
                          and e.get('valueBoolean') is True for e in d.get('modifierExtension', []) or [])
                a = pdt(d.get('authoredOn'))
                if not dnp and a and DAY[0] <= a <= DAY[1]:
                    return True
        for o in assessments('98181-1'):
            iv = eff(o)
            if in_vs(o.get('valueCodeableConcept'), VS('Frailty Device')) and iv and iv[1] is not None \
                    and DAY[0] <= iv[1] <= DAY[1]:
                return True
        for c in of('Condition', 'Frailty Diagnosis', 'code'):
            if overlaps(dayiv(prevalence(c)), DAY):
                return True
        for e in of('Encounter', 'Frailty Encounter', 'type'):
            if ok(e, ENC_OK) and overlaps(dayiv(period_iv(e.get('period'))), DAY):
                return True
        for o in of('Observation', 'Frailty Symptom', 'code'):
            if ok(o, ('preliminary', 'final', 'amended', 'corrected')) and overlaps(dayiv(eff(o)), DAY):
                return True
        return False

    def adv_illness():
        win = (day_start(add_years(ps, -1)), day_end(pe))
        for c in of('Condition', 'Advanced Illness', 'code'):
            iv = prevalence(c)
            if iv and iv[0] is not None and win[0] <= iv[0] <= win[1]:
                return True
        return False

    def dementia():
        win = (day_start(add_years(ps, -1)), day_end(pe))
        vs = VS('Dementia Medications')
        for m in by.get('MedicationRequest', []):
            if m.get('status') == 'active' and m.get('intent') == 'order' \
                    and in_vs(m.get('medicationCodeableConcept'), vs):
                if overlaps(med_period(m), win):
                    return True
        return False

    def nursing_home():
        if age < 66:
            return False
        cands = []
        for o in assessments('71802-3'):
            iv = eff(o)
            if iv and iv[1] is not None and iv[1] <= day_end(pe):
                cands.append((iv[1], o))
        if not cands:
            return False
        cands.sort(key=lambda t: t[0])
        return has_code(cands[-1][1].get('valueCodeableConcept'), 'http://snomed.info/sct', '160734000')

    def palliative():
        for o in assessments('71007-9'):
            if overlaps(dayiv(eff(o)), DAY):
                return True
        for c in of('Condition', 'Palliative Care Diagnosis', 'code'):
            if overlaps(dayiv(prevalence(c)), DAY):
                return True
        for e in of('Encounter', 'Palliative Care Encounter', 'type'):
            if ok(e, ENC_OK) and overlaps(dayiv(period_iv(e.get('period'))), DAY):
                return True
        for p in of('Procedure', 'Palliative Care Intervention', 'code'):
            if p.get('status') == 'completed' and overlaps(dayiv(to_iv(p, 'performed', birth)), DAY):
                return True
        return False

    excl = hospice() or renal()
    if not excl and age >= 66 and frailty():
        if age >= 81 or adv_illness() or dementia():
            excl = True
    if not excl:
        excl = nursing_home() or palliative()
    res["denominator-exclusion"] = excl
    if excl:
        return res

    # ---- numerator
    encs = {e.get('id'): e for e in by.get('Encounter', [])}
    readings = []
    for o in by.get('Observation', []):
        if not ok(o, ('final', 'amended', 'corrected')):
            continue
        comps = o.get('component') or []
        isbp = any('observation-bp' in p for p in (o.get('meta') or {}).get('profile', [])) \
            or has_code(o.get('code'), 'http://loinc.org', '85354-9') \
            or any(has_code(c.get('code'), 'http://loinc.org', '8480-6') or
                   has_code(c.get('code'), 'http://loinc.org', '8462-4') for c in comps)
        if not isbp:
            continue
        ref = (o.get('encounter') or {}).get('reference')
        if ref:
            e = encs.get(ref.split('/')[-1])
            if e and (e.get('class') or {}).get('code') in ('EMER', 'IMP', 'ACUTE', 'NONAC', 'PRENC', 'SS'):
                continue
        t = latest(eff(o))
        if t is None or not (DAY[0] <= t <= DAY[1]):
            continue
        readings.append((t.date(), o))
    if not readings:
        return res
    last = max(d for d, _ in readings)

    def val(o, code):
        m = [c for c in o.get('component') or [] if has_code(c.get('code'), 'http://loinc.org', code)]
        if len(m) != 1:
            return None
        q = m[0].get('valueQuantity')
        if not q or q.get('value') is None:
            return None
        if (q.get('code') or q.get('unit')) != 'mm[Hg]':
            return None
        return q['value']

    def lowest(code):
        vals = [val(o, code) for d, o in readings if d == last]
        if any(v is None for v in vals):
            return None  # null sorts first
        return min(vals)

    s = lowest('8480-6')
    dd = lowest('8462-4')
    res["numerator"] = s is not None and dd is not None and s < 140 and dd < 90
    return res
