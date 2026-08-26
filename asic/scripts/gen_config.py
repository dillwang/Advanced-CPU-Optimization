#!/usr/bin/env python3
"""
gen_config.py -- write a LibreLane (or OpenLane) config for one module of the
flattened core.

The flattened Verilog is one file holding every module. What differs between
designs is DESIGN_NAME, whether the module has a clock, which modules below it
it still needs the source of, and which of them have already been hardened into
macros. All of that is read out of the Verilog rather than hardcoded, so adding
a module to the RTL does not mean editing a list here.

Hierarchical runs are the point of --macro. Naming a child as a macro cuts it
and everything under it out of this design's source, and declares it instead as
a placed black box with its own GDS, LEF and timing. That is what keeps the
parent's placement and routing problem bounded.
"""

import argparse
import glob
import json
import os
import re
import sys

SRAM_MACRO = "sky130_sram_1kbyte_1rw1r_32x256_8"


def parse_modules(path):
    """name -> (full source text, body after the header)."""
    src = open(path, encoding="utf-8", errors="replace").read()
    # Strip comments first so a commented-out instantiation cannot be mistaken
    # for a real one.
    src = re.sub(r"/\*.*?\*/", " ", src, flags=re.S)
    src = re.sub(r"//[^\n]*", " ", src)
    out = {}
    for m in re.finditer(r"^[ \t]*module\s+(\w+)\b(.*?)^[ \t]*endmodule",
                         src, flags=re.S | re.M):
        out[m.group(1)] = (m.group(0), m.group(2))
    return out


def parse_module_files(paths):
    """(module -> (source, body), module -> file, files with no module in them).

    The last one matters: mips_core_pkg.sv, memory_interfaces.sv and
    mips_core_interfaces.sv hold a package and interfaces, no modules at all.
    They define what everything else is built out of, so they always go in the
    file list, in their original order.
    """
    mods, owner, support = {}, {}, []
    for path in paths:
        src = open(path, encoding="utf-8", errors="replace").read()
        src = re.sub(r"/\*.*?\*/", " ", src, flags=re.S)
        src = re.sub(r"//[^\n]*", " ", src)
        found = False
        for m in re.finditer(r"^[ \t]*module\s+(\w+)\b(.*?)^[ \t]*endmodule",
                             src, flags=re.S | re.M):
            mods[m.group(1)] = (m.group(0), m.group(2))
            owner[m.group(1)] = path
            found = True
        if not found:
            support.append(path)
    return mods, owner, support


def module_bodies(path):
    """Backwards-compatible view: name -> body. Used by gen_floorplan."""
    return {k: v[1] for k, v in parse_modules(path).items()}


def port_names(body):
    """Names in the module header's port list."""
    return set(re.findall(r"\w+", body.split(";", 1)[0]))


def instantiates(body, child):
    """True if `body` instantiates `child`.

    The trailing \\b matters: without it a wire called sram_data reads as an
    instantiation of sram.
    """
    return re.search(r"\b%s\b\s*(#\s*\(|\w+\s*\()" % re.escape(child), body) is not None


def children(name, mods):
    body = mods[name][1]
    return [c for c in mods if c != name and instantiates(body, c)]


def subtree(name, mods, cut):
    """Modules whose source `name` still needs, stopping at every name in `cut`.

    `name` itself is included; anything in `cut` is not, and neither is
    anything only reachable through it -- that is the whole point of hardening
    a child, its contents stop being this design's problem.
    """
    need, stack = set(), [name]
    while stack:
        n = stack.pop()
        if n in need or n in cut or n not in mods:
            continue
        need.add(n)
        stack.extend(children(n, mods))
    return need


def reaches_sram(names, mods):
    return any(instantiates(mods[n][1], "sram") for n in names)


def pdk_sram_paths(pdk_root, pdk):
    base = os.path.join(pdk_root, pdk, "libs.ref", "sky130_sram_macros")
    got = {}
    for kind, sub, ext in (("gds", "gds", "gds"), ("lef", "lef", "lef"),
                           ("lib", "lib", "lib"), ("nl", "verilog", "v")):
        d = os.path.join(base, sub)
        if not os.path.isdir(d):
            continue
        for f in sorted(os.listdir(d)):
            if f.startswith(SRAM_MACRO) and f.endswith("." + ext):
                got.setdefault(kind, os.path.join(d, f))
    return got


