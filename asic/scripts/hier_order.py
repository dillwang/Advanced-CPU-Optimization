#!/usr/bin/env python3
"""
hier_order.py -- print the order to harden a design and its hardened children.

A block has to exist as a macro before anything above it can place it, so the
order is a topological sort of the instantiation graph restricted to the modules
being cut out, with the top last. Reading it from the Verilog rather than a
hardcoded list means it stays right when the RTL changes.
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_config import parse_modules, parse_module_files, children  # noqa: E402


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--verilog", default="")
    p.add_argument("--sv-file", action="append", default=[])
    p.add_argument("--top", default="mips_core")
    p.add_argument("cuts", nargs="*",
                   help="modules to harden separately and hand upward as macros")
    a = p.parse_args()

    if a.sv_file:
        mods, _, _ = parse_module_files(a.sv_file)
    elif a.verilog:
        mods = parse_modules(a.verilog)
    else:
        sys.exit("hier_order: need --verilog or --sv-file")
    if a.top not in mods:
        sys.exit("hier_order: no module %r" % a.top)

    unknown = [c for c in a.cuts if c not in mods]
    if unknown:
        sys.exit("hier_order: not modules here: %s" % ", ".join(unknown))

    wanted = set(a.cuts)
    order, seen = [], set()

    def visit(n):
        if n in seen:
            return
        seen.add(n)
        for c in children(n, mods):
            if c in wanted:
                visit(c)
        order.append(n)

    # Deepest cut first, then everything that depends on it, then the top.
    for c in sorted(wanted):
        visit(c)
    visit(a.top)

    # A cut that the top never reaches is not an error, just useless -- say so
    # rather than silently hardening something nothing will place.
    reach, stack = set(), [a.top]
    while stack:
        n = stack.pop()
        if n in reach or n not in mods:
            continue
        reach.add(n)
        stack.extend(children(n, mods))
    for c in sorted(wanted - reach):
        print("hier_order: %s is not instantiated under %s" % (c, a.top),
              file=sys.stderr)

    print(" ".join(n for n in order if n in reach))


if __name__ == "__main__":
    main()
