#!/usr/bin/env python3
"""
slang_lint.py -- find, before a synthesis run, the two things Slang rejects and
Verilator does not.

Slang enforces SystemVerilog rules that Verilator waves through, and each one
kills a whole design at step 5 of 80 with a single error line. Finding them one
per run costs a round trip each. This finds them all at once:

  use-before-declaration  a signal referenced above the line that declares it
  mixed assignment        one variable written = in one place and <= in another
                          inside the same always block

Both are approximations -- this is a regex pass, not an elaborator -- so it errs
toward reporting. Every hit is worth a look; not every hit is a defect, and
nothing here replaces running the real front end.
"""

import argparse
import re
import sys

# Types a module-level signal can be declared with. The typedef'd ones are
# collected from the sources themselves; these are the built-ins.
BUILTIN_TYPES = {
    "logic", "wire", "reg", "bit", "byte", "int", "integer", "shortint",
    "longint", "time", "real", "shortreal", "genvar", "event",
}

# One bracket group, allowing a nested one inside it: [b], [f_gi[b]], [3:0].
BRACKET = r"\[(?:[^\[\]]|\[[^\[\]]*\])*\]"

KEYWORDS = {
    "begin", "end", "if", "else", "for", "while", "case", "casex", "casez",
    "endcase", "always", "always_ff", "always_comb", "always_latch", "assign",
    "module", "endmodule", "function", "endfunction", "task", "endtask",
    "generate", "endgenerate", "input", "output", "inout", "posedge",
    "negedge", "or", "and", "not", "return", "break", "continue", "default",
    "parameter", "localparam", "typedef", "struct", "union", "enum", "packed",
    "signed", "unsigned", "automatic", "static", "const", "unique", "priority",
    "initial", "final", "assert", "package", "endpackage", "import", "export",
    "interface", "endinterface", "modport", "this", "super", "null", "void",
}


def strip_comments(text):
    """Blank out comments, keeping every line number where it was."""
    out = []
    in_block = False
    for line in text.split("\n"):
        if in_block:
            end = line.find("*/")
            if end < 0:
                out.append("")
                continue
            line = " " * (end + 2) + line[end + 2:]
            in_block = False
        line = re.sub(r"//.*$", "", line)
        while True:
            m = re.search(r"/\*", line)
            if not m:
                break
            end = line.find("*/", m.end())
            if end < 0:
                line = line[:m.start()]
                in_block = True
                break
            line = line[:m.start()] + " " * (end + 2 - m.start()) + line[end + 2:]
        out.append(line)
    return out


def collect_types(paths):
    """Every typedef'd type name in the sources, so a declaration that uses one
    is recognised as a declaration."""
    types = set(BUILTIN_TYPES)
    for p in paths:
        text = "\n".join(strip_comments(open(p, errors="replace").read()))
        for m in re.finditer(
                r"\btypedef\b[^;]*?\b([A-Za-z_]\w*)\s*(?:\[[^\]]*\])?\s*;",
                text, re.S):
            types.add(m.group(1))
    return types


def modules_of(lines):
    """(name, first_line, last_line) for every module in the file, 0-indexed."""
    out = []
    start = name = None
    for i, line in enumerate(lines):
        m = re.match(r"\s*module\s+([A-Za-z_]\w*)", line)
        if m and start is None:
            name, start = m.group(1), i
        elif re.match(r"\s*endmodule\b", line) and start is not None:
            out.append((name, start, i))
            start = name = None
    return out


def declarations(lines, lo, hi, types):
    """Module-level declarations: {name: line}. Skips anything inside a
    begin/end, a function or a task, since those are separately scoped."""
    decls = {}
    depth = 0
    in_sub = 0
    type_re = re.compile(
        r"^\s*(?:(?:const|static|automatic|var)\s+)?(" +
        "|".join(sorted(map(re.escape, types), key=len, reverse=True)) +
        r")\b(?:\s+(?:signed|unsigned))?\s*(?:\[[^\]]*\]\s*)*(.+?);\s*$")
    for i in range(lo, hi):
        line = lines[i]
        # A DPI prototype -- import "DPI-C" function void f(...); -- names a
        # function and never closes one. Counting it leaves the scope depth
        # stuck for the rest of the module, so every declaration below it is
        # skipped and the check silently passes.
        if re.match(r"\s*(import|export|extern)\b", line):
            continue
        if re.search(r"\b(function|task)\b", line) and not re.search(r"\bendf", line):
            in_sub += 1
        if re.search(r"\b(endfunction|endtask)\b", line):
            in_sub = max(0, in_sub - 1)
        if in_sub:
            continue
        opens = len(re.findall(r"\bbegin\b", line))
        closes = len(re.findall(r"\bend\b", line))
        if depth == 0:
            m = type_re.match(line)
            if m:
                for part in m.group(2).split(","):
                    part = re.sub(r"\[[^\]]*\]", "", part)
                    part = part.split("=")[0].strip()
                    n = re.match(r"^([A-Za-z_]\w*)$", part)
                    if n and n.group(1) not in KEYWORDS:
                        decls.setdefault(n.group(1), i)
        depth = max(depth + opens - closes, 0)
    return decls