def hardened_views(name, results_dir):
    """The views a previously hardened block leaves behind, as a MACROS entry.

    LibreLane will take a .lib if the run produced one; failing that, a
    gate-level netlist plus per-corner SPEF is the more accurate option and the
    one it documents. Either is enough to synthesise and time against.
    """
    def one(*parts):
        hits = sorted(glob.glob(os.path.join(results_dir, *parts)))
        return [os.path.abspath(h) for h in hits]

    gds = one("%s.gds" % name) or one("gds", "%s.gds" % name)
    lef = one("%s.lef" % name) or one("lef", "%s.lef" % name)
    if not gds or not lef:
        sys.exit("gen_config: %s has no GDS/LEF under %s -- harden it before "
                 "the design that uses it as a macro" % (name, results_dir))

    entry = {"gds": gds, "lef": lef, "instances": {}}

    libs = one("lib", "*", "*.lib") or one("lib", "*.lib") or one("*.lib")
    if libs:
        by_corner = {}
        for p in libs:
            corner = os.path.basename(os.path.dirname(p))
            by_corner.setdefault(corner if corner != "lib" else "*", []).append(p)
        entry["lib"] = by_corner
    else:
        nl = one("%s.nl.v" % name) or one("nl", "%s.nl.v" % name)
        spefs = one("spef", "*", "*.spef") or one("spef", "*.spef")
        if not nl or not spefs:
            sys.exit("gen_config: %s has neither a .lib nor netlist+SPEF under "
                     "%s; nothing to time it with" % (name, results_dir))
        entry["nl"] = nl
        by_corner = {}
        for p in spefs:
            corner = os.path.basename(os.path.dirname(p))
            by_corner.setdefault(corner if corner != "spef" else "*", []).append(p)
        entry["spef"] = by_corner
    return entry


def probe_mods(mods):
    """One line per module: clocked, reaches an SRAM, how much state it holds."""
    print("    %-24s %6s %6s  %-5s  %s"
          % ("MODULE", "LINES", "PORTS", "CLOCK", "NOTE"))
    for name in sorted(mods):
        # `sram` is the black box the macro binds to, not something to harden.
        # It only appears at all because this parse does not evaluate `ifdef,
        # and cache_bank.sv carries a simulation model of it.
        if name == "sram":
            continue
        full, body = mods[name]
        ports = port_names(body)
        clock = "clk" if "clk" in ports else ("clk0" if "clk0" in ports else "-")
        kids = children(name, mods)
        note = []
        if reaches_sram(subtree(name, mods, set()), mods):
            note.append("needs SRAM macros")
        if kids:
            note.append("holds " + ", ".join(sorted(kids)))
        print("    %-24s %6d %6d  %-5s  %s"
              % (name, full.count("\n") + 1, len(ports), clock, "; ".join(note)))


