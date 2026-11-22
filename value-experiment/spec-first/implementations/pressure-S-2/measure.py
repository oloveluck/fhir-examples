import re
from datetime import datetime, date, timedelta, timezone

MAXD = datetime(9999, 12, 31, tzinfo=timezone.utc)
MIND = datetime(1, 1, 2, tzinfo=timezone.utc)

SURVEY = ('http://terminology.hl7.org/CodeSystem/observation-category', 'survey')
SNOMED = 'http://snomed.info/sct'
LOINC = 'http://loinc.org'
CLIN = 'http://terminology.hl7.org/CodeSystem/condition-clinical'


# ---------- date helpers ----------
def parse_dt(s, end=False):
    """FHIR date/dateTime -> (utc datetime, local date); partial dates widen to start/end."""
    if s is None:
        return None
    m = re.match(r'^(\d{4})(?:-(\d\d))?(?:-(\d\d))?(?:T(\d\d):(\d\d)(?::(\d\d)(?:\.(\d+))?)?(Z|[+-]\d\d:\d\d)?)?$', s)
    if not m:
        return None
    y, mo, d, hh, mi, ss, frac, tz = m.groups()
    if hh is None:
        if mo is None:
            lo = datetime(int(y), 1, 1, tzinfo=timezone.utc)
            hi = datetime(int(y), 12, 31, 23, 59, 59, 999000, tzinfo=timezone.utc)
        elif d is None:
            lo = datetime(int(y), int(mo), 1, tzinfo=timezone.utc)
            nm = datetime(int(y) + (int(mo) == 12), int(mo) % 12 + 1, 1, tzinfo=timezone.utc)
            hi = nm - timedelta(milliseconds=1)
        else:
            lo = datetime(int(y), int(mo), int(d), tzinfo=timezone.utc)
            hi = lo + timedelta(days=1, milliseconds=-1)
        dt = hi if end else lo
        return dt, dt.date()
    us = int((frac or '0').ljust(6, '0')[:6])
    off = timedelta(0)
    if tz and tz != 'Z':
        sign = 1 if tz[0] == '+' else -1
        off = sign * timedelta(hours=int(tz[1:3]), minutes=int(tz[4:6]))
    local = datetime(int(y), int(mo), int(d), int(hh), int(mi), int(ss or 0), us)
    return (local - off).replace(tzinfo=timezone.utc), local.date()


class Iv:
    def __init__(self, lo, hi):
        self.lo, self.hi = lo, hi  # (utc, localdate) or None = unbounded


def dt_of(v):
    return v[0] if v else None


def to_interval(res, base):
    for suffix in ('DateTime', 'Instant'):
        s = res.get(base + suffix)
        if s is not None:
            return Iv(parse_dt(s), parse_dt(s, True))
    p = res.get(base + 'Period')
    if p is not None:
        return Iv(parse_dt(p.get('start')), parse_dt(p.get('end'), True))
    return None


def to_interval_period(res):
    p = res.get('period')
    if p is None:
        return None
    return Iv(parse_dt(p.get('start')), parse_dt(p.get('end'), True))


def latest(iv):
    if iv is None:
        return None
    return iv.hi if iv.hi is not None else iv.lo


def d_in(v, ps, pe):
    return v is not None and ps <= v[1] <= pe


def overlaps_day(iv, ps, pe):
    if iv is None or (iv.lo is None and iv.hi is None):
        return False
    lo = iv.lo[1] if iv.lo else date.min
    hi = iv.hi[1] if iv.hi else date.max
    return lo <= pe and hi >= ps


def during_day(iv, ps, pe):
    if iv is None or iv.lo is None or iv.hi is None:
        return False
    return iv.lo[1] >= ps and iv.hi[1] <= pe


def pdate(s):
    return datetime.strptime(s[:10], '%Y-%m-%d').date()


def overlaps_exact(iv, lo, hi_excl=None, hi_incl=None):
    if iv is None:
        return False
    ilo = dt_of(iv.lo) or MIND
    ihi = dt_of(iv.hi) or MAXD
    if hi_excl is not None:
        return ilo < hi_excl and ihi >= lo
    return ilo <= hi_incl and ihi >= lo