def header_end(lines, lo, hi):
    """Line the module's port list closes on. Everything up to it is the
    header, where a name can legitimately appear before its declaration: a
    non-ANSI port list names its ports and declares them in the body."""
    depth = 0
    started = False
    for i in range(lo, hi):
        depth += lines[i].count("(") - lines[i].count(")")
        if depth > 0:
            started = True
        elif started and depth <= 0:
            return i
    return lo


def used_before(lines, lo, name, decl_line, types):
    """First line in [lo, decl_line) that references `name` as a signal.

    A leading dot is not enough to rule a reference out: `.name` at the head of
    a port connection IS a reference to a local signal, while `x.name` is a
    member access. The lookbehind rejects only the second.
    """
    word = re.compile(r"(?<![\w.$])" + re.escape(name) + r"\b")
    # `for (int s = 0; ...)` declares s in the loop's own scope; so does a DPI
    # prototype's argument list. Neither is a use of a module-level signal.
    as_decl = re.compile(r"\b(?:" + "|".join(sorted(map(re.escape, types))) +
                         r")\s+" + re.escape(name) + r"\b")
    for i in range(lo, decl_line):
        line = lines[i]
        if not word.search(line):
            continue
        # A non-ANSI port list gives the direction first and the type later, so
        # `output [7:0] x;` above `logic [7:0] x;` is legal and expected.
        if re.match(r"\s*(import|export|extern|input|output|inout)\b", line):
            continue
        if as_decl.search(line):
            continue
        return i
    return None


def loop_vars(lines, lo, hi):
    """Names declared in a for-header. They live in the loop's own scope, so a
    module-level declaration of the same name below is a different signal --
    and telling the two apart properly needs an elaborator, so skip them."""
    out = set()
    for i in range(lo, hi):
        for m in re.finditer(r"\bfor\s*\(\s*(?:\w+\s+)?([A-Za-z_]\w*)\s*=", lines[i]):
            out.add(m.group(1))
    return out


def mixed_assignments(lines, lo, hi):
    """Variables written both = and <= inside one always block."""
    out = []
    i = lo
    while i < hi:
        if not re.match(r"\s*always(_ff|_comb|_latch)?\b", lines[i]):
            i += 1
            continue
        start = i
        depth = 0
        seen_begin = False
        blocking, nonblocking = {}, {}
        while i < hi:
            line = lines[i]
            if re.findall(r"\bbegin\b", line):
                seen_begin = True
            depth += len(re.findall(r"\bbegin\b", line))
            depth -= len(re.findall(r"\bend\b", line))
            # An index can itself be an indexed expression -- g_tab[b][f_gi[b]]
            # -- so a bracket group has to allow one level of nesting. With
            # [^\]]* this missed every 2-D table in the design, which is
            # exactly where the mixed assignments were.
            m = re.match(r"\s*([A-Za-z_]\w*)\s*(?:" + BRACKET + r"|\.\w+)*\s*(<?=)(?!=)",
                         line)
            if m and m.group(1) not in KEYWORDS:
                (nonblocking if m.group(2) == "<=" else blocking)[m.group(1)] = i
            i += 1
            if seen_begin and depth <= 0:
                break
        for name in sorted(set(blocking) & set(nonblocking)):
            out.append((name, start, blocking[name], nonblocking[name]))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="+")
    ap.add_argument("--no-mixed", action="store_true",
                    help="skip the blocking/nonblocking check")
    a = ap.parse_args()

    types = collect_types(a.files)
    hits = 0
    for path in a.files:
        text = open(path, errors="replace").read()
        lines = strip_comments(text)
        raw = text.split("\n")
        for name, lo, hi in modules_of(lines):
            body = header_end(lines, lo, hi)
            loops = loop_vars(lines, lo, hi)
            for sig, dl in sorted(declarations(lines, lo, hi, types).items(),
                                  key=lambda kv: kv[1]):
                if sig == name or dl <= body or sig in loops:
                    continue
                u = used_before(lines, body, sig, dl, types)
                if u is not None:
                    hits += 1
                    print("%s:%d: '%s' used before its declaration on line %d "
                          "(module %s)" % (path, u + 1, sig, dl + 1, name))
                    print("      %s" % raw[u].strip()[:96])
            if a.no_mixed:
                continue
            for sig, blk, b, nb in mixed_assignments(lines, lo, hi):
                hits += 1
                print("%s:%d: '%s' written blocking here and nonblocking on "
                      "line %d, in the always block at line %d"
                      % (path, b + 1, sig, nb + 1, blk + 1))
    print("\n%d finding(s)" % hits)
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main())
