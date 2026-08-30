# RTL-to-GDS on nanoHUB: what to know before you start

Copy this file into a new repo and tell Claude Code to read it before building
an RTL-to-GDS flow. Everything here was paid for in round trips on a real
nanoHUB session; none of it is guessable from the outside, and several items
contradict what a reasonable person would assume.

There is a second file beside this one, `CLAUDE-rtl2gds.md`: the same knowledge
as rules, error signatures and commands rather than prose. Drop that one in as
`CLAUDE.md` so it loads every session; read this one when you want the why.

Read the whole thing first. Two items cost more than everything else combined,
and neither is the flow:

1. **Getting a shell that can run LibreLane at all** (§1).
2. **Not realising how much of the flow can be checked on your own machine**
   (§2). Slang is on PyPI; the front end that decides a run's first five minutes
   runs locally in about a second per design. Every hour lost to this project's
   worst day was spent discovering, one remote round trip at a time, things a
   thirteen-second local check reports all at once.

Do §2 before §1 if you have RTL in hand. It needs no remote session.

---

## 1. Getting a shell that can run LibreLane

**This is where the remote time goes.** Budget for it, and do it before writing
a line of the flow — but after the local checks in §2, which need no shell at
all and will change what you ask the flow to do.

nanoHUB runs LibreLane 3 inside **bubblewrap**, not as a command on `PATH`.
The entry point is a wrapper:

```
mkdir -p ~/LIBRELANE/.nix-librelane     # must exist first; nothing creates it
/apps/share64/rocky8/librelane/librelane-3.0.4/start
```

`start` binds `~/LIBRELANE/.nix-librelane` as `/`, re-binds every host
top-level directory inside it, and binds the install's own `nix` directory over
`/nix`. Outside that namespace the LibreLane package is findable and **useless**
— its dependencies resolve through `/nix/store` paths that only exist inside
the wrapper. The symptom is `ModuleNotFoundError: No module named 'click'` from
a package sitting in plain sight.

Do not try to fix that from outside. There is nothing to fix.

Five things that look like the entry point and are not:

| looks like | actually |
| --- | --- |
| `/apps/librelane/r8/bin` — first on `PATH` | `startCode`, `startLibrelane`, `startXterm`, `toolmenu`. Session launchers, no CLI. |
| `~/LIBRELANE` | the container's root filesystem |
| six trees under `/apps/share64/{rhel8,rocky8}/librelane/` | 2.4.6, 3.0.4, two 3.1.0 dev builds, a dated dev build. `$PDK_ROOT` says which one the environment intends |
| `/usr/bin/python3` | 3.6. `librelane/__version__.py` imports `importlib.metadata`, which needs 3.8. The Nix install ships its own interpreter |
| a downloaded `sv2v` | needs glibc 2.29–2.34; nanoHUB is Rocky 8 at 2.28. It downloads fine and will not link |

Once inside, `librelane` is a normal command and none of the above matters.

**`$PDK_ROOT` is already exported** even in a shell that cannot run the flow.
It points inside the intended install, so it is the best clue for locating
everything else — but its presence does *not* mean you are in a working shell.

**git does not work inside the devshell.** Pull outside, then re-enter.

**Never `git pull` while a run is in progress.** Bash reads a script
incrementally from a byte offset; rewriting it underneath a running invocation
makes it resume mid-line in the new file.

**Exiting the devshell kills any run in it** — the namespace goes with it, so
`disown` does not help. Background long runs and keep the shell open:

```
./flow.sh ... > ~/run.log 2>&1 &
tail -f ~/run.log
```

---

## 2. SystemVerilog: use the Slang frontend, not sv2v

If the design uses packages, interfaces, structs, or unpacked arrays of them,
Yosys's own Verilog frontend will not read it. The obvious move is sv2v. **Do
not start there.**

```json
{ "USE_SLANG": true,
  "VERILOG_FILES": ["...sv"],
  "VERILOG_INCLUDE_DIRS": ["path/holding/your/.svh"] }
```

