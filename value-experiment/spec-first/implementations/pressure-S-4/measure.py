import re
from datetime import datetime, timedelta

NEG = datetime(1, 1, 1)
POS = datetime(9999, 12, 31, 23, 59, 59, 999000)
MAXT = datetime.max.time()
MINT = datetime.min.time()


def pdt(s):
    """Parse FHIR date/dateTime -> (lo, hi) datetimes by precision (offset ignored)."""
    if not s:
        return None
    m = re.match(r'^(\d{4})(?:-(\d\d))?(?:-(\d\d))?(?:T(\d\d)(?::(\d\d))?(?::(\d\d))?(?:\.(\d+))?)?', s)
    if not m:
        return None
    y, mo, d, h, mi, sec, fr = m.groups()
    y = int(y)
    if mo is None:
        return datetime(y, 1, 1), datetime(y, 12, 31, 23, 59, 59, 999000)
    mo = int(mo)
    if d is None:
        nxt = datetime(y + (mo == 12), mo % 12 + 1, 1)
        return datetime(y, mo, 1), nxt - timedelta(milliseconds=1)
    d = int(d)
    if h is None:
        return datetime(y, mo, d), datetime(y, mo, d, 23, 59, 59, 999000)
    h = int(h)
    if mi is None:
        return datetime(y, mo, d, h), datetime(y, mo, d, h, 59, 59, 999000)
    mi = int(mi)
    if sec is None:
        return datetime(y, mo, d, h, mi), datetime(y, mo, d, h, mi, 59, 999000)
    sec = int(sec)
    if fr is None:
        return datetime(y, mo, d, h, mi, sec), datetime(y, mo, d, h, mi, sec, 999000)
    t = datetime(y, mo, d, h, mi, sec, int(fr.ljust(6, '0')[:6]))
    return t, t


def interval_of(r, base):
    """toInterval of a dateTime/Period choice element. Returns (lo, hi) or None."""
    if base + 'DateTime' in r:
        p = pdt(r[base + 'DateTime'])
        return (p[0], p[1]) if p else None
    if base + 'Instant' in r:
        p = pdt(r[base + 'Instant'])
        return (p[0], p[1]) if p else None
    per = r.get(base + 'Period')
    if per is None and base == 'period':
        per = r.get('period')
    if per is not None:
        s = pdt(per.get('start'))
        e = pdt(per.get('end'))
        return (s[0] if s else NEG, e[1] if e else POS)
    return None


def overlaps(a, b):
    if a is None or b is None:
        return False
    return a[0] <= b[1] and b[0] <= a[1]


def dday(iv):
    return (datetime.combine(iv[0].date(), MINT), datetime.combine(iv[1].date(), MAXT))


def codes_of(cc):
    out = set()
    if not cc:
        return out
    for c in cc.get('coding', []) or []:
        out.add((c.get('system'), c.get('code')))
    return out


def in_vs(cc, vs):
    if isinstance(cc, list):
        return any(in_vs(x, vs) for x in cc)
    return bool(codes_of(cc) & vs)


