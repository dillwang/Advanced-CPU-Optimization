#!/usr/bin/env python3
"""
pdk_report.py -- what a bit of storage actually costs in this PDK.

Moving a table from flip-flops to SRAM is worth doing only if SRAM is denser,
and in sky130 that is much less obvious than it sounds: the open OpenRAM macros
carry heavy peripheral overhead, and a high-density DFF is small. Rather than
quote a number from memory, this measures both out of the installed PDK -- macro
SIZE from the LEF, flop SIZE from the standard cell LEF -- and prints um^2 per
bit for each.

Read the last column. If a macro is not comfortably below the flop row once you
allow for placement density, converting a table to SRAM buys area only through
the routing it removes, and costs a port-arbitration rewrite to get it.
"""

import argparse
import glob
import os
import re
import sys


def lef_sizes(path):
    """name -> (w, h) for every MACRO in a LEF."""
    txt = open(path, encoding="utf-8", errors="replace").read()
    out = {}
    for m in re.finditer(r"MACRO\s+(\S+)\b(.*?)END\s+\1\b", txt, flags=re.S):
        s = re.search(r"SIZE\s+([\d.]+)\s+BY\s+([\d.]+)\s*;", m.group(2))
        if s:
            out[m.group(1)] = (float(s.group(1)), float(s.group(2)))
    return out


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--pdk-root", required=True)
    p.add_argument("--pdk", default="sky130A")
    p.add_argument("--scl", default="sky130_fd_sc_hd")
    p.add_argument("--flop", default="",
                   help="flop cell to compare against (default: the smallest "
                        "dfxtp/dfrtp in the library)")
    p.add_argument("--util", type=float, default=40.0,
                   help="utilisation to charge the flop row at, since flops need "
                        "placement density and a macro does not")
    a = p.parse_args()

    root = os.path.join(a.pdk_root, a.pdk)
    if not os.path.isdir(root):
        sys.exit("pdk_report: no %s" % root)

    rows = []

    # --- standard cell flop -------------------------------------------------
    scl_lefs = glob.glob(os.path.join(root, "libs.ref", a.scl, "lef", "*.lef"))
    cells = {}
    for f in scl_lefs:
        cells.update(lef_sizes(f))
    if not cells:
        sys.exit("pdk_report: no standard cell LEF under %s"
                 % os.path.join(root, "libs.ref", a.scl, "lef"))

    if a.flop:
        flops = {a.flop: cells[a.flop]} if a.flop in cells else {}
        if not flops:
            sys.exit("pdk_report: no cell %r in %s" % (a.flop, a.scl))
    else:
        flops = {n: s for n, s in cells.items()
                 if re.search(r"__df[rsx]?[a-z]*tp?_\d", n)}
        if not flops:
            flops = {n: s for n, s in cells.items() if "__df" in n}
    name, (fw, fh) = min(flops.items(), key=lambda kv: kv[1][0] * kv[1][1])
    farea = fw * fh
    rows.append((name, 1, farea, farea, farea / (a.util / 100.0)))

    # --- SRAM macros --------------------------------------------------------
    for d in sorted(glob.glob(os.path.join(root, "libs.ref", "*sram*", "lef", "*.lef"))):
        for n, (w, h) in sorted(lef_sizes(d).items()):
            m = re.search(r"_(\d+)x(\d+)_", n)
            if not m:
                continue
            bits = int(m.group(1)) * int(m.group(2))
            rows.append((n, bits, w * h, w * h / bits, w * h / bits))

    w0 = max(len(r[0]) for r in rows)
    print("%-*s  %9s  %12s  %10s  %10s" % (w0, "CELL / MACRO", "BITS",
                                           "AREA um^2", "um^2/bit",
                                           "at %g%% util" % a.util))
    print("-" * (w0 + 50))
    for n, bits, area, per, eff in rows:
        print("%-*s  %9d  %12.1f  %10.3f  %10.3f" % (w0, n, bits, area, per, eff))

    best = min((r for r in rows[1:]), key=lambda r: r[4], default=None)
    if best:
        ratio = rows[0][4] / best[4]
        print()
        print("Densest macro is %s at %.3f um^2/bit, against %.3f for a %s "
              "placed at %g%%." % (best[0], best[4], rows[0][4], rows[0][0], a.util))
        print("That is %.2fx. %s" % (
            ratio,
            "Worth converting a table to SRAM if you can arbitrate the ports."
            if ratio >= 1.5 else
            "Not much: the win from converting a table would come from the "
            "routing it removes, not the bits."))


if __name__ == "__main__":
    main()