LibreLane has a Slang frontend that reads SystemVerilog directly. Two reasons
it beats sv2v, beyond not needing a binary that will not run:

- **sv2v inlines any module with an interface port into its parent.** On one
  real design that collapsed 22 modules to 12 — `d_cache`, `i_cache`, `lsq`,
  `alu`, `decoder` and others all vanished into the top. Those are exactly the
  modules you want available as hierarchical cut points.
- Nothing to install, nothing to lower, no intermediate file to keep in sync.

Keep an sv2v path as a fallback for a LibreLane built without the plugin, but
default to Slang.

### Three checks, in cost order. Run all of them.

Slang and Verilator are not alternatives and neither replaces the other. Slang
is a **front end**: it elaborates and enforces the language. Verilator is a
**simulator**: it tells you whether the design still computes the right answer.
A design can pass one and fail the other in both directions, and this core did.

So the workflow is a ladder, cheapest first, and each rung catches a class the
one above it cannot see:

| | cost | catches |
| --- | --- | --- |
| `slang` (via pyslang) on each design | **~1 s each** | conformance, elaboration, missing modules and interfaces — but see the caveat below: this is *not* the same tool the flow runs |
| `verilator --lint-only` | **~3 s** | what the simulator will refuse: `BLKLOOPINIT`, `BLKANDNBLK`, width and case warnings |
| `verilate` + every benchmark | **~10 min** | whether it is still correct, and what it costs in cycles |

Only the third one is authoritative about behaviour, and nothing else can
substitute for it after a semantic change. But the first two are ~13 seconds
together and they caught every failure in this project's worst day.

**`pip install pyslang`.** Slang is on PyPI, so the elaboration LibreLane does
in step 5 of its 80 happens locally in about a second per design. Everything in
the next section was found on a remote machine, one failure per round trip,
before anyone asked whether the front end could be run here. It can.

**nanoHUB has no pip**, so this is a check you run *before you get there* — on
the machine you edit the RTL on. That is the right place for it anyway: the
point is to arrive with the findings already fixed. Two things soften the
absence if you do end up needing it remotely:

- The LibreLane install ships Slang itself — that is what `USE_SLANG` runs. If
  a `slang` executable is on `PATH` inside the devshell, drive that instead of
  the Python module; same arguments, same answer. Build the checker so either
  backend works from one argv.
- Failing that, the regex fallback needs nothing but Python.

Never print `pip install …` as advice on a machine that has no pip. It reads as
a fix and is a dead end.

**`verilator --lint-only` is the rung people skip.** It takes the same arguments
as the build, needs no C++ compilation, and finishes in three seconds against
ten minutes for a full `verilate`. The `BLKLOOPINIT` trap two sections down cost
a complete rebuild to discover and would have shown up here instantly.

Build the Slang check against **the same file list** the config generator
produces — share the function, do not re-derive it. A check of a different file
list is a check of something other than what will run, and it will disagree with
the real run in both directions.

Two things a local Slang check cannot see, and should report as unchecked
rather than fail on: macro Verilog views that live in the PDK, and anything
downstream of elaboration.

**And one it will get wrong.** LibreLane does not run slang; it runs
**yosys-slang**, the Yosys frontend, which refuses things plain slang accepts:

- a `for` loop of more than `--unroll-limit` iterations, default **4000**
- any nonblocking assignment to a variable already written blocking — which
  slang tolerates and Verilator ignores entirely

A design can come back clean from the local check and still die at step 5 on
both counts. That happened here after this section was first written. Treat the
pyslang check as "is the SystemVerilog well formed and does it elaborate",
which is most of what kills a run, and keep the regex lint for the
mixed-assignment class it cannot see.

### Reset a table with one assignment, never a loop

This is the single most useful RTL idiom in this document, and it took three
separate tool failures to arrive at:

```systemverilog
tg_ctr <= '{default: '{default: '{default: CTR_W'(4)}}};
```

