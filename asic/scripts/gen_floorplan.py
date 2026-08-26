#!/usr/bin/env python3
"""
gen_floorplan.py -- build an explicit floorplan for a design that contains macros.

LibreLane will place standard cells on its own, but it will not invent a
location for a hard macro: every instance needs coordinates. Those instances do
not exist until synthesis has run and flattened the hierarchy, so this reads
them back out of the synthesised netlist, reads each macro's real dimensions and
power pin names out of its LEF rather than assuming them, and emits the config
fragment that pins the second pass.

It handles a mix of macro sizes, because a hierarchical run has them: 54 SRAMs
of one shape next to a hardened tage_m1 that is a different shape entirely. The
placement is shelf packing -- macros sorted tall-first into rows across the top,
standard cells given the rest. That is not a clever floorplan; a real one would
put each cache's banks next to the logic that reads them. It is a legal one that
routes, and it is a starting point to argue with.
"""

import argparse
import json
import math
import os
import re
import sys


def lef_macro_info(lef_path, macro):
    """(width, height, power pin names, ground pin names) from a macro's LEF."""
    txt = open(lef_path, encoding="utf-8", errors="replace").read()
    m = re.search(r"MACRO\s+%s\b(.*?)END\s+%s\b" % (re.escape(macro), re.escape(macro)),
                  txt, flags=re.S)
    if not m:
        sys.exit("gen_floorplan: no MACRO %s in %s" % (macro, lef_path))
    block = m.group(1)
    s = re.search(r"SIZE\s+([\d.]+)\s+BY\s+([\d.]+)\s*;", block)
    if not s:
        sys.exit("gen_floorplan: no SIZE for %s in %s" % (macro, lef_path))

    # Take the power and ground pin names from the LEF rather than guessing:
    # the OpenRAM macros use vccd1/vssd1, a block hardened by LibreLane in
    # sky130 uses VPWR/VGND, and getting it wrong silently leaves a macro
    # unconnected to the grid.
    power, ground = [], []
    for pin, pbody in re.findall(r"\bPIN\s+(\S+)\b(.*?)END\s+\1\b", block, flags=re.S):
        use = re.search(r"\bUSE\s+(\w+)\s*;", pbody)
        if not use:
            continue
        if use.group(1).upper() == "POWER":
            power.append(pin)
        elif use.group(1).upper() == "GROUND":
            ground.append(pin)
    return float(s.group(1)), float(s.group(2)), power, ground


