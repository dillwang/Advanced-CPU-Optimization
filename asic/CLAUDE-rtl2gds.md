# RTL-to-GDS on nanoHUB — operational rules

Drop this into a repo as `CLAUDE.md`, or append it to an existing one, so it
loads every session. Companion to `PLAYBOOK.md`: that one explains, this one
decides. When they disagree, this one wins.

## CHECK LOCALLY BEFORE PROPOSING ANY REMOTE RUN

Three checks, cost order, each catches what the others cannot. Run all three.
Do this BEFORE asking for a shell, not after.

```bash
pip install pyslang                         # LOCAL box. nanoHUB has NO pip.
./rtl2gds.sh check                          # ~1 s/design. What SYNTHESIS refuses.
verilator --lint-only <same args as build>  # ~3 s.      What the SIMULATOR refuses.
make verilate && ./obj_dir/V<top> -b <bench>  # ~10 min.  Whether it is still CORRECT.
```

Slang and Verilator are not alternatives. Slang is a front end and enforces the
language; Verilator is a simulator and tells you the answer is still right. A
design passes one and fails the other in both directions — this one did, on the
same line. Never substitute one for the other; never skip the third after a
semantic change.

The first two cost ~13 seconds together and catch every class of failure that
otherwise arrives one remote round trip at a time.

**pip does not exist on nanoHUB.** Run the check where you edit the RTL and
arrive with the findings fixed. If a check is needed remotely anyway: the
LibreLane install ships Slang (that is what `USE_SLANG` runs), so drive a
`slang` executable off `PATH` with the same argv; else fall back to the regex
lint. Never emit `pip install` as advice on a machine without pip.

## HARD RULES

1. Get a working shell BEFORE writing any flow code. Prove it: `librelane --version` exits 0.
2. Never trust a tool you located until you have run it. `--version` or equivalent. Locating ≠ usable.
3. Default to `USE_SLANG: true`. Do not reach for sv2v.
4. Never `git pull` while a run is in progress in that checkout.
5. Never hardcode a macro's dimensions or power pin names. Read both from its LEF.
6. Never set `GRT_ALLOW_CONGESTION: true` by default. Escalation only.
7. Any design containing a macro needs two passes: synthesise → read instance names → floorplan → full run.
8. Hierarchical children build one routing layer below the top (met4 vs met5 on sky130A).
9. Do not read tool logs to find status. Read `runs/<tag>/<NN>-<step>/state_out.json` and diff metrics.
10. Verify config variable names against the installed LibreLane source. Do not recall them.
11. A module with an interface port CANNOT be a top-level design. Check which modules are interface-free BEFORE planning per-module runs.
12. Never report success from a file's existence. `--to <step>` writes `state_out.json` for steps that ran before the failure. Gate on a metric only the wanted step produces.
13. Append every failure's cause to one `errors.log` as it happens, and roll them up at the end.
14. `pip install pyslang` and run the real front end LOCALLY before any remote run. Build the check on the SAME file list the config generator emits — share the function, never re-derive it.
15. Select source files by what they DEFINE (modules, interfaces, packages, transitively), never by "files with no module in them". Interfaces hide in files that also hold modules.
16. Never trust a checker you have not seen fail. Point it at a known-bad input first. Silence from a broken checker and silence from a clean design are the same output.
16b. A tool that exited non-zero has FAILED. Never let "we could not parse an error line" upgrade that to success — report it and print the raw tail. This exact bug shipped here and was caught only because a test stub was accidentally broken.
17. Fix every front-end finding in ONE pass. The front end reports the whole design; one local invocation gives the entire list.

## ERROR SIGNATURES → CAUSE → FIX