One `'{default:}` per unpacked dimension. It satisfies all three constraints
that a loop cannot satisfy together:

| | a loop of `=` | a loop of `<=` | whole-array `'{default:}` |
| --- | --- | --- | --- |
| Verilator `BLKLOOPINIT` | ok | **fails** past `--unroll-count` | ok |
| yosys-slang mixed assignment | **fails** if written `<=` elsewhere | ok | ok |
| yosys-slang `--unroll-limit` | **fails** past 4000 | **fails** past 4000 | ok — zero iterations |

Two traps in the idiom itself:

- **Verilator applies `'{default:}` only one level deep.** A flat
  `'{default: '0}` on a 3-D array is rejected with *"CONST is not an unpacked
  array, but is in an unpacked array context"*. Match the nesting to the
  array's depth.
- **Do not fix the unroll error by raising `--unroll-limit`.** Unrolling 24,576
  reset statements is what made one elaboration run sixteen hours without
  finishing. The whole-array form unrolls to nothing.

### Validate the checker against a failure you already have

The regex fallback written for this project missed the exact bug that motivated
it. A DPI prototype —

```systemverilog
import "DPI-C" function void stats_event(input string e);
```

— names a function and never closes one, so a `function`/`endfunction` depth
counter incremented and never came back down. Every declaration below line 121
of that file was silently skipped, and the check passed a file with a real
defect in it.

The lesson generalises past this bug: **a checker that has never been shown
failing is not known to work.** Before trusting a new one, point it at a
known-bad input and confirm it says so. Silence from an unvalidated checker and
silence from a clean design are the same output.

### Slang is stricter than Verilator, and that is the point

Expect a design that has only ever been simulated to fail its first Slang run.
On one real core, three constructs that Verilator waves through were rejected:

- **use before declaration** — a signal referenced in a child's port list and
  declared twenty lines below it. Two instances. Pure reordering to fix.
- **mixing blocking and nonblocking assignments to one variable** inside a
  single `always_ff` — reset cleared a table with `=`, everything else wrote it
  with `<=`. Illegal SystemVerilog; Verilator does not care. There were 26 of
  these in one core, every one an array clear in a reset loop.

  **This one has a trap.** Verilator rejects a *nonblocking* assignment to an
  unpacked array element inside a `for` loop it cannot unroll (`BLKLOOPINIT`) —
  which is exactly what the fix produces. Slang demands `<=` on that line and
  Verilator refuses it. The way out is neither: clear the whole array in one
  aggregate assignment, `tbl <= '{default: '0};`, which both accept and which
  describes a reset better anyway. Only the tables past the unroll limit need
  it — four of the twenty-six here.
- **a top-level module with an interface port** — see below. Not a bug at all.

Budget a pass for these. They are cheap individually and each one blocks a whole
module, so they arrive all at once and look worse than they are.

Fix them **all at once**, not one per run — the front end reports every error in
the design, so one local invocation gives you the whole list. Three were found
one-per-round-trip before the local check existed; the remaining twenty-seven
took one pass afterwards.

Re-run the simulation when you are done: none of these fixes should change a
cycle, and if one does, it was not the fix you thought it was.

### A module with an interface port cannot be a top-level design

```
alu.sv:35:26: error: top-level module 'alu' has unconnected interface port 'in'
```

This is the one that reshapes the plan, so find it out early. If the design puts
interfaces on its module boundaries — and a modern SystemVerilog core usually
does — then a large fraction of its modules **cannot be pointed at as a
top-level design at all**, by any front end. sv2v hides this by inlining them
into the parent; Slang reports it. Same capability lost either way.

On one core it was 9 of 21 modules, including both caches, the load/store queue
and the out-of-order backend.

**The fix is not per-module runs, it is `SYNTH_KEEP_HIERARCHY_MODULES`.** One
synthesis of the top with named boundaries preserved gives the area of every
block at once — including the ones that cannot stand alone — and costs one run
instead of twenty. Reach for it as the default way to build an area table, and
keep standalone hardening for the blocks you actually intend to place as macros.

