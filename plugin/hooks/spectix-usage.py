#!/usr/bin/env python3
# Parse `claude -p "/usage"` output into the compact JSON the menu-bar app reads.
#
# Why this exists: SpectiX shows your Claude *subscription* usage (current 5-hour
# session % + weekly %) and when each window resets. The authoritative numbers are the
# ones the `/usage` command prints — it hits Claude Code's own /api/oauth/usage endpoint
# with the live, auto-refreshed OAuth token, so they always match what you see in the
# terminal and need no token juggling on our side. The status hook runs
# `claude -p "/usage"` (throttled, backgrounded) and pipes its stdout here; we turn the
# human-readable lines into `{session_pct, session_resets_at, week_pct, ...}` and the app
# renders + counts down from the reset epochs.
#
# The reset times print as absolute local wall-clock ("resets Jul 2 at 7:39pm
# (America/Los_Angeles)") with no year, so we resolve them to Unix epochs here (Python
# has the timezone + date machinery; Swift would have to reimplement it): assume the
# current year in the stated zone, and if that lands well in the past, it wrapped a year
# boundary (a Dec reset seen in Jan) so bump to next year. Reset windows are always
# upcoming and within a week, so this is unambiguous.
#
# Prints one JSON object on success; exits non-zero (writes nothing) when the output
# isn't a subscription usage report — e.g. an API-credits account — so the app simply
# shows no usage line rather than a wrong one.

import sys, re, json, time
from datetime import datetime
try:
    from zoneinfo import ZoneInfo
except Exception:
    ZoneInfo = None

txt = sys.stdin.read()
now = time.time()


def reset_epoch(when, tzname):
    if not ZoneInfo:
        return None
    dt = None
    for fmt in ("%b %d at %I:%M%p", "%b %d at %I%p"):
        try:
            dt = datetime.strptime(when.strip(), fmt)
            break
        except Exception:
            dt = None
    if dt is None:
        return None
    try:
        tz = ZoneInfo(tzname)
    except Exception:
        return None
    yr = datetime.now(tz).year
    dt = dt.replace(year=yr, tzinfo=tz)
    ep = dt.timestamp()
    if ep < now - 86400:                       # wrapped a year boundary
        ep = dt.replace(year=yr + 1).timestamp()
    return int(ep)


out = {"updated_at": int(now)}

# "<label>: 44% used · resets Jul 2 at 7:39pm (America/Los_Angeles)" — the reset clause is
# optional (parsed only when present) so a percentage still lands even if the format shifts.
RESET = r"(?:[^\n]*?resets\s+([A-Za-z]+ \d+ at [\d:]+[apmAPM]+)\s*\(([^)]+)\))?"


def grab(label, key):
    m = re.search(label + r":\s*(\d+)%\s*used" + RESET, txt)
    if not m:
        return
    out[key + "_pct"] = int(m.group(1))
    if m.group(2) and m.group(3):
        ep = reset_epoch(m.group(2), m.group(3))
        if ep:
            out[key + "_resets_at"] = ep


grab(r"Current session", "session")
grab(r"Current week \(all models\)", "week")

# The per-model weekly line ("Current week (Fable): 16% used") names whichever model the
# account's extra-usage window tracks; capture its label so the app can show it verbatim.
mm = re.search(r"Current week \((?!all models\))([^)]+)\):\s*(\d+)%\s*used", txt)
if mm:
    out["week_model_label"] = mm.group(1)
    out["week_model_pct"] = int(mm.group(2))

if "session_pct" in out:
    sys.stdout.write(json.dumps(out))
else:
    sys.exit(1)
