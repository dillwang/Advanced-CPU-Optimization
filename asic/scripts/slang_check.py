#!/usr/bin/env python3
"""
slang_check.py -- run the real Slang front end locally, before nanoHUB.

LibreLane reads SystemVerilog with Slang, and when Slang refuses, the run dies
in step 5 of 80 -- possibly an hour into a core run, certainly a round trip away
from anyone who can fix it. Slang is on PyPI as `pyslang`, so the same
elaboration can be done here in about a second per design:

    pip install pyslang
    ./rtl2gds.sh check            # or: python scripts/slang_check.py --all

What makes this worth more than a lint is that it is not an approximation. The
file list is the one gen_config.py hands LibreLane, in the same order, with the
same include path and the same defines -- so an elaboration that passes here is
the elaboration that will run there.

`scripts/slang_lint.py` stays useful when pyslang is not installed: it needs
nothing but Python, and it catches the two failures that actually happened. But
if this runs, believe this one.
"""

import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import gen_config  # noqa: E402  -- same file selection the flow uses


def files_for(top, sv_files, mods, owner, support, ifcs, sram_verilog):
    """Exactly the file list gen_config hands LibreLane for this design, plus
    the macro wrapper when the design reaches the generic `sram`. Sharing the
    one function is the point: a check against a different file list is a check
    of something other than what will run."""
    need = gen_config.subtree(top, mods, set())
    out = gen_config.slang_files(sv_files, need, mods, owner, support, ifcs)
    if sram_verilog and gen_config.reaches_sram(need, mods):
        out.append(os.path.abspath(sram_verilog))
    return out


def elaborate(top, files, include_dirs, defines):
    """(ok, diagnostics) for one design. A fresh Driver each time -- Slang's
    state is per-compilation, and a stale one reports the previous design."""
    from pyslang import driver

    d = driver.Driver()
    d.addStandardArgs()
    args = ["slang", "--top", top]
    for inc in include_dirs:
        args += ["-I", os.path.abspath(inc)]
    for define in defines:
        args += ["-D", define]
    args += files

    def quote(a):
        return '"%s"' % a if (" " in a or "\\" in a) else a

    if not d.parseCommandLine(" ".join(quote(a) for a in args)):
        return False, d.textDiagClient.getString()
    if not d.processOptions():
        return False, d.textDiagClient.getString()
    if not d.parseAllSources():
        return False, d.textDiagClient.getString()
    comp = d.createCompilation()
    ok = d.reportCompilation(comp, True)
    text = d.textDiagClient.getString()
    # reportCompilation returns None in some builds, so fall back to reading
    # the diagnostics: an error line is an error whatever the return value.
    if ok is None:
        ok = "error:" not in text
    return bool(ok), text


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--sv-file", action="append", default=[], metavar="FILE",
                   help="a SystemVerilog source, in compile order. Repeatable")
    p.add_argument("--include-dir", action="append", default=[], metavar="DIR")
    p.add_argument("--sram-verilog", default="", metavar="FILE",
                   help="stands in for the generic `sram` in any design that "
                        "reaches it, the way the flow substitutes the macro")
    p.add_argument("--pdk-root", default="", metavar="DIR",
                   help="a PDK, for the SRAM macro's own Verilog view. Without "
                        "one, a reference to a macro is treated as satisfied "
                        "rather than reported: the PDK on the target supplies "
                        "it, and its absence here is not a defect in the RTL")
    p.add_argument("--pdk", default="sky130A")
    p.add_argument("--define", action="append", default=[], metavar="NAME[=V]",
                   help="a `define. SIMULATION is deliberately NOT set here, "
                        "matching the flow")
    p.add_argument("--top", action="append", default=[], metavar="MOD",
                   help="check this design. Repeatable. Default: every module")
    p.add_argument("--all", action="store_true",
                   help="check every module, including ones that cannot be a "
                        "top-level design")
    p.add_argument("-q", "--quiet", action="store_true",
                   help="one line per design, no diagnostics")
    a = p.parse_args()

    if not a.sv_file:
        sys.exit("slang_check: no sources; pass --sv-file")
    try:
        import pyslang  # noqa: F401
    except ImportError:
        sys.exit("slang_check: pyslang is not installed.\n"
                 "     pip install pyslang\n"
                 "     (or use scripts/slang_lint.py, which needs nothing)")

    mods, owner, support = gen_config.parse_module_files(a.sv_file)
    ifcs = gen_config.parse_interface_files(a.sv_file)
    tops = a.top or sorted(n for n in mods if n != "sram")

    # The macro's own Verilog view lives in the PDK. With no PDK here, a
    # reference to it is not something the RTL could fix, so do not report it --
    # but say once that it went unchecked, rather than quietly hiding it.
    macro_files = []
    if a.pdk_root:
        macro_files = gen_config.pdk_sram_paths(a.pdk_root, a.pdk) or []
    assumed = set()
    macro_re = re.compile(r"unknown module '(sky130_sram\w*)'")

    bad = []
    for top in tops:
        if top not in mods:
            print("  ?? %-24s not a module in these sources" % top)
            continue
        files = files_for(top, a.sv_file, mods, owner, support, ifcs,
                          a.sram_verilog)
        ok, text = elaborate(top, files + macro_files, a.include_dir, a.define)
        errs = [l for l in text.split("\n") if ": error:" in l]
        if not macro_files:
            keep = []
            for line in errs:
                m = macro_re.search(line)
                if m:
                    assumed.add(m.group(1))
                else:
                    keep.append(line)
            errs, ok = keep, (ok or not keep)
        if ok:
            print("  ok %-24s %d file(s)" % (top, len(files)))
            continue
        bad.append(top)
        # An interface port is not a defect, it is a fact about the module:
        # nothing can bind an interface when the module is the top. Say so,
        # rather than making it look like something to fix.
        iface = [l for l in errs if "unconnected interface port" in l]
        if iface and len(errs) == len(iface):
            print("  -- %-24s cannot be a top-level design: %d interface port(s)"
                  % (top, len(iface)))
            continue
        print(" ERR %-24s %d error(s)" % (top, len(errs)))
        if not a.quiet:
            for line in errs[:6]:
                print("       %s" % line.strip()[:110])

    if assumed:
        print("\nassumed present, supplied by the PDK on the target: %s"
              % ", ".join(sorted(assumed)))
    print("\n%d of %d design(s) elaborate" % (len(tops) - len(bad), len(tops)))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
