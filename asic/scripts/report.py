#!/usr/bin/env python3
"""
report.py -- digest a LibreLane run into the few hundred bytes worth reading.

A Classic flow run is ~80 steps and tens of megabytes of tool output. Almost
none of it matters. What matters is: which step you are on or died at, which
steps are eating the wall clock, the handful of metrics that moved, and the
errors -- and all four are recoverable from the run directory without reading
a single tool log end to end.

Every step writes state_out.json holding its metrics, so the interesting view is
the *diff*: what each step changed. That is where a run tells you something you
did not already know.
"""

import argparse
import json
import os
import re
import sys
import time

# The metrics worth watching, in the order a person cares about them.
WATCH = [
    ("design__instance__count",        "cells",       "{:,.0f}"),
    ("design__instance__area",         "area um2",    "{:,.0f}"),
    ("design__instance__utilization",  "util",        "{:.3f}"),
    ("design__die__area",              "die um2",     "{:,.0f}"),
    ("timing__setup__ws",              "setup WNS",   "{:+.3f}"),
    ("timing__hold__ws",               "hold WNS",    "{:+.3f}"),
    ("timing__setup__tns",             "setup TNS",   "{:+.1f}"),
    ("route__wirelength",              "wirelength",  "{:,.0f}"),
    ("route__antenna_violation__count", "antenna",    "{:,.0f}"),
    ("magic__drc_error__count",        "magic DRC",   "{:,.0f}"),
    ("klayout__drc_error__count",      "klayout DRC", "{:,.0f}"),
    ("design__lvs_error__count",       "LVS",         "{:,.0f}"),
    ("design__max_slew_violation__count", "max slew", "{:,.0f}"),
    ("design__max_cap_violation__count",  "max cap",  "{:,.0f}"),
]


def newest_run(design_dir):
    runs = os.path.join(design_dir, "runs")
    if not os.path.isdir(runs):
        return None
    cand = [os.path.join(runs, d) for d in os.listdir(runs)]
    cand = [c for c in cand if os.path.isdir(c)]
    return max(cand, key=os.path.getmtime) if cand else None


def step_dirs(run):
    """Step directories in flow order. LibreLane prefixes them with an index."""
    out = []
    for d in sorted(os.listdir(run)):
        full = os.path.join(run, d)
        if not os.path.isdir(full):
            continue
        m = re.match(r"^(\d+)[-.](.+)$", d)
        if m:
            out.append((int(m.group(1)), m.group(2), full))
    out.sort()
    return out


def metrics_of(step_dir):
    for name in ("state_out.json", "metrics.json"):
        p = os.path.join(step_dir, name)
        if os.path.isfile(p):
            try:
                d = json.load(open(p))
            except Exception:
                continue
            return d.get("metrics", d) or {}
    return {}


def fmt(spec, v):
    try:
        return spec.format(float(v))
    except Exception:
        return str(v)


def log_problems(step_dir, limit=3):
    """Lines from this step's logs that look like a real complaint."""
    hits = []
    for f in sorted(os.listdir(step_dir)):
        if not f.endswith(".log"):
            continue
        try:
            for line in open(os.path.join(step_dir, f), errors="replace"):
                if re.search(r"^\s*(\[ERROR\]|ERROR:|Error:|FATAL|fatal:)", line):
                    s = line.strip()
                    if s not in hits:
                        hits.append(s)
                    if len(hits) >= limit:
                        return hits
        except Exception:
            pass
    return hits


def main():
    p = argparse.ArgumentParser()
    p.add_argument("design_dir", help="the design directory, holding runs/")
    p.add_argument("--run", default="", help="a specific run (default: newest)")
    p.add_argument("--all-steps", action="store_true",
                   help="list every step, not just the ones that changed something")
    a = p.parse_args()

    run = a.run or newest_run(a.design_dir)
    if not run or not os.path.isdir(run):
        sys.exit("report: no run directory under %s" % a.design_dir)

    steps = step_dirs(run)
    if not steps:
        sys.exit("report: %s holds no step directories yet" % run)

    print("run: %s" % run)
    print("%d steps so far, last touched %s\n"
          % (len(steps), time.strftime("%H:%M:%S",
                                       time.localtime(os.path.getmtime(steps[-1][2])))))

    # Wall clock per step, from when each directory was last written. Crude,
    # but it is the only timing the run records without a tool log parse, and
    # it is enough to find the step that is eating the afternoon.
    times = [os.path.getmtime(d) for _, _, d in steps]
    start = os.path.getmtime(run)
    durs = []
    prev = start
    for t in times:
        durs.append(max(t - prev, 0.0))
        prev = t

    print("%-4s %-38s %9s  %s" % ("#", "STEP", "SECONDS", "CHANGED"))
    print("-" * 96)
    prev_m = {}
    for (idx, name, d), dur in zip(steps, durs):
        m = metrics_of(d)
        changed = []
        for key, label, spec in WATCH:
            if key in m and m[key] != prev_m.get(key):
                changed.append("%s %s" % (label, fmt(spec, m[key])))
        if m:
            prev_m.update(m)
        if not (changed or a.all_steps or dur > 30):
            continue
        print("%-4d %-38s %9.1f  %s" % (idx, name[:38], dur,
                                        ", ".join(changed[:4])))
        for line in log_problems(d):
            print("     ! %s" % line[:110])

    print()
    final = os.path.join(run, "final", "metrics.json")
    m = json.load(open(final)) if os.path.isfile(final) else prev_m
    m = m.get("metrics", m)
    if m:
        print("final:")
        for key, label, spec in WATCH:
            if key in m and m[key] is not None:
                print("    %-14s %s" % (label, fmt(spec, m[key])))

    slowest = sorted(zip(steps, durs), key=lambda x: -x[1])[:3]
    print("\nslowest steps:")
    for (idx, name, _), dur in slowest:
        print("    %6.1fs  %s" % (dur, name))


if __name__ == "__main__":
    main()
