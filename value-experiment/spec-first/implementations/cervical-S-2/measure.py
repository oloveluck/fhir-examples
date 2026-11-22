from datetime import datetime, timedelta, timezone, date
import re

MS = timedelta(milliseconds=1)
UTC = timezone.utc


def pdt(s, end=False):
    """Parse FHIR date/dateTime to aware UTC datetime; partial dates expand to range edge."""
    if not s:
        return None
    s = str(s)
    m = re.match(r'^(\d{4})(?:-(\d{2}))?(?:-(\d{2}))?$', s)
    if m:
        y = int(m.group(1))
        mo = m.group(2)
        d = m.group(3)
        if d:
            a = datetime(y, int(mo), int(d), tzinfo=UTC)
            return a + timedelta(days=1) - MS if end else a
        if mo:
            a = datetime(y, int(mo), 1, tzinfo=UTC)
            n = datetime(y + (int(mo) == 12), int(mo) % 12 + 1, 1, tzinfo=UTC)
            return n - MS if end else a
        a = datetime(y, 1, 1, tzinfo=UTC)
        return datetime(y + 1, 1, 1, tzinfo=UTC) - MS if end else a
    try:
        dt = datetime.fromisoformat(s.replace('Z', '+00:00'))
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=UTC)
        return dt.astimezone(UTC)
    except Exception:
        return None


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


def has_code(cc, system, code):
    return (system, code) in codes_of(cc)


def interval(r, base):
    """(low, high) of choice element base[x]; None if absent."""
    for k in ('DateTime', 'Instant'):
        if base + k in r:
            v = r[base + k]
            return pdt(v), pdt(v, True)
    if base + 'Period' in r:
        p = r[base + 'Period']
        return pdt(p.get('start')), pdt(p.get('end'), True)
    return None


OBS_CAT = 'http://terminology.hl7.org/CodeSystem/observation-category'


