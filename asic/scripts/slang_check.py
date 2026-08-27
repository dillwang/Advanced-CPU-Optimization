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
import shutil
import subprocess
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


def slang_argv(top, files, include_dirs, defines):
    """The command line, shared by both backends so they cannot drift."""
    args = ["--top", top]
    for inc in include_dirs:
        args += ["-I", os.path.abspath(inc)]
    for define in defines:
        args += ["-D", define]
    return args + files


def elaborate_binary(binary, top, files, include_dirs, defines):
    """(ok, diagnostics) from a `slang` executable.

    nanoHUB has no pip, so pyslang cannot be installed there -- but the
    LibreLane install ships Slang itself, because that is what USE_SLANG runs.
    If it is on PATH inside the devshell, it answers the same question.
    """
    p = subprocess.run([binary] + slang_argv(top, files, include_dirs, defines),
                       capture_output=True, text=True)
    return p.returncode == 0, (p.stdout or "") + (p.stderr or "")


def elaborate(top, files, include_dirs, defines):
    """(ok, diagnostics) for one design. A fresh Driver each time -- Slang's
    state is per-compilation, and a stale one reports the previous design."""
    from pyslang import driver

    d = driver.Driver()
    d.addStandardArgs()
    args = ["slang"] + slang_argv(top, files, include_dirs, defines)

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
    p.add_argument("--slang-bin", default="", metavar="PATH",
                   help="a slang executable, for machines where pyslang cannot "
                        "be installed. Autodetected on PATH")
    p.add_argument("-q", "--quiet", action="store_true",
                   help="one line per design, no diagnostics")
    a = p.parse_args()

    if not a.sv_file:
        sys.exit("slang_check: no sources; pass --sv-file")
    # pyslang where pip exists; a slang executable where it does not. nanoHUB
    # is the second case, and it ships Slang anyway -- that is what USE_SLANG
    # runs. Either backend answers the same question from the same argv.
    binary = a.slang_bin
    try:
        if binary:
            raise ImportError          # an explicit --slang-bin wins
        import pyslang  # noqa: F401
    except ImportError:
        binary = binary or shutil.which("slang") or ""
        if not binary:
            sys.exit("slang_check: no Slang here -- neither the pyslang module\n"
                     "     nor a slang executable on PATH.\n"
                     "     Where pip exists:  pip install pyslang\n"
                     "     Where it does not: run this check before you get\n"
                     "     here, or use scripts/slang_lint.py, which needs\n"
                     "     nothing but Python.")

    def run(top, files):
        if binary:
            return elaborate_binary(binary, top, files, a.include_dir, a.define)
        return elaborate(top, files, a.include_dir, a.define)

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
        ok, text = run(top, files + macro_files)
        errs = [l for l in text.split("\n") if ": error:" in l]
        if not macro_files and errs:
            keep = []
            for line in errs:
                m = macro_re.search(line)
                if m:
                    assumed.add(m.group(1))
                else:
                    keep.append(line)
            # A failure is only forgiven when EVERY error it reported was a
            # reference to a macro the PDK will supply. `ok or not keep` was
            # wrong: it turned "failed, and we could not parse why" into "ok",
            # which is the one answer a checker must never give.
            if errs and not keep:
                ok = True
            errs = keep
        if not ok and not errs:
            # Failed with nothing we recognised. Say so and show the tail --
            # silence here is indistinguishable from success.
            bad.append(top)
            print(" ERR %-24s failed with no error line we could parse:" % top)
            for line in [l for l in text.strip().split("\n") if l.strip()][-4:]:
                print("       %s" % line.strip()[:110])
            continue
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