| you see | it means | do |
| --- | --- | --- |
| `ModuleNotFoundError: No module named 'click'` (from a librelane that imports) | you are outside the bwrap namespace; deps live at `/nix/store` paths that do not exist on the host | `mkdir -p ~/LIBRELANE/.nix-librelane` then `<install>/start`, run from inside |
| `bwrap: Can't find source path .../LIBRELANE/.nix-librelane` | the empty root the wrapper binds as `/` does not exist | `mkdir -p ~/LIBRELANE/.nix-librelane` |
| `No module named 'importlib.metadata'` | Python < 3.8 (nanoHUB `/usr/bin/python3` is 3.6) | use the interpreter the Nix install ships, not the system one |
| `sv2v: /lib64/libc.so.6: version 'GLIBC_2.34' not found` | published sv2v needs glibc 2.29–2.34; Rocky 8 has 2.28 | stop using sv2v; `USE_SLANG: true` |
| `Can't resolve task name '\<name>'` | a DPI call site is unguarded while its import is inside `` `ifdef SIMULATION `` | guard the `always` block in the RTL; it is an RTL bug |
| `no module '<name>'` from your own script after discovery succeeded | your module lookup reads an sv2v artifact that the Slang path never creates | make module discovery frontend-aware |
| a step reports an unknown config key | version skew between your keys and the installed LibreLane | grep that version's source for the key |
| `top-level module 'X' has unconnected interface port 'y'` | X's ports are SystemVerilog interfaces; nothing binds them when X is top. Not a bug — no front end can do this | do not harden X alone. Use `SYNTH_KEEP_HIERARCHY_MODULES` on its parent to get its area |
| `<sig> used before its declaration` / `note: declared here` below the use | Slang enforces declare-before-use; Verilator does not | move the declaration above the first reference. Pure reordering |
| `cannot mix blocking and nonblocking assignments` | one variable written `=` in the reset branch and `<=` elsewhere in the same `always_ff` | make them agree. Re-run the simulation: it should be cycle-identical |
| `BLKLOOPINIT: Unsupported: Delayed assignment to array inside for loops` (Verilator, right after fixing the above) | Verilator refuses `<=` to an unpacked array element in a loop it cannot unroll, which is what the Slang fix produces. The two tools contradict each other on that line | neither form: clear the whole table at once, `tbl <= '{default: '0};`. Only loops past `--unroll-count` need it |
| `unroll limit of 4000 exhausted [--unroll-limit=]` | **yosys-slang**, not slang. A reset loop over a table with more iterations than that | whole-array assignment (zero iterations). Do NOT just raise the limit — unrolling 24k statements is what made one elaboration run 16 h without finishing |
| `non-blocking assignment to variable 'X' is not supported after previous blocking assignment` | yosys-slang refusing what plain slang tolerates | same whole-array clear; it fixes the unroll limit and this together |
| `Item is incompatible with the array type` / `CONST is not an unpacked array, but is in an unpacked array context` | Verilator applies `'{default:}` only ONE level deep, and the array has more dimensions | nest one `'{default:}` per unpacked dimension: 3-D wants `'{default: '{default: '{default: X}}}` |
| ABC `return code 137` (often with `The network is combinational`) | 128+9 = SIGKILL. The OOM killer took ABC; the message is noise printed on the way down | lower `-j`. Peak memory is per concurrent design and ABC is the peak |
| a design fails with exit 1 and NO error line in any log | a killed process prints nothing | same as above; and make the failure recorder print a log tail rather than an empty cause |
| `unknown interface 'X'` when hardening a module that does not use module Y | X is defined inside Y's file; a file-selection rule keyed on modules drops it | include a file when it defines an interface the design names, not only when it owns a needed module |
| every design reports ok but each log ends in `ERROR` | success was inferred from a file that a truncated run also writes | gate on a metric, not a path |
| flow and PDK from different install trees | six versions coexist under `/apps/share64/*/librelane/` | match them; `$PDK_ROOT` says which the environment intends |

## CANONICAL COMMANDS

```bash
# LOCAL, before any of the below
pip install pyslang && ./rtl2gds.sh check

# session, first time
mkdir -p ~/LIBRELANE/.nix-librelane
/apps/share64/rocky8/librelane/librelane-3.0.4/start

# git: OUTSIDE the devshell only
exit; cd <repo> && git pull; <install>/start

# long run: background, keep the shell open (exiting kills the namespace)
./flow.sh ... > ~/run.log 2>&1 &
tail -f ~/run.log
```

## CONFIG KEYS (verified against LibreLane source, re-verify per version)

```
USE_SLANG SLANG_ARGUMENTS VERILOG_FILES VERILOG_INCLUDE_DIRS VERILOG_DEFINES
SYNTH_HIERARCHY_MODE(flatten|deferred_flatten|keep, default flatten)
SYNTH_KEEP_HIERARCHY_MODULES SYNTH_CLOCKGATE_MIN_WIDTH(off by default)
RT_MIN_LAYER RT_MAX_LAYER            # PDK vars; sky130A default met5
FP_SIZING(relative|absolute) FP_CORE_UTIL PL_TARGET_DENSITY_PCT
DIE_AREA CORE_AREA MACROS PDN_MACRO_CONNECTIONS
DRT_OPT_ITERS DRT_ANTENNA_REPAIR_ITERS GRT_ALLOW_CONGESTION
FP_PDN_VPITCH FP_PDN_HPITCH RUN_LINTER
ERROR_ON_MAGIC_DRC ERROR_ON_KLAYOUT_DRC ERROR_ON_KLAYOUT_ANTENNA
```

Step IDs: `Yosys.Synthesis` `OpenROAD.Floorplan` `Odb.ManualMacroPlacement`
`Odb.SetPowerConnections` `OpenROAD.GeneratePDN` `OpenROAD.GlobalPlacement`
`OpenROAD.CTS` `OpenROAD.GlobalRouting` `OpenROAD.DetailedRouting`
`OpenROAD.RCX` `OpenROAD.STAPostPNR` `OpenROAD.IRDropReport` `Magic.DRC`
`KLayout.DRC` `KLayout.XOR` `Netgen.LVS` `Yosys.EQY`

Resume: `--last-run`, `--from <step>`, `--to <step>`, `--skip <step>`.
`--to Yosys.Synthesis` still walks all ~80 steps skipping the rest, and still
writes `final/`. Normal.

## FACTS THAT CONTRADICT INTUITION

- OpenROAD has **no post-detailed-route optimisation**. Every resizer runs
  before `DetailedRouting`. There is no `optDesign -postroute -drv -inc`.
  A repair loop = re-run with a loosened constraint, not an incremental ECO.
- sv2v **inlines any module with an interface port into its parent**. It
  destroys your hierarchical cut points. Slang does not — but a module with an
  interface port still cannot be a top-level design under either. Surviving the
  frontend and being hardenable alone are different properties. On one real
  core, 9 of 21 modules were unhardenable this way, including both caches, the
  LSQ and the OoO backend.
- The area table for those comes from **one** run of the top with
  `SYNTH_KEEP_HIERARCHY_MODULES` set, not from N per-module runs. Cheaper, and
  it works for blocks that cannot stand alone.
- **Verilator is not a conformance checker.** A design that simulates cleanly
  can still be rejected by Slang: declare-before-use and mixed blocking/
  nonblocking assignment are both errors there and silent in Verilator.
- sky130 SRAM beats flops by ~**2.9×** per bit, not 10×. OpenRAM carries heavy
  peripheral overhead. Measure: macro `SIZE` from LEF, flop `SIZE` from the SCL
  LEF. Reference: `dfxtp_1` 20.0 µm²/bit (50.0 at 40% util),
  `sram_2kbyte_32x512` 17.4, `sram_1kbyte_32x256` 23.3.
- A multi-ported register file **cannot** be SRAM. Async read alone rules it
  out. Measured: a 128×32 PRF with 8 async reads + 5 writes was 581,694 µm², of
  which the flops were 87,123 (15%) — the mux network is 85%.
- **`pyslang` is NOT `yosys-slang`.** LibreLane runs the Yosys frontend, which
  refuses things plain slang accepts: loops past `--unroll-limit` (4000), and
  any nonblocking assignment to a variable already written blocking. A design
  can pass `./rtl2gds.sh check` clean and still die at step 5. The local check
  covers conformance and elaboration; the regex lint covers mixed assignment;
  nothing local covers the unroll limit.
- Slang requires `<=` where a variable is written nonblocking elsewhere in the
  same `always_ff`; Verilator then rejects `<=` to an unpacked array element in
  a loop it cannot unroll. **The two tools contradict each other on that exact
  line.** The resolution is neither form: a whole-array assignment.
- **Reset a table with one whole-array assignment, always — not a loop.** It
  satisfies Verilator's BLKLOOPINIT, yosys-slang's unroll limit and the
  mixed-assignment rule at once, and it is the only form that scales. Nest one
  `'{default:}` per unpacked dimension.
- A regex over SystemVerilog must allow **nested** bracket groups:
  `g_tab[b][f_gi[b]]`. `\[[^\]]*\]` silently misses every multidimensional
  table, which is exactly where the interesting bugs are.
- A regex checker over SystemVerilog goes SILENT, not loud, when it is wrong.
  Specific ways: a DPI prototype (`import "DPI-C" function ...;`) opens a scope
  that never closes and freezes a depth counter; a non-ANSI port list names
  signals before declaring them and that is legal; a `for (int i ...)` variable
  shadows a module-level signal of the same name.
- `$PDK_ROOT` being exported does **not** mean you are in a shell that can run
  the flow.
- The directory at the front of `PATH` named after the tool may hold only
  session launchers.

## BASH TRAPS

- `set -e` is disabled inside a function called from a `||` list. Check status
  explicitly, `return 1`.
- `local a="$1" b="$dir/$a"` — `$a` is unset until the statement ends. Split.
- `"${arr[@]}"` on an empty array errors under `set -u` in bash < 4.4. Use
  `${arr[@]+"${arr[@]}"}`.
- `grep -oP` fails on some locales. Use `sed` + BRE.
- A DPI prototype (`import "DPI-C" function void f(...);`) names a function and
  never closes one. Any begin/end or function/endfunction depth counter that
  does not skip `import`/`export` lines gets stuck and silently passes
  everything below.
- Adding a fourth guessed path? Stop and `find` instead.
- Authoring on Windows: commit `.gitattributes` with `*.sh text eol=lf`, or the
  shebang arrives as `^M` and Linux reports `bad interpreter`.
- Probe interpreters by running them; `command -v python3` can find a stub.

## ORDER OF WORK (each step gates the next)

```
LOCAL -- no remote session needed, do these first
1. slang elaborate every design  -> which modules can be a top at all. seconds.
2. verilator --lint-only         -> what the simulator refuses. 3 s.
3. fix ALL findings in one pass  -> then full sim; must be cycle-identical
4. parse RTL, list modules       -> no tools needed

REMOTE
5. working shell                 -> librelane --version exits 0
6. measure the PDK               -> um^2/bit per macro and per flop
7. synth-only, SMALLEST          -> proves config keys. minutes.
8. synth-only, TOP + SYNTH_KEEP_HIERARCHY_MODULES for every block you want a
                                    number for -> the whole area table in ONE
                                    run, including blocks that cannot be a top
9. full flow, one small block    -> proves P&R and signoff
10. big runs
```

Step 8 replaces "synth-only, everything". N per-module runs is worse than one
kept-hierarchy run, not just slower: the per-module runs cannot cover a module
with an interface port, and their numbers are out of context.

Do not skip 1-3, and do not skip 7-8. Each is the difference between a
five-second answer and a five-hour one.