def main():
    p = argparse.ArgumentParser()
    p.add_argument("module", nargs="?")
    p.add_argument("--probe", action="store_true",
                   help="describe every module in the file and exit")
    p.add_argument("--verilog", default="",
                   help="the sv2v-flattened Verilog (sv2v frontend)")
    p.add_argument("--sv-file", action="append", default=[],
                   help="a SystemVerilog source, in compile order (slang "
                        "frontend). Repeatable; replaces --verilog.")
    p.add_argument("--include-dir", action="append", default=[],
                   help="`include search path for the slang frontend")
    p.add_argument("--sram-verilog", default="")
    p.add_argument("--macro", action="append", default=[], metavar="NAME=DIR",
                   help="a child already hardened; cut it out of the source and "
                        "declare it as a placed macro from DIR. Repeatable.")
    p.add_argument("--rtl-out", default="",
                   help="where to write this design's trimmed Verilog "
                        "(default: alongside --out)")
    p.add_argument("--out", default="")
    p.add_argument("--period", type=float, default=10.0)
    p.add_argument("--util", type=float, default=40.0)
    p.add_argument("--density", type=float, default=0.0, help="0 = derive from util")
    p.add_argument("--pdk-root", default="")
    p.add_argument("--pdk", default="sky130A")
    p.add_argument("--flow", choices=["librelane", "openlane1"], default="librelane")
    p.add_argument("--max-layer", default="",
                   help="RT_MAX_LAYER. Leave empty for the PDK default (met5 on "
                        "sky130A). A block destined to be a macro must leave the "
                        "top layer free for its parent to route over.")
    p.add_argument("--clock-gate", type=int, default=0, metavar="N",
                   help="SYNTH_CLOCKGATE_MIN_WIDTH: gate any enabled flop group "
                        "of at least N bits. 0 leaves it off.")
    p.add_argument("--hierarchy-mode", default="",
                   choices=["", "flatten", "deferred_flatten", "keep"],
                   help="SYNTH_HIERARCHY_MODE. Empty leaves LibreLane's default, "
                        "which is already 'flatten'.")
    p.add_argument("--keep-hierarchy", action="append", default=[], metavar="MOD",
                   help="keep this module's boundary through a flattened "
                        "synthesis, so its area is still attributable. Repeatable.")
    p.add_argument("--extra", default="", help="JSON object merged in last")
    a = p.parse_args()

    # Two frontends. sv2v lowers everything to one Verilog-2005 file and
    # inlines any module with an interface port into its parent. LibreLane's
    # Slang frontend reads the SystemVerilog directly and keeps every module,
    # which is both less work and a better hierarchy to cut.
    slang = bool(a.sv_file)
    if not slang and not a.verilog:
        sys.exit("gen_config: need --verilog or --sv-file")

    if slang:
        mods, owner, support = parse_module_files(a.sv_file)
        src_desc = "%d SystemVerilog files" % len(a.sv_file)
    else:
        mods, owner, support = parse_modules(a.verilog), {}, []
        src_desc = a.verilog

    if a.probe:
        probe_mods(mods)
        return
    if not a.module or not a.out:
        sys.exit("gen_config: need a module name and --out (or --probe)")

    if a.module not in mods:
        sys.exit("gen_config: no module %r in %s (have: %s)"
                 % (a.module, src_desc, ", ".join(sorted(mods))))

    cut = {}
    for spec in a.macro:
        if "=" not in spec:
            sys.exit("gen_config: --macro wants NAME=DIR, got %r" % spec)
        n, d = spec.split("=", 1)
        if n not in mods:
            sys.exit("gen_config: --macro names %r, which is not a module here" % n)
        cut[n] = d

    need = subtree(a.module, mods, set(cut))
    used_macros = {n: d for n, d in cut.items()
                   if any(instantiates(mods[m][1], n) for m in need)}

    if slang:
        # Hand LibreLane the sources themselves. Keep the original order --
        # the package and the interfaces must compile before anything that
        # imports them -- and keep every file that holds no module at all,
        # because that is exactly what those support files are. Files whose
        # only modules were cut out are dropped, which is what stops the parent
        # re-elaborating a subtree it is placing as a macro.
        files, seen = [], set()
        for f in a.sv_file:
            if f in seen:
                continue
            if f in support or any(owner.get(n) == f for n in need):
                seen.add(f)
                files.append(os.path.abspath(f))
    else:
        # Write just the modules this design still needs. Handing LibreLane the
        # whole flattened file would re-elaborate the very subtrees we hardened.
        rtl = a.rtl_out or os.path.join(os.path.dirname(os.path.abspath(a.out)),
                                        "rtl.v")
        with open(rtl, "w", encoding="utf-8") as f:
            f.write("// generated by gen_config.py -- %s and what it still needs\n"
                    % a.module)
            for n in sorted(need):
                f.write("\n" + mods[n][0] + "\n")
        files = [os.path.abspath(rtl)]
    needs_sram = reaches_sram(need, mods)
    if needs_sram:
        if not a.sram_verilog:
            sys.exit("gen_config: %s reaches an SRAM but --sram-verilog was not "
                     "given" % a.module)
        files.append(os.path.abspath(a.sram_verilog))

    ports = port_names(mods[a.module][1])
    clock = "clk" if "clk" in ports else ("clk0" if "clk0" in ports else None)

    if a.flow == "librelane":
        cfg = {
            "DESIGN_NAME": a.module,
            "VERILOG_FILES": files,
            "CLOCK_PORT": clock,
            "CLOCK_PERIOD": a.period,
            "FP_SIZING": "relative",
            "FP_CORE_UTIL": a.util,
            "PL_TARGET_DENSITY_PCT": a.density or min(a.util + 10.0, 85.0),
            # Verilator would lint every module in the trimmed file, not just
            # the one being built, and most of them are not this design's
            # problem. Lint the RTL with the simulator instead.
            "RUN_LINTER": False,
            # Congestion is NOT allowed on the first attempt, deliberately.
            # These blocks are wall-to-wall flops and global routing may well
            # complain -- but that complaint is the most useful signal the flow
            # produces about whether the die is big enough, and suppressing it
            # by default throws it away. rtl2gds.sh --repair turns it on for the
            # retries, once you have seen the first answer.
            "meta": {"version": 2},
        }
        if slang:
            # SIMULATION stays undefined here too, which is what drops the DPI
            # imports of stats_event and the $display blocks -- the same thing
            # leaving it out of the sv2v invocation does.
            cfg["USE_SLANG"] = True
            if a.include_dir:
                cfg["VERILOG_INCLUDE_DIRS"] = [os.path.abspath(d)
                                               for d in a.include_dir]
        if clock is None:
            # Purely combinational: no clock to constrain, and the default SDC
            # would try to create one on a port that is not there.
            cfg.pop("CLOCK_PERIOD")
    else:
        cfg = {
            "DESIGN_NAME": a.module,
            "VERILOG_FILES": files,
            "CLOCK_PORT": clock or "",
            "CLOCK_PERIOD": a.period,
            "FP_SIZING": "relative",
            "FP_CORE_UTIL": a.util,
            "PL_TARGET_DENSITY": (a.density or min(a.util + 10.0, 85.0)) / 100.0,
            "DESIGN_IS_CORE": True,
        }

    macros = {}
    if needs_sram:
        if not a.pdk_root:
            sys.exit("gen_config: %s needs SRAM macros, so --pdk-root is required"
                     % a.module)
        sram = pdk_sram_paths(a.pdk_root, a.pdk)
        missing = [k for k in ("gds", "lef", "lib") if k not in sram]
        if missing:
            sys.exit("gen_config: %s not found in %s (missing %s). This PDK build "
                     "does not ship the OpenRAM macros."
                     % (SRAM_MACRO, a.pdk_root, ", ".join(missing)))
        if a.flow == "librelane":
            # instances stay empty here; gen_floorplan.py fills them on the
            # second pass, once synthesis has named them.
            macros[SRAM_MACRO] = {
                "gds": [sram["gds"]],
                "lef": [sram["lef"]],
                "lib": {"*": [sram["lib"]]},
                "instances": {},
            }
            if "nl" in sram:
                macros[SRAM_MACRO]["nl"] = [sram["nl"]]
        else:
            cfg["EXTRA_GDS_FILES"] = sram["gds"]
            cfg["EXTRA_LEFS"] = sram["lef"]
            cfg["EXTRA_LIBS"] = sram["lib"]

    for n, d in sorted(used_macros.items()):
        if a.flow != "librelane":
            sys.exit("gen_config: hierarchical macros need LibreLane; OpenLane 1 "
                     "cannot take %s as a placed block here" % n)
        macros[n] = hardened_views(n, d)

    if macros:
        cfg["MACROS"] = macros

    if a.flow == "librelane":
        # RT_MAX_LAYER is a PDK variable, so leaving it alone means met5 on
        # sky130A -- every layer available. That is right for a top level and
        # wrong for a block that is going to be placed inside one: the parent
        # needs a layer it can route over the macro on, and the PDN wants met5
        # for its straps. Hence met4 for children, set by the caller.
        if a.max_layer:
            cfg["RT_MAX_LAYER"] = a.max_layer
        if a.clock_gate:
            # ~742,000 flops in this design, most of them predictor tables that
            # are written rarely. Gating them is the one lever that changes the
            # power number by an order of magnitude rather than a few per cent.
            cfg["SYNTH_CLOCKGATE_MIN_WIDTH"] = a.clock_gate
        if a.hierarchy_mode:
            cfg["SYNTH_HIERARCHY_MODE"] = a.hierarchy_mode
        if a.keep_hierarchy:
            cfg["SYNTH_KEEP_HIERARCHY_MODULES"] = a.keep_hierarchy

    if a.extra:
        cfg.update(json.loads(a.extra))

    with open(a.out, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2)
        f.write("\n")

    print("%s: clock=%s modules=%d sram=%s macros=%s"
          % (a.module, clock or "(none)", len(need), "yes" if needs_sram else "no",
             ",".join(sorted(used_macros)) or "none"))


if __name__ == "__main__":
    main()