def macro_instances(netlist_text, macro):
    """Instance names of `macro` in a Yosys-written netlist.

    Yosys escapes hierarchical names, writing `\\D_CACHE.databank[0].CORE ` with
    a leading backslash and a trailing space. OpenDB knows them without the
    backslash, so strip it.
    """
    names = []
    for m in re.finditer(r"\b%s\s+(\\\S+|\w+)\s*\(" % re.escape(macro), netlist_text):
        n = m.group(1)
        names.append(n[1:] if n.startswith("\\") else n)
    return names


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--netlist", required=True)
    p.add_argument("--config", required=True,
                   help="the pass-1 config.json, read for its MACROS entries")
    p.add_argument("--metrics", default="")
    p.add_argument("--util", type=float, default=40.0)
    p.add_argument("--halo", type=float, default=30.0,
                   help="um between macros, for routing channels and PDN straps")
    p.add_argument("--margin", type=float, default=20.0, help="um die to core")
    p.add_argument("--out", required=True)
    a = p.parse_args()

    cfg = json.load(open(a.config))
    declared = cfg.get("MACROS") or {}
    if not declared:
        sys.exit("gen_floorplan: %s declares no MACROS; nothing to place" % a.config)

    txt = open(a.netlist, encoding="utf-8", errors="replace").read()
    txt = re.sub(r"/\*.*?\*/", " ", txt, flags=re.S)
    txt = re.sub(r"//[^\n]*", " ", txt)

    # Collect every instance of every declared macro, with its size.
    items, info = [], {}
    for name, entry in declared.items():
        lefs = entry.get("lef") or []
        if not lefs:
            sys.exit("gen_floorplan: macro %s has no LEF in %s" % (name, a.config))
        w = h = None
        for lef in lefs:
            try:
                w, h, pwr, gnd = lef_macro_info(lef, name)
                break
            except SystemExit:
                continue
        if w is None:
            sys.exit("gen_floorplan: no LEF in %s describes MACRO %s"
                     % (", ".join(lefs), name))
        insts = macro_instances(txt, name)
        if not insts:
            print("gen_floorplan: %s is declared but not instantiated; skipping"
                  % name, file=sys.stderr)
            continue
        info[name] = (w, h, pwr, gnd)
        for i in insts:
            items.append((h, w, name, i))

    if not items:
        sys.exit("gen_floorplan: none of the declared macros appear in %s -- did "
                 "synthesis really bind them?" % a.netlist)

    # Standard cell area, from synthesis. Without it, guess something that will
    # be obviously wrong rather than silently tight.
    cell_area = 0.0
    if a.metrics and os.path.isfile(a.metrics):
        m = json.load(open(a.metrics))
        # final/metrics.json is the metrics dict itself; a step's state_out.json
        # wraps it under "metrics".
        m = m.get("metrics", m)
        cell_area = float(m.get("design__instance__area") or 0.0)
    if cell_area <= 0:
        cell_area = 5.0e6
        print("gen_floorplan: no cell area in metrics, assuming %.1f mm^2"
              % (cell_area / 1e6), file=sys.stderr)

    # Shelf packing, tall macros first, into a band whose width is chosen to
    # keep that band roughly square.
    macro_area = sum(w * h for h, w, _, _ in items)
    widest = max(w for _, w, _, _ in items)
    band_target_w = max(widest + a.halo, math.sqrt(macro_area) * 1.2)

    items.sort(key=lambda t: (-t[0], -t[1]))
    shelves, cur, cur_w, cur_h = [], [], 0.0, 0.0
    for h, w, name, inst in items:
        if cur and cur_w + w + a.halo > band_target_w:
            shelves.append((cur, cur_h))
            cur, cur_w, cur_h = [], 0.0, 0.0
        cur.append((h, w, name, inst))
        cur_w += w + a.halo
        cur_h = max(cur_h, h)
    if cur:
        shelves.append((cur, cur_h))

    band_w = max(sum(w + a.halo for _, w, _, _ in s) + a.halo for s, _ in shelves)
    band_h = sum(sh + a.halo for _, sh in shelves) + a.halo

    std_area = cell_area / (a.util / 100.0)
    die_w = math.ceil(max(band_w, math.sqrt(std_area)) + 2 * a.margin)
    std_h = std_area / max(die_w - 2 * a.margin, 1.0)
    die_h = math.ceil(band_h + std_h + 2 * a.margin)

    # Lay the shelves out from the top down, so the standard cells get the
    # bottom of the die in one contiguous piece.
    placement = {n: {} for n in info}
    pdn = []
    y = die_h - a.margin - a.halo
    for shelf, shelf_h in shelves:
        y -= shelf_h
        x = a.margin + a.halo
        for _, w, name, inst in shelf:
            placement[name][inst] = {"location": [round(x, 3), round(y, 3)],
                                     "orientation": "N"}
            pwr, gnd = info[name][2], info[name][3]
            if pwr and gnd:
                pdn.append("%s %s %s %s %s" % (inst, pwr[0], gnd[0], pwr[0], gnd[0]))
            x += w + a.halo
        y -= a.halo

    macros = {}
    for name, entry in declared.items():
        if name not in info:
            continue
        e = dict(entry)
        e["instances"] = placement[name]
        macros[name] = e

    out = {
        "FP_SIZING": "absolute",
        "DIE_AREA": "0 0 %d %d" % (die_w, die_h),
        "CORE_AREA": "%g %g %g %g" % (a.margin, a.margin,
                                      die_w - a.margin, die_h - a.margin),
        "MACROS": macros,
        "PDN_MACRO_CONNECTIONS": pdn,
        # The die is explicit now, so utilisation is already spent -- let the
        # placer spread into what is left rather than chase the synthesis number.
        "PL_TARGET_DENSITY_PCT": round(min(a.util + 5.0, 70.0), 1),
        "RUN_LINTER": False,
    }

    with open(a.out, "w", encoding="utf-8") as f:
        json.dump(out, f, indent=2)
        f.write("\n")

    for name, (w, h, pwr, gnd) in sorted(info.items()):
        print("gen_floorplan: %3d x %-40s %7.1f x %-7.1f um  power %s/%s"
              % (len(placement[name]), name, w, h,
                 pwr[0] if pwr else "?", gnd[0] if gnd else "?"))
    print("gen_floorplan: macro band %.0f x %.0f um in %d shelves, standard "
          "cells %.2f mm^2 at %.0f%%" % (band_w, band_h, len(shelves),
                                         cell_area / 1e6, a.util))
    print("gen_floorplan: die %d x %d um = %.2f mm^2 -> %s"
          % (die_w, die_h, die_w * die_h / 1e6, a.out))


if __name__ == "__main__":
    main()