Check which modules are interface-free before planning anything around
per-module runs. It is a five-minute grep and it decides the shape of the flow.

Note `SYNTH_HIERARCHY_MODE` interacts with it: with Slang you must pass
`--keep-hierarchy` in `SLANG_ARGUMENTS` separately.

### Getting simulation-only code out

Leave the simulation define **undefined** rather than stripping code. On a
design guarded with `` `ifdef SIMULATION `` that single choice drops DPI
imports and their call sites, `$display`/`$fatal` blocks, and behavioural
memory models all at once — the last of which is what turns an SRAM wrapper
into the black box a macro binds to.

Then **check the output**, because a call site whose import was guarded but
which was not itself guarded will fail synthesis with
`Can't resolve task name '\foo'`. That is an RTL bug, and the fix is a guard
around the `always` block, not a workaround in the flow.

---

## 3. Verified LibreLane configuration

Read from LibreLane's source, not recalled. Check them against the installed
version before trusting them — but these are the right names to look for.

| variable | note |
| --- | --- |
| `RT_MIN_LAYER`, `RT_MAX_LAYER` | **PDK variables.** Default met5 on sky130A |
| `SYNTH_HIERARCHY_MODE` | `flatten` (the default), `deferred_flatten`, `keep` |
| `SYNTH_KEEP_HIERARCHY_MODULES` | keep named boundaries through a flat run, for per-module area attribution |
| `SYNTH_CLOCKGATE_MIN_WIDTH` | gate enabled flop groups ≥ N bits. **Off by default**; the biggest power lever on a flop-heavy design |
| `USE_SLANG`, `SLANG_ARGUMENTS` | the SystemVerilog frontend |
| `VERILOG_INCLUDE_DIRS`, `VERILOG_DEFINES` | `` `include `` search path and defines |
| `FP_SIZING` | `relative` (use `FP_CORE_UTIL`) or `absolute` (use `DIE_AREA`) |
| `FP_CORE_UTIL`, `PL_TARGET_DENSITY_PCT` | note the `_PCT`; OpenLane 1 used a 0–1 fraction |
| `MACROS`, `PDN_MACRO_CONNECTIONS` | hard macro declaration and power hookup |
| `DRT_OPT_ITERS`, `DRT_ANTENNA_REPAIR_ITERS` | detailed router effort |
| `GRT_ALLOW_CONGESTION` | **leave off by default.** It suppresses the most useful signal the flow gives about whether the die is big enough |
| `ERROR_ON_MAGIC_DRC`, `ERROR_ON_KLAYOUT_DRC` | turn a fatal into a count when you want to see how bad it is |
| `FP_PDN_VPITCH`, `FP_PDN_HPITCH` | strap pitch; widening frees routing tracks at the cost of IR drop |
| `RUN_LINTER` | Verilator lint; worth disabling if you feed it more modules than the design needs |

### Step IDs worth knowing

`Yosys.Synthesis` · `OpenROAD.Floorplan` · `Odb.ManualMacroPlacement` ·
`Odb.SetPowerConnections` · `OpenROAD.GeneratePDN` · `OpenROAD.GlobalPlacement` ·
`OpenROAD.CTS` · `OpenROAD.GlobalRouting` · `OpenROAD.DetailedRouting` ·
`OpenROAD.RCX` · `OpenROAD.STAPostPNR` · `OpenROAD.IRDropReport` ·
`Magic.DRC` · `KLayout.DRC` · `KLayout.XOR` · `Netgen.LVS` · `Yosys.EQY`

`--to Yosys.Synthesis` still walks all ~80 steps, skipping the rest, and still
writes `final/`. That is normal, not a bug.

### There is no post-detailed-route optimisation

If you know Innovus, this is the surprise. Every resizer in the Classic flow —
`RepairDesignPostGRT`, `ResizerTimingPostGRT`, `RepairAntennas` — runs after
**global** routing and before `DetailedRouting`. There is no
`optDesign -postroute -drv -inc` to call twice. What the detailed router cannot
fix in place, it reports.

So a "repair" loop means re-running with a constraint loosened, not an
incremental ECO. Escalate cheapest first: router effort, then a bigger die,
then a sparser PDN — and check IR drop after the last one.

---

## 4. Flow design patterns that paid off

**Validate the tool before trusting discovery.** Finding something and being
able to use it are different questions. Two separate failures in one session —
an sv2v binary that downloaded cleanly and could not link, and a LibreLane
package that imported and could not resolve its dependencies — both would have
been caught by asking the candidate for `--version` before committing to it.
Do that for every external tool you locate.

**Two passes for anything with macros.** LibreLane places standard cells but
never a hard macro; every instance needs coordinates, and the instance paths do
not exist until synthesis has flattened the hierarchy. So: synthesise, read the
instance names out of the netlist, then run the full flow with the floorplan
pinned.

**Read dimensions and pin names out of the LEF.** Never hardcode macro size,
and never assume power pin names — sky130 OpenRAM uses `vccd1`/`vssd1` while a
LibreLane-hardened block uses `VPWR`/`VGND`. Guessing wrong leaves a macro
silently unconnected to the grid.

**Hierarchical children must stop one routing layer short.** If a block routes
on the top layer, its parent has nothing to route over it on, and the PDN wants
that layer for straps. Build children at met4, top at met5.

**Where to cut hierarchically is a ratio question:** state held inside the block
against port bits crossing its boundary. On one design, a branch predictor held
~504,000 flops behind 191 port bits (2,640 bits per port bit) while a rename
unit held ~10,000 behind 2,410 (4 per port bit). Cut the first, never the
second. Hierarchy buys tractability, and costs area and cross-boundary timing.

**Every step is a checkpoint.** LibreLane writes `state_out.json` per step. Use
`--last-run` and `--from <step>` to resume. If your script stamps a fresh run
tag every invocation it silently throws all of that away.

**Never let a truncated run report success.** `--to <step>` leaves a
`state_out.json` behind for whatever steps did run, so "metrics exist" proves
nothing — a run that died in step 5 of 80 writes them too. Gate the success
message on a metric that only the step you wanted produces: a cell count for
synthesis, a GDS for a full run. This flow reported `ok` for twenty-one designs
that had all failed in step 5, because the check was for a file rather than for
a number in it.

**Aggregate errors as they happen.** A failure's cause is one line in one step
log inside one design's run directory, and with `-j` several designs interleave
their output on the way past. Append a short block per failure — module, exit
code, last step, the deduplicated `error:` lines — to a single file, and print a
one-line-per-failure roll-up at the end. Build the block in a temp file and
append it with one `cat` so concurrent writers cannot interleave.

**Do not read the scroll; diff the metrics.** A run is ~80 steps and tens of
megabytes. Each step's `state_out.json` holds its metrics, so the useful view is
what each step *changed*, plus any `ERROR` line, plus the slowest steps. A
~100-line digest script pays for itself the first time you use it, and it reads
a run directory only — so it works mid-run and from outside the devshell.

**Select source files by what they define, not by what kind of file they are.**
Handing a per-module run "the files with no module in them, plus the file owning
each module I need" is the obvious rule and it is wrong. Interfaces, packages and
typedefs live wherever someone put them, and in this core `d_cache_input_ifc` sat
inside `d_cache.sv` — a file with a module in it. Two designs that used the
interface without using the module got a file list missing it, and would have
died at `unknown interface 'd_cache_input_ifc'`. Include a file when it defines
anything the design *names*, transitively, and it stops mattering where things
live.

**Measure the PDK, do not recall it.** Read macro `SIZE` from LEF and flop
`SIZE` from the standard cell LEF and compute µm²/bit yourself. Real sky130
numbers, for calibration: `dfxtp_1` 20.0 µm²/bit (50.0 at 40% utilisation),
`sram_1kbyte_32x256` 23.3, `sram_1kbyte_8x1024` 24.8, `sram_2kbyte_32x512`
**17.4**. SRAM wins by ~2.9×, not the 10× intuition suggests — OpenRAM carries
heavy peripheral overhead.

---

## 5. Traps in the tooling you write

Writing a parser for SystemVerilog by regex is a bad idea that is nonetheless
sometimes the right call — as a fallback when the real front end is not
installed. If you do it, these are the specific ways it goes quiet:

- **A DPI prototype opens a scope it never closes.**
  `import "DPI-C" function void f(...);` matches `function` and has no
  `endfunction`. A depth counter gets stuck and skips every declaration below
  it, in silence. Skip `import`/`export`/`extern` lines before counting anything.
- **A non-ANSI port list legitimately names signals before declaring them.**
  `output [7:0] x;` above `logic [7:0] x;` is correct Verilog, not a defect.
  Find where the module header closes and start the check after it.
- **A `for (int i = ...)` loop variable shadows a module-level signal of the
  same name.** Without scope tracking you will report the inner use as a
  forward reference to the outer declaration. Skipping names that appear in any
  loop header is a crude fix that costs little.
- **A module name and a signal name can collide.** Exclude the module's own name.

Each of these produced a false result on the first run of a ~200-line checker.
Three were false positives, which is annoying; one was a false negative, which
is dangerous. See "Validate the checker against a failure you already have".

## 6. Bash traps that cost real time

- **`set -e` is disabled inside functions called from a `||` list.** A function
  invoked as `f || warn` will keep going after an internal failure. Check
  statuses explicitly and `return 1`.
- **`local a="$1" b="$WORK/$a"`** fails under `set -u` — `$a` is not assigned
  until the statement finishes. Split the declarations.
- **`"${arr[@]}"` on an empty array** errors under `set -u` in bash < 4.4. Use
  `${arr[@]+"${arr[@]}"}`.
- **`grep -oP`** dies on some locales. Prefer `sed` with a BRE.
- Prefer `find`/globs over probing a list of guessed paths. If you are adding a
  fourth guess, search instead.
- Windows-side: `command -v python3` can find a Microsoft Store stub that exits
  non-zero. Probe by running it, not by finding it.
- Commit a `.gitattributes` with `*.sh text eol=lf` if authoring on Windows. A
  CRLF shebang gives `bad interpreter: /usr/bin/env bash^M` on Linux.

---

## 7. Order of work

Everything before step 5 runs on your own machine and needs no remote session
at all. That ordering is the single biggest thing this project got wrong on the
first pass.

1. **`pip install pyslang` and elaborate every design locally.** Seconds. This
   tells you which modules can be a top-level design at all, and it is the
   answer to a question you would otherwise pay for one round trip at a time.
2. **`verilator --lint-only`.** Three seconds. Catches what the simulator will
   refuse, which is not the same set.
3. **Fix every RTL finding in one pass, then re-run the full simulation.** The
   fixes should be cycle-identical; if one is not, it was not the fix you
   thought it was.
4. Parse the RTL and list what is hardenable. Still no tools needed.
5. Get a working shell on the remote machine. Prove it with `librelane --version`.
6. Measure the PDK — µm²/bit for every macro and a flop. Cheap, and it frames
   every later decision.
7. **Synthesis only, smallest module.** The run that proves the flow accepts
   your config. Minutes, not hours.
8. **Synthesis only, the top, with `SYNTH_KEEP_HIERARCHY_MODULES` set** for
   every block you want a number for. One run, one area table, and it covers
   the blocks that cannot be a top-level design. This is better than N
   per-module runs, not just cheaper.
9. Full flow on one small block, all the way to GDS.
10. Only then the big runs.

Steps 7 and 8 are the ones people skip on the remote side, and steps 1–3 are the
ones people skip entirely. Skipping either turns a five-second answer into a
five-hour one.
