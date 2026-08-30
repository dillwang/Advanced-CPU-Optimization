#!/usr/bin/env python3
"""
mixed_assign.py -- find variables written both `=` and `<=` inside one
procedural block, using slang's own parse tree.

yosys-slang refuses this ("non-blocking assignment to variable 'x' is not
supported after previous blocking assignment") while plain slang and Verilator
both accept it, so it is invisible to every other check in this flow and it
kills a run at step 5 of 80.

The regex version of this check (`slang_lint.py`) was wrong five times running:
nested bracket indices, DPI prototypes that open a scope and never close it,
non-ANSI port lists, assignments split across two lines, and assignments sitting
inside `if (...)` on the same statement. Each time it reported zero findings and
the real tool disagreed. Parsing SystemVerilog with regexes is a losing game, so
this one asks the parser.

    pip install pyslang
    python mixed_assign.py <file.sv> ...

Reports nothing about which variables *should* be blocking -- a blocking-only
temporary inside an `always_ff` is legal and yosys-slang accepts it. Only the
mixture is a problem.
"""

import argparse
import sys

try:
    import pyslang
    from pyslang import syntax
except ImportError:
    sys.exit("mixed_assign: needs pyslang (pip install pyslang).\n"
             "     Without it, scripts/slang_lint.py covers this case less well.")

BLOCK_KINDS = {
    syntax.SyntaxKind.AlwaysBlock,
    syntax.SyntaxKind.AlwaysFFBlock,
    syntax.SyntaxKind.AlwaysCombBlock,
    syntax.SyntaxKind.AlwaysLatchBlock,
}


def base_name(node):
    """The variable an lvalue ultimately writes.

    `tg_ctr[t][i][w]`, `rob[ci].valid` and a bare `x` all resolve to the
    leftmost identifier, which is the granularity yosys-slang complains at.
    """
    while True:
        kids = [node[i] for i in range(len(node)) if node[i] is not None]
        named = [k for k in kids if getattr(k, "kind", None) in
                 (syntax.SyntaxKind.IdentifierName, syntax.SyntaxKind.IdentifierSelectName)]
        if named:
            node = named[0]
            if node.kind == syntax.SyntaxKind.IdentifierName:
                return str(node).strip()
            continue
        text = str(node).strip()
        # Fall back to the leading identifier of the printed form.
        out = []
        for ch in text:
            if ch.isalnum() or ch == "_":
                out.append(ch)
            else:
                break
        return "".join(out) or None


def walk(node, fn):
    if node is None:
        return
    fn(node)
    try:
        n = len(node)
    except TypeError:
        return
    for i in range(n):
        try:
            child = node[i]
        except Exception:
            continue
        if child is not None and hasattr(child, "kind"):
            walk(child, fn)


def scan(path):
    """[(variable, blocking_line, nonblocking_line)] for one file."""
    tree = syntax.SyntaxTree.fromFile(path)
    if tree is None:
        return []
    sm = tree.sourceManager
    findings = []

    def line_of(node):
        try:
            return sm.getLineNumber(node.sourceRange.start)
        except Exception:
            return 0

    def do_block(block):
        blocking, nonblocking = {}, {}

        def visit(n):
            k = getattr(n, "kind", None)
            if k == syntax.SyntaxKind.AssignmentExpression:
                name = base_name(n)
                if name:
                    blocking.setdefault(name, line_of(n))
            elif k == syntax.SyntaxKind.NonblockingAssignmentExpression:
                name = base_name(n)
                if name:
                    nonblocking.setdefault(name, line_of(n))

        walk(block, visit)
        for name in sorted(set(blocking) & set(nonblocking)):
            findings.append((name, blocking[name], nonblocking[name],
                             line_of(block)))

    def find_blocks(n):
        if getattr(n, "kind", None) in BLOCK_KINDS:
            do_block(n)

    walk(tree.root, find_blocks)
    return findings


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="+")
    a = ap.parse_args()

    total = 0
    for path in a.files:
        try:
            found = scan(path)
        except Exception as e:
            print("%s: could not parse (%s)" % (path, e))
            continue
        for name, b, nb, blk in found:
            total += 1
            print("%s:%d: '%s' written blocking here and nonblocking on line "
                  "%d, in the procedural block at line %d" % (path, b, name, nb, blk))
    print("\n%d finding(s)" % total)
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