def add_months(d, n):
    m = d.month - 1 + n
    return d.replace(year=d.year + m // 12, month=m % 12 + 1)


def minus_year(d):
    try:
        return d.replace(year=d.year - 1)
    except ValueError:
        return d.replace(year=d.year - 1, day=28)


def _ad(d):
    return (datetime(d.year, d.month, d.day, tzinfo=timezone.utc), d)


# ---------- code helpers ----------
def codings(cc):
    if not cc or not isinstance(cc, dict):
        return []
    return [(c.get('system'), c.get('code')) for c in cc.get('coding', [])]


def in_vs(cc, vs):
    return any(c in vs for c in codings(cc))


def has_code(cc, system, code):
    return (system, code) in codings(cc)


def is_survey(o):
    return any(SURVEY in codings(c) for c in o.get('category', []))


def assessment_performed(o):
    return o.get('status') in ('final', 'amended', 'corrected') and is_survey(o)


def enc_performed(e):
    return e.get('status') in ('finished', 'arrived', 'triaged', 'in-progress', 'onleave')


# ---------- condition ----------
def age_to_date(q, birth):
    if birth is None or not q or q.get('value') is None:
        return None
    unit = q.get('code') or q.get('unit')
    v = q['value']
    if unit in ('a', 'year', 'years'):
        y = int(v)
    elif unit in ('mo', 'month', 'months'):
        y = int(v // 12)
    else:
        return None
    b = pdate(birth)
    try:
        return b.replace(year=b.year + y)
    except ValueError:
        return b.replace(year=b.year + y, day=28)


def onset_interval(c, birth):
    iv = to_interval(c, 'onset')
    if iv:
        return iv
    d = age_to_date(c.get('onsetAge'), birth)
    if d:
        return Iv(_ad(d), _ad(d.replace(year=d.year + 1)))
    return None


def abatement_interval(c, birth):
    iv = to_interval(c, 'abatement')
    if iv:
        return iv
    d = age_to_date(c.get('abatementAge'), birth)
    if d:
        return Iv(_ad(d), _ad(d.replace(year=d.year + 1)))
    return None


def prevalence(c, birth):
    active = any(s[0] == CLIN and s[1] in ('active', 'recurrence', 'relapse')
                 for s in codings(c.get('clinicalStatus')))
    on = onset_interval(c, birth)
    lo = on.lo if on else None
    ab = abatement_interval(c, birth)
    hi = ab.hi if ab else None
    if active:
        return Iv(lo, hi)
    if hi is None:
        return None  # open end with unknown abatement: not shown to overlap
    return Iv(lo, hi)


# ---------- main ----------
def evaluate(resources, valuesets, period_start, period_end):
    ps, pe = pdate(period_start), pdate(period_end)
    mp_lo = datetime(ps.year, ps.month, ps.day, tzinfo=timezone.utc)
    mp_hi = datetime(pe.year, pe.month, pe.day, tzinfo=timezone.utc) + timedelta(days=1, milliseconds=-1)

    def VS(n):
        return valuesets.get(n, set())

    def of(t):
        return [r for r in resources if r.get('resourceType') == t]

    patient = (of('Patient') or [{}])[0]
    birth = patient.get('birthDate')
    conds, encs, obs, procs = of('Condition'), of('Encounter'), of('Observation'), of('Procedure')

    def cond_in(vsn):
        return [c for c in conds if in_vs(c.get('code'), VS(vsn))]

    def enc_in(vsn):
        vs = VS(vsn)
        return [e for e in encs if enc_performed(e) and any(in_vs(cc, vs) for cc in (e.get('type') or []))]

    age = None
    if birth:
        b = pdate(birth)
        age = pe.year - b.year - ((pe.month, pe.day) < (b.month, b.day))

    # ---- initial population
    htn_end = datetime.combine(add_months(ps, 6), datetime.min.time(), tzinfo=timezone.utc)
    htn = any(overlaps_exact(prevalence(c, birth), mp_lo, hi_excl=htn_end)
              for c in cond_in('Essential Hypertension'))
    qual_names = ['Office Visit', 'Annual Wellness Visit',
                  'Preventive Care Services Established Office Visit, 18 and Up',
                  'Preventive Care Services Initial Office Visit, 18 and Up',
                  'Home Healthcare Services', 'Virtual Encounter', 'Telephone Visits']
    qual = any(during_day(to_interval_period(e), ps, pe) for n in qual_names for e in enc_in(n))
    ip = age is not None and 18 <= age <= 85 and htn and qual
    out = {"initial-population": bool(ip), "denominator": bool(ip),
           "denominator-exclusion": False, "numerator": False}
    if not ip:
        return out

    # ---- exclusions
    def hospice():
        for e in enc_in('Encounter Inpatient'):
            dd = (e.get('hospitalization') or {}).get('dischargeDisposition')
            if dd and (has_code(dd, SNOMED, '428361000124107') or has_code(dd, SNOMED, '428371000124100')):
                iv = to_interval_period(e)
                if iv and iv.hi and d_in(iv.hi, ps, pe):
                    return True
        for e in enc_in('Hospice Encounter'):
            if overlaps_day(to_interval_period(e), ps, pe):
                return True
        for o in obs:
            if has_code(o.get('code'), LOINC, '45755-6') and assessment_performed(o) \
                    and has_code(o.get('valueCodeableConcept'), SNOMED, '373066001') \
                    and overlaps_day(to_interval(o, 'effective'), ps, pe):
                return True
        for s in of('ServiceRequest'):
            if in_vs(s.get('code'), VS('Hospice Care Ambulatory')) and s.get('status') in ('active', 'completed') \
                    and s.get('intent') == 'order' and s.get('authoredOn') \
                    and d_in(parse_dt(s['authoredOn']), ps, pe):
                return True
        for p in procs:
            if in_vs(p.get('code'), VS('Hospice Care Ambulatory')) and p.get('status') == 'completed' \
                    and overlaps_day(to_interval(p, 'performed'), ps, pe):
                return True
        for c in cond_in('Hospice Diagnosis'):
            if overlaps_day(prevalence(c, birth), ps, pe):
                return True
        return False

    def preg_renal():
        for n in ('Pregnancy', 'End Stage Renal Disease', 'Kidney Transplant Recipient',
                  'Chronic Kidney Disease, Stage 5'):
            for c in cond_in(n):
                if overlaps_exact(prevalence(c, birth), mp_lo, hi_incl=mp_hi):
                    return True
        return False

    def esrd_proc():
        for n in ('Kidney Transplant', 'Dialysis Services'):
            for p in procs:
                if in_vs(p.get('code'), VS(n)) and p.get('status') == 'completed':
                    iv = to_interval(p, 'performed')
                    if iv and iv.hi and iv.hi[0] <= mp_hi:
                        return True
        return False

    def esrd_enc():
        for e in enc_in('ESRD Monthly Outpatient Services'):
            iv = to_interval_period(e)
            if iv and iv.lo and iv.lo[0] <= mp_hi:
                return True
        return False

    prior = minus_year(ps)

    def advanced_illness():
        for c in cond_in('Advanced Illness'):
            iv = prevalence(c, birth)
            if iv and iv.lo and prior <= iv.lo[1] <= pe:
                return True
        return False

    def med_period(r):
        dis = r.get('dosageInstruction') or []
        if len(dis) > 1:
            return None
        dosage = dis[0] if dis else {}
        dar = dosage.get('doseAndRate') or []
        if len(dar) > 1:
            return None
        dar = dar[0] if dar else {}
        rep = (dosage.get('timing') or {}).get('repeat') or {}
        freq = rep.get('frequencyMax') or rep.get('frequency')
        per = rep.get('period')
        days = {'d': 1, 'wk': 7, 'mo': 30, 'a': 365, 'h': 1 / 24, 'min': 1 / 1440}.get(rep.get('periodUnit'))
        daily = None
        if freq is not None and per and days:
            daily = freq / (per * days)
        if daily is None:
            tod = rep.get('timeOfDay')
            daily = float(len(tod)) if tod else 1.0
        dose = None
        if 'doseRange' in dar:
            dose = (dar['doseRange'].get('high') or {}).get('value')
        elif 'doseQuantity' in dar:
            dose = dar['doseQuantity'].get('value')
        bounds = rep.get('boundsPeriod')
        dr = r.get('dispenseRequest') or {}
        start = None
        if bounds and bounds.get('start'):
            start = parse_dt(bounds['start'])[1]
        elif r.get('authoredOn'):
            start = parse_dt(r['authoredOn'])[1]
        elif (dr.get('validityPeriod') or {}).get('start'):
            start = parse_dt(dr['validityPeriod']['start'])[1]
        supply = None
        es = dr.get('expectedSupplyDuration')
        if es and es.get('value') is not None:
            m = {'d': 1, 'day': 1, 'days': 1, 'wk': 7, 'week': 7, 'mo': 30, 'month': 30,
                 'h': 1 / 24}.get(es.get('code') or es.get('unit'))
            if m:
                supply = es['value'] * m
        if supply is None:
            q = (dr.get('quantity') or {}).get('value')
            if q is not None and dose:
                supply = q / (dose * daily)
        refills = dr.get('numberOfRepeatsAllowed') or 0
        if start is None or supply is None:
            return None
        total = supply * (1 + refills)
        end = start + timedelta(days=int(total - 1))
        return Iv(_ad(start), _ad(end))

    def med_in_vs(r):
        vs = VS('Dementia Medications')
        if 'medicationCodeableConcept' in r:
            return in_vs(r['medicationCodeableConcept'], vs)
        ref = (r.get('medicationReference') or {}).get('reference')
        if ref:
            mid = ref.split('/')[-1]
            for m in of('Medication'):
                if m.get('id') == mid and in_vs(m.get('code'), vs):
                    return True
        return False

    def dementia_meds():
        for r in of('MedicationRequest'):
            if r.get('status') == 'active' and r.get('intent') == 'order' and med_in_vs(r):
                iv = med_period(r)
                if iv and iv.lo[1] <= pe and iv.hi[1] >= prior:
                    return True
        return False

    def frailty():
        for r in of('DeviceRequest'):
            if in_vs(r.get('codeCodeableConcept'), VS('Frailty Device')) \
                    and r.get('status') in ('active', 'completed') \
                    and r.get('intent') == 'order' and not r.get('doNotPerform') and r.get('authoredOn') \
                    and d_in(parse_dt(r['authoredOn']), ps, pe):
                return True
        for o in obs:
            if has_code(o.get('code'), LOINC, '98181-1') and assessment_performed(o) \
                    and in_vs(o.get('valueCodeableConcept'), VS('Frailty Device')):
                iv = to_interval(o, 'effective')
                if iv and iv.hi and d_in(iv.hi, ps, pe):
                    return True
        for c in cond_in('Frailty Diagnosis'):
            if overlaps_day(prevalence(c, birth), ps, pe):
                return True
        for e in enc_in('Frailty Encounter'):
            if overlaps_day(to_interval_period(e), ps, pe):
                return True
        for o in obs:
            if in_vs(o.get('code'), VS('Frailty Symptom')) \
                    and o.get('status') in ('preliminary', 'final', 'amended', 'corrected') \
                    and overlaps_day(to_interval(o, 'effective'), ps, pe):
                return True
        return False

    def nursing_home():
        if age < 66:
            return False
        cands = []
        for o in obs:
            if has_code(o.get('code'), LOINC, '71802-3') and assessment_performed(o):
                iv = to_interval(o, 'effective')
                if iv and iv.hi and iv.hi[1] <= pe:
                    cands.append((iv.hi[0], o))
        if not cands:
            return False
        cands.sort(key=lambda x: x[0])
        return has_code(cands[-1][1].get('valueCodeableConcept'), SNOMED, '160734000')

    def palliative():
        for o in obs:
            if has_code(o.get('code'), LOINC, '71007-9') and assessment_performed(o) \
                    and overlaps_day(to_interval(o, 'effective'), ps, pe):
                return True
        for c in cond_in('Palliative Care Diagnosis'):
            if overlaps_day(prevalence(c, birth), ps, pe):
                return True
        for e in enc_in('Palliative Care Encounter'):
            if overlaps_day(to_interval_period(e), ps, pe):
                return True
        for p in procs:
            if in_vs(p.get('code'), VS('Palliative Care Intervention')) and p.get('status') == 'completed' \
                    and overlaps_day(to_interval(p, 'performed'), ps, pe):
                return True
        return False

    def frail_exclusion():
        if age < 66 or not frailty():
            return False
        if age >= 81:
            return True
        return advanced_illness() or dementia_meds()

    excl = (hospice() or preg_renal() or esrd_proc() or esrd_enc() or frail_exclusion()
            or nursing_home() or palliative())
    out["denominator-exclusion"] = bool(excl)
    if excl:
        return out

    # ---- numerator
    enc_by_id = {e.get('id'): e for e in encs}
    BAD = {'EMER', 'IMP', 'ACUTE', 'NONAC', 'PRENC', 'SS'}
    readings = []
    for o in obs:
        profiles = (o.get('meta') or {}).get('profile') or []
        is_bp = any(p.endswith('observation-bp') for p in profiles) or has_code(o.get('code'), LOINC, '85354-9')
        if not is_bp or o.get('status') not in ('final', 'amended', 'corrected'):
            continue
        ref = (o.get('encounter') or {}).get('reference')
        if ref:
            e = enc_by_id.get(ref.split('/')[-1])
            if e and (e.get('class') or {}).get('code') in BAD:
                continue
        lt = latest(to_interval(o, 'effective'))
        if lt is None or not d_in(lt, ps, pe):
            continue
        readings.append((lt[1], o))
    if not readings:
        return out
    day = max(d for d, _ in readings)

    def lowest(code):
        vals = []
        for d, o in readings:
            if d != day:
                continue
            comps = [c for c in o.get('component', []) if has_code(c.get('code'), LOINC, code)]
            q = comps[0].get('valueQuantity') if comps else None
            if q is None or q.get('value') is None or \
                    (q.get('code') or q.get('unit') or 'mm[Hg]') not in ('mm[Hg]', 'mmHg'):
                vals.append(None)
            else:
                vals.append(q['value'])
        if not vals or any(v is None for v in vals):
            return None
        return min(vals)

    s, d = lowest('8480-6'), lowest('8462-4')
    out["numerator"] = s is not None and d is not None and s < 140 and d < 90
    return out