def evaluate(resources, valuesets, period_start, period_end):
    ps = pdt(period_start)[0]
    pe = pdt(period_end)[1]
    MP = (ps, pe)

    def VS(n):
        return valuesets.get(n, set())

    by = {}
    for r in resources:
        by.setdefault(r.get('resourceType'), []).append(r)
    patient = (by.get('Patient') or [{}])[0]

    def age_at(d):
        b = patient.get('birthDate')
        if not b:
            return None
        bd = pdt(b)[0]
        return d.year - bd.year - ((d.month, d.day) < (bd.month, bd.day))

    age = age_at(pe)

    def with_code(rtype, vs, field='code'):
        return [r for r in by.get(rtype, []) if in_vs(r.get(field), vs)]

    def with_type(rtype, vs):
        return [r for r in by.get(rtype, []) if in_vs(r.get('type'), vs)]

    def clin(cond, code):
        return any(c.get('code') == code for c in (cond.get('clinicalStatus') or {}).get('coding', []))

    def prevalence(c):
        start = NEG
        if 'onsetDateTime' in c:
            p = pdt(c['onsetDateTime'])
            start = p[0] if p else NEG
        elif 'onsetPeriod' in c:
            start = interval_of(c, 'onset')[0]
        ab = None
        if 'abatementDateTime' in c:
            p = pdt(c['abatementDateTime'])
            ab = p[1] if p else None
        elif 'abatementPeriod' in c:
            e = c['abatementPeriod'].get('end')
            ab = pdt(e)[1] if e else None
        return (start, ab if ab else POS)

    def perf_enc(lst):
        return [e for e in lst if e.get('status') in ('finished', 'arrived', 'triaged', 'in-progress', 'onleave')]

    def perf_proc(lst):
        return [p for p in lst if p.get('status') == 'completed']

    def assess(lst):
        return [o for o in lst if o.get('status') in ('final', 'amended', 'corrected')
                and any('survey' in [c.get('code') for c in cat.get('coding', [])] for cat in o.get('category', []))]

    def during_day(iv, per):
        if iv is None:
            return False
        d, p = dday(iv), dday(per)
        return d[0] >= p[0] and d[1] <= p[1]

    def overlaps_day(iv, per):
        if iv is None:
            return False
        return overlaps(dday(iv), dday(per))

    def ends_during_day(iv, per):
        if iv is None or iv[1] == POS:
            return False
        p = dday(per)
        return p[0] <= iv[1] <= p[1]

    # ---- initial population
    m6 = ps.month + 6
    six = datetime(ps.year + (m6 - 1) // 12, (m6 - 1) % 12 + 1, ps.day) - timedelta(milliseconds=1)
    htn = [c for c in with_code('Condition', VS('Essential Hypertension'))
           if overlaps(prevalence(c), (ps, six))]
    enc_vs = set()
    for n in ["Office Visit", "Annual Wellness Visit",
              "Preventive Care Services Established Office Visit, 18 and Up",
              "Preventive Care Services Initial Office Visit, 18 and Up",
              "Home Healthcare Services", "Virtual Encounter", "Telephone Visits"]:
        enc_vs |= VS(n)
    qual_enc = [e for e in perf_enc(with_type('Encounter', enc_vs))
                if during_day(interval_of(e, 'period'), MP)]
    ip = age is not None and 18 <= age <= 85 and bool(htn) and bool(qual_enc)
    res = {"initial-population": ip, "denominator": ip, "denominator-exclusion": False, "numerator": False}
    if not ip:
        return res

    # ---- exclusions
    def hospice():
        disp = {('http://snomed.info/sct', '428371000124100'), ('http://snomed.info/sct', '428361000124107')}
        for e in perf_enc(with_type('Encounter', VS('Encounter Inpatient'))):
            dd = (e.get('hospitalization') or {}).get('dischargeDisposition')
            if codes_of(dd) & disp and ends_during_day(interval_of(e, 'period'), MP):
                return True
        for e in perf_enc(with_type('Encounter', VS('Hospice Encounter'))):
            if overlaps_day(interval_of(e, 'period'), MP):
                return True
        for o in assess(with_code('Observation', {('http://loinc.org', '45755-6')})):
            if ('http://snomed.info/sct', '373066001') in codes_of(o.get('valueCodeableConcept')) \
                    and overlaps_day(interval_of(o, 'effective'), MP):
                return True
        for s in with_code('ServiceRequest', VS('Hospice Care Ambulatory')):
            if s.get('status') in ('active', 'completed') and s.get('intent') == 'order':
                a = pdt(s.get('authoredOn'))
                if a and during_day(a, MP):
                    return True
        for p in perf_proc(with_code('Procedure', VS('Hospice Care Ambulatory'))):
            if overlaps_day(interval_of(p, 'performed'), MP):
                return True
        for c in with_code('Condition', VS('Hospice Diagnosis')):
            if overlaps_day(prevalence(c), MP):
                return True
        return False

    def preg_renal():
        for n in ('Pregnancy', 'End Stage Renal Disease', 'Kidney Transplant Recipient',
                  'Chronic Kidney Disease, Stage 5'):
            for c in with_code('Condition', VS(n)):
                if overlaps(prevalence(c), MP):
                    return True
        return False

    def esrd_proc():
        for p in perf_proc(with_code('Procedure', VS('Kidney Transplant') | VS('Dialysis Services'))):
            iv = interval_of(p, 'performed')
            if iv and iv[1] != POS and iv[1] <= pe:
                return True
        return False

    def esrd_enc():
        for e in perf_enc(with_type('Encounter', VS('ESRD Monthly Outpatient Services'))):
            iv = interval_of(e, 'period')
            if iv and iv[0] != NEG and iv[0] <= pe:
                return True
        return False

    def frailty():
        for d in with_code('DeviceRequest', VS('Frailty Device'), 'codeCodeableConcept'):
            if d.get('status') in ('active', 'completed') and d.get('intent') == 'order':
                dnp = [e.get('valueBoolean') for e in d.get('modifierExtension', [])
                       if e.get('url') == 'http://hl7.org/fhir/us/qicore/StructureDefinition/qicore-doNotPerform']
                if dnp and dnp[0] is True:
                    continue
                a = pdt(d.get('authoredOn'))
                if a and during_day(a, MP):
                    return True
        for o in assess(with_code('Observation', {('http://loinc.org', '98181-1')})):
            if in_vs(o.get('valueCodeableConcept'), VS('Frailty Device')) \
                    and ends_during_day(interval_of(o, 'effective'), MP):
                return True
        for c in with_code('Condition', VS('Frailty Diagnosis')):
            if overlaps_day(prevalence(c), MP):
                return True
        for e in perf_enc(with_type('Encounter', VS('Frailty Encounter'))):
            if overlaps_day(interval_of(e, 'period'), MP):
                return True
        for o in with_code('Observation', VS('Frailty Symptom')):
            if o.get('status') in ('preliminary', 'final', 'amended', 'corrected') \
                    and overlaps_day(interval_of(o, 'effective'), MP):
                return True
        return False

    yb = (datetime(ps.year - 1, ps.month, ps.day), pe)

    def adv_illness():
        for c in with_code('Condition', VS('Advanced Illness')):
            s = prevalence(c)[0]
            if s != NEG:
                s2 = datetime.combine(s.date(), MINT)
                if dday(yb)[0] <= s2 <= dday(yb)[1]:
                    return True
        return False

    def med_period(m):
        di = m.get('dosageInstruction') or []
        dosage = di[0] if len(di) == 1 else None
        rep = ((dosage or {}).get('timing') or {}).get('repeat') or {}
        bounds = rep.get('boundsPeriod')
        dr = m.get('dispenseRequest') or {}
        start = None
        if bounds and bounds.get('start'):
            start = pdt(bounds['start'])[0]
        elif m.get('authoredOn'):
            start = pdt(m['authoredOn'])[0]
        elif (dr.get('validityPeriod') or {}).get('start'):
            start = pdt(dr['validityPeriod']['start'])[0]
        if start is None:
            return None
        start = datetime.combine(start.date(), MINT)
        days = None
        esd = dr.get('expectedSupplyDuration')
        if esd and esd.get('value') is not None:
            u = esd.get('code') or esd.get('unit')
            f = {'d': 1, 'days': 1, 'day': 1, 'wk': 7, 'weeks': 7, 'week': 7, 'mo': 30, 'a': 365}.get(u, 1)
            days = esd['value'] * f
        else:
            q = (dr.get('quantity') or {}).get('value')
            dar = (dosage or {}).get('doseAndRate') or []
            dose = None
            if len(dar) == 1:
                if 'doseRange' in dar[0]:
                    dose = (dar[0]['doseRange'].get('high') or {}).get('value')
                elif 'doseQuantity' in dar[0]:
                    dose = dar[0]['doseQuantity'].get('value')
            freq = rep.get('frequencyMax') or rep.get('frequency')
            per = rep.get('period')
            perd = None
            if per is not None:
                uf = {'s': 1 / 86400.0, 'min': 1 / 1440.0, 'h': 1 / 24.0, 'd': 1, 'wk': 7, 'mo': 30,
                      'a': 365}.get(rep.get('periodUnit'))
                perd = per * uf if uf else None
            if freq and perd:
                dpd = freq / perd
            elif rep.get('timeOfDay'):
                dpd = len(rep['timeOfDay'])
            else:
                dpd = 1.0
            if q is not None and dose:
                days = q / (dose * dpd)
        if days is None:
            return None
        total = days * (1 + (dr.get('numberOfRepeatsAllowed') or 0))
        end = start + timedelta(days=int(total - 1))
        return (start, datetime.combine(end.date(), MAXT))

    def dementia_meds():
        for m in by.get('MedicationRequest', []):
            if not (m.get('status') == 'active' and m.get('intent') == 'order'):
                continue
            if not in_vs(m.get('medicationCodeableConcept'), VS('Dementia Medications')):
                continue
            per = med_period(m)
            if per and overlaps_day(per, yb):
                return True
        return False

    def nursing_home():
        obs = []
        for o in assess(with_code('Observation', {('http://loinc.org', '71802-3')})):
            iv = interval_of(o, 'effective')
            if iv and iv[1] != POS and iv[1] <= pe:
                obs.append((iv[1], o))
        if not obs:
            return False
        obs.sort(key=lambda t: t[0])
        return ('http://snomed.info/sct', '160734000') in codes_of(obs[-1][1].get('valueCodeableConcept'))

    def palliative():
        for o in assess(with_code('Observation', {('http://loinc.org', '71007-9')})):
            if overlaps_day(interval_of(o, 'effective'), MP):
                return True
        for c in with_code('Condition', VS('Palliative Care Diagnosis')):
            if overlaps_day(prevalence(c), MP):
                return True
        for e in perf_enc(with_type('Encounter', VS('Palliative Care Encounter'))):
            if overlaps_day(interval_of(e, 'period'), MP):
                return True
        for p in perf_proc(with_code('Procedure', VS('Palliative Care Intervention'))):
            if overlaps_day(interval_of(p, 'performed'), MP):
                return True
        return False

    excl = False
    if hospice() or preg_renal() or esrd_proc() or esrd_enc():
        excl = True
    elif age >= 66 and ((frailty() and (age >= 81 or adv_illness() or dementia_meds())) or nursing_home()):
        excl = True
    elif palliative():
        excl = True
    res["denominator-exclusion"] = excl
    if excl:
        return res

    # ---- numerator
    encs = {e.get('id'): e for e in by.get('Encounter', [])}
    badcls = {'EMER', 'IMP', 'ACUTE', 'NONAC', 'PRENC', 'SS'}
    SYS = ('http://loinc.org', '8480-6')
    DIA = ('http://loinc.org', '8462-4')
    readings = []
    for o in by.get('Observation', []):
        if o.get('status') not in ('final', 'amended', 'corrected'):
            continue
        profiles = (o.get('meta') or {}).get('profile', [])
        is_bp = any('observation-bp' in p for p in profiles) or ('http://loinc.org', '85354-9') in codes_of(o.get('code'))
        if not is_bp:
            continue
        ref = (o.get('encounter') or {}).get('reference')
        if ref:
            e = encs.get(ref.split('/')[-1])
            if e and (e.get('class') or {}).get('code') in badcls:
                continue
        iv = interval_of(o, 'effective')
        if iv is None:
            continue
        latest = iv[1] if iv[1] != POS else iv[0]
        if not (dday(MP)[0] <= latest <= dday(MP)[1]):
            continue
        readings.append((latest.date(), o))
    if not readings:
        return res
    day = max(d for d, _ in readings)

    def lowest(code):
        vals = []
        for d, o in readings:
            if d != day:
                continue
            comps = [c for c in o.get('component', []) if code in codes_of(c.get('code'))]
            if len(comps) != 1:
                vals.append(None)
                continue
            q = comps[0].get('valueQuantity')
            vals.append(q.get('value') if q else None)
        if not vals or any(v is None for v in vals):
            return None
        return min(vals)

    s, d = lowest(SYS), lowest(DIA)
    res["numerator"] = s is not None and d is not None and s < 140 and d < 90
    return res