def evaluate(resources, valuesets, period_start, period_end):
    def vs(n):
        return valuesets.get(n, set())

    MP0 = pdt(period_start)
    MP1 = pdt(period_end, True)

    def by(t):
        return [r for r in resources if r.get('resourceType') == t]

    patient = (by('Patient') or [{}])[0]
    bd = patient.get('birthDate')

    def age_at(d):
        b = date.fromisoformat(bd[:10])
        return d.year - b.year - ((d.month, d.day) < (b.month, b.day))

    def overlaps(iv):
        if iv is None:
            return False
        a, b = iv
        return (b is None or b >= MP0) and (a is None or a <= MP1)

    def during(iv):
        if iv is None:
            return False
        a, b = iv
        return a is not None and b is not None and a >= MP0 and b <= MP1

    age_ok = False
    if bd:
        try:
            age_ok = 24 <= age_at(MP1.date()) <= 64
        except Exception:
            pass

    def enc_ok(e):
        return e.get('status') in ('finished', 'arrived', 'triaged', 'in-progress', 'onleave')

    def enc_iv(e):
        if not e.get('period'):
            return None
        return interval({'periodPeriod': e['period']}, 'period')

    qnames = ["Office Visit", "Preventive Care Services Established Office Visit, 18 and Up",
              "Preventive Care Services Initial Office Visit, 18 and Up", "Home Healthcare Services",
              "Telephone Visits", "Virtual Encounter"]
    qset = set()
    for n in qnames:
        qset |= vs(n)
    qual = any(enc_ok(e) and in_vs(e.get('type', []), qset) and during(enc_iv(e))
               for e in by('Encounter'))
    ip = bool(age_ok and patient.get('gender') == 'female' and qual)

    def age_iv(q):
        if not q or not bd:
            return None
        try:
            b = date.fromisoformat(bd[:10])
            n = int(q.get('value'))
            dd = 28 if (b.month == 2 and b.day == 29) else b.day
            lo = datetime(b.year + n, b.month, dd, tzinfo=UTC)
            hi = datetime(b.year + n + 1, b.month, dd, tzinfo=UTC) - MS
            return lo, hi
        except Exception:
            return None

    def prev_iv(c):
        on = None
        if 'onsetDateTime' in c or 'onsetPeriod' in c:
            on = interval(c, 'onset')
        elif 'onsetAge' in c:
            on = age_iv(c['onsetAge'])
        start = on[0] if on else None
        end = None
        if 'abatementDateTime' in c:
            end = pdt(c['abatementDateTime'])
        elif 'abatementPeriod' in c:
            end = pdt(c['abatementPeriod'].get('end'))
        elif 'abatementAge' in c:
            a = age_iv(c['abatementAge'])
            end = a[1] if a else None
        return start, end

    def cond_overlaps(c):
        s, e = prev_iv(c)
        return (e is None or e >= MP0) and (s is None or s <= MP1)

    absence = False
    for p in by('Procedure'):
        if p.get('status') == 'completed' and in_vs(p.get('code'), vs("Hysterectomy with No Residual Cervix")):
            iv = interval(p, 'performed')
            if iv and iv[1] is not None and iv[1] <= MP1:
                absence = True
    for c in by('Condition'):
        if in_vs(c.get('code'), vs("Congenital or Acquired Absence of Cervix")):
            s, _ = prev_iv(c)
            if s is not None and s <= MP1:
                absence = True

    def survey(o):
        return o.get('status') in ('final', 'amended', 'corrected') and any(
            has_code(c, OBS_CAT, 'survey') for c in o.get('category', []))

    hosp = False
    for e in by('Encounter'):
        if not enc_ok(e):
            continue
        per = enc_iv(e)
        if in_vs(e.get('type', []), vs("Encounter Inpatient")):
            dd = (e.get('hospitalization') or {}).get('dischargeDisposition')
            if dd and (has_code(dd, 'http://snomed.info/sct', '428361000124107')
                       or has_code(dd, 'http://snomed.info/sct', '428371000124100')):
                if per and per[1] is not None and MP0 <= per[1] <= MP1:
                    hosp = True
        if in_vs(e.get('type', []), vs("Hospice Encounter")) and overlaps(per):
            hosp = True
    for o in by('Observation'):
        if survey(o) and has_code(o.get('code'), 'http://loinc.org', '45755-6') \
                and has_code(o.get('valueCodeableConcept'), 'http://snomed.info/sct', '373066001') \
                and overlaps(interval(o, 'effective')):
            hosp = True
    for s in by('ServiceRequest'):
        if s.get('status') in ('active', 'completed') and s.get('intent') == 'order' \
                and in_vs(s.get('code'), vs("Hospice Care Ambulatory")):
            a = pdt(s.get('authoredOn'))
            if a and MP0 <= a <= MP1:
                hosp = True
    for p in by('Procedure'):
        if p.get('status') == 'completed' and in_vs(p.get('code'), vs("Hospice Care Ambulatory")) \
                and overlaps(interval(p, 'performed')):
            hosp = True
    for c in by('Condition'):
        if in_vs(c.get('code'), vs("Hospice Diagnosis")) and cond_overlaps(c):
            hosp = True

    pal = False
    for o in by('Observation'):
        if survey(o) and has_code(o.get('code'), 'http://loinc.org', '71007-9') \
                and overlaps(interval(o, 'effective')):
            pal = True
    for c in by('Condition'):
        if in_vs(c.get('code'), vs("Palliative Care Diagnosis")) and cond_overlaps(c):
            pal = True
    for e in by('Encounter'):
        if enc_ok(e) and in_vs(e.get('type', []), vs("Palliative Care Encounter")) and overlaps(enc_iv(e)):
            pal = True
    for p in by('Procedure'):
        if p.get('status') == 'completed' and in_vs(p.get('code'), vs("Palliative Care Intervention")) \
                and overlaps(interval(p, 'performed')):
            pal = True

    excl = hosp or absence or pal

    def has_value(o):
        return any(k.startswith('value') and o[k] is not None for k in o)

    def lab_ok(o):
        return o.get('status') in ('final', 'amended', 'corrected') and any(
            has_code(c, OBS_CAT, 'laboratory') for c in o.get('category', []))

    num = False
    for o in by('Observation'):
        if not lab_ok(o) or not has_value(o):
            continue
        iv = interval(o, 'effective')
        if not iv:
            continue
        l = iv[1] if iv[1] is not None else iv[0]
        if l is None:
            continue
        if in_vs(o.get('code'), vs("Pap Test")):
            if MP0.replace(year=MP0.year - 2) <= l <= MP1:
                num = True
        if in_vs(o.get('code'), vs("HPV Test")):
            try:
                if age_at(l.date()) >= 30 and MP0.replace(year=MP0.year - 4) <= l <= MP1:
                    num = True
            except Exception:
                pass

    return {"initial-population": ip,
            "denominator": ip,
            "denominator-exclusion": bool(ip and excl),
            "numerator": bool(ip and not excl and num)}
