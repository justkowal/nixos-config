"""Polish public holidays and the operator's day types (wd = Mon-Fri, sa = Sat, su = Sunday and holidays)."""
from datetime import date, timedelta


def easter(y):
    a, b, c = y % 19, y // 100, y % 100
    d, e = b // 4, b % 4
    f = (b + 8) // 25
    g = (b - f + 1) // 3
    h = (19 * a + b - d - g + 15) % 30
    i, k = c // 4, c % 4
    el = (32 + 2 * e + 2 * i - h - k) % 7
    m = (a + 11 * h + 22 * el) // 451
    month, day = divmod(h + el - 7 * m + 114, 31)
    return date(y, month, day + 1)


def holidays(y):
    e = easter(y)
    fixed = [(1, 1), (1, 6), (5, 1), (5, 3), (8, 15), (11, 1), (11, 11), (12, 24), (12, 25), (12, 26)]
    days = {date(y, m, d) for m, d in fixed}
    days |= {e, e + timedelta(days=1), e + timedelta(days=49), e + timedelta(days=60)}
    if y < 2025:
        days.discard(date(y, 12, 24))  # Christmas Eve became a public holiday in 2025
    return days


def day_type(d):
    if d in holidays(d.year) or d.weekday() == 6:
        return "su"
    return "sa" if d.weekday() == 5 else "wd"
