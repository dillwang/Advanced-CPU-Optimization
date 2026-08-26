# RTL to GDSII

Everything here drives the core through an open-source physical design flow on
[nanoHUB](https://nanohub.org/resources/librelane). One script does the whole
thing, from the SystemVerilog in `mips_cpu/mips_core/` to a GDS you can open in
KLayout.

```
git clone https://github.com/dillwang/Advanced-CPU-Optimization.git
cd Advanced-CPU-Optimization/asic

./rtl2gds.sh list                    # what can be hardened, and what it needs
./rtl2gds.sh --synth-only all-blocks # area and cell counts, minutes not hours
./rtl2gds.sh prf                     # one small block, all the way to GDS
./rtl2gds.sh core                    # the whole CPU flat, SRAM macros and all
./rtl2gds.sh hier                    # the whole CPU bottom up, blocks as macros
./rtl2gds.sh pdk-report              # um^2 per bit: SRAM macro vs flip-flop
```

Results land in `asic/results/<module>/` — GDS, DEF, gate-level netlist, SPEF
and `metrics.json` — and the script prints a table of area, cell count, slack
and violation counts at the end.

## Which flow, and which node

**LibreLane, not OpenLane.** nanoHUB carries both. Its
[OpenLane](https://nanohub.org/resources/openlane) tool is OpenLane 1: the
Tcl-driven flow that Efabless maintained until it shut down, and which is now
frozen. [LibreLane](https://nanohub.org/resources/librelane) is the continuation
of OpenLane 2 under the FOSSi Foundation, maintained by the people who wrote it,
and the nanoHUB build is theirs. It is the same OpenROAD, Yosys, Magic, Netgen
and KLayout underneath; what differs is the driver — a Python step graph you can
stop, restart and resume at any step, instead of a monolithic Tcl script. That
matters here, because the full core needs a two-pass run and OpenLane 1 makes
that awkward.

`rtl2gds.sh` finds whichever is installed and adapts, but the `core` target
needs LibreLane's macro handling and says so if it can't find it.

**sky130A with `sky130_fd_sc_hd`,** which is the smallest node you can actually
get. LibreLane supports three open PDKs:

| PDK | node | SRAM macros |
| --- | --- | --- |
| `sky130A` | 130 nm | yes — OpenRAM, three sizes |
| `gf180mcuD` | 180 nm | no |
| `ihp-sg13g2` | 130 nm | yes, but LibreLane dev branch only |

sky130 and IHP are the same 130 nm and nothing open goes below it, so the tie is
broken by the caches: this design needs 54 SRAM instances and only sky130 ships
macros that a stock LibreLane install will find. `sky130_fd_sc_hd` is the
high-density standard cell variant — the smallest cells in the kit, 2.72 µm row
height. Override either with `-k`/`-s` if you want to compare.

## What each stage does

### 1. Lower — sv2v

Yosys reads Verilog-2005. This core is SystemVerilog throughout: a package of
parameters, interfaces on nearly every module boundary, structs, unpacked arrays
of structs. So the first thing the script does is run every file named in
`mips_cpu/verilator_files` through sv2v into one flat `build/mips_core.v`.

Two details matter.

**The file list comes from `verilator_files`, not a glob.** `mips_core/*.sv`
misses `ooo/` and `branch_predictor_files/` entirely, and picks up the retired
predictors still sitting in the tree. The existing `mips_cpu/synth/Makefile`
globs, which is why the `mips_core.v` it leaves behind holds eight modules built
around `perceptron_predictor` — a machine that has not existed here for a while.

**`SIMULATION` is deliberately left undefined,** which does three jobs at once:
it drops every `import "DPI-C" function void stats_event` and its call sites, it
drops the `$display`/`$fatal` assertion blocks, and it removes the behavioural
OpenRAM model from `cache_bank.sv` — which is what turns `sram` into the black
box that `src/sram_sky130.v` then binds to a real macro.

That last one needed a fix in the RTL. `i_cache.sv` called `stats_event` from an
unguarded `always_ff` while its import was inside `` `ifdef SIMULATION ``, so
synthesis died on `Can't resolve task name '\stats_event'`. The call block now
carries the same guard `d_cache.sv` already had. Simulation is unaffected.

sv2v inlines any module with an interface port into its parent, so `d_cache`,
`i_cache`, `alu`, `decoder`, `lsq`, `ooo_backend`, `stream_buffer` and
`d_prefetcher` all disappear into `mips_core`. What survives as a real module is
exactly what can be hardened on its own, and `./rtl2gds.sh list` reports that set
rather than a hardcoded list.

### 2. Synthesis — Yosys

RTL to a gate netlist in `sky130_fd_sc_hd`, constrained by `CLOCK_PERIOD`
(default 10 ns; `-p` to change it). `RUN_LINTER` is off because the flat file
holds every module and linting all of it for each block run is noise.

`--synth-only` stops here. **Do this first.** It takes minutes instead of hours
and tells you the area and cell count, which is the number that decides whether
the rest of the flow is worth starting.

### 3. Floorplan — OpenROAD

Die and core area, standard cell rows, routing tracks, IO pin placement, power
grid, and — for anything containing a cache — SRAM macro placement.

For blocks the script asks for relative sizing: pick a die that lands the design
at `FP_CORE_UTIL` (default 40%).

Any design holding a macro needs two passes here, because **LibreLane will place
standard cells for you but it will not invent a location for a hard macro.**
Every instance needs coordinates, and those instance paths don't exist until
synthesis has flattened the hierarchy. So for `core`, for `hier`, and for any
block that reaches a cache bank, the script:

1. runs synthesis alone,
2. reads the macro instance names back out of the netlist, and each macro's real
   dimensions *and power pin names* out of its LEF rather than assuming them,
   shelf-packs them into a band and sizes a die that holds it plus the standard
   cells (`scripts/gen_floorplan.py`),
3. re-runs the whole flow with that floorplan pinned, plus the
   `PDN_MACRO_CONNECTIONS` entries hooking each macro to the grid.

Reading the power pins matters once the run is hierarchical: the OpenRAM macros
use `vccd1`/`vssd1` and a block hardened by LibreLane in sky130 uses
`VPWR`/`VGND`, and guessing wrong leaves a macro silently unconnected.

The generated layout is macros shelf-packed across the top with logic below. It
is legal and it routes; it is not *good*. A real floorplan would put each cache's
banks next to the logic that reads them. Treat it as a starting point to argue
with — `build/work/<module>/floorplan.json` is plain JSON, and editing it and
re-running is the intended workflow.

### 4. Placement and clock tree — OpenROAD

Global placement, repair, detailed placement, then CTS builds the clock network
and the design is re-timed against real clock arrival. `GRT_ALLOW_CONGESTION` is
on: these blocks are wall-to-wall flops and global route *will* report
congestion. Better to let it hand the mess to detailed routing and read the DRC
count at the end than to stop on a warning.

### 5. Routing — OpenROAD

Global then detailed routing, antenna repair, then parasitic extraction to SPEF.

### 6. Signoff — OpenROAD, Magic, KLayout, Netgen

Post-route STA at every corner, DRC in both Magic and KLayout, LVS in Netgen
against the synthesized netlist, antenna check, then the GDS is streamed out.

The script copies GDS, DEF, netlist, SPEF and `metrics.json` into
`results/<module>/` and prints:

```
    module     cells   area um2   util %   WNS ns   TNS ns   DRC   LVS   antenna
```

WNS at or above zero with DRC and LVS at zero is a clean run.

## What to expect

**Start with `--synth-only all-blocks`.** The reason is in the storage:

| structure | bits, all in flip-flops |
| --- | --- |
| TAGE tags `6 x 1024 x 4 x 13` | 319,488 |
| TAGE counters, useful bits, valid | 147,456 |
| TAGE path-history checkpoints, base table | 36,864 |
| SC bias tables `bias_p` + `bias_pt` + `bias_ptc` | 135,168 |
| SC GEHL banks, 15 of them | 92,160 |
| SC local history, sum checkpoints | 11,008 |
| **branch predictor total** | **~742,000** |
| everything else (BTB, PRF, ROB, IQ, LSQ, prefetcher) | ~80,000 |
| i-cache and d-cache | SRAM macros, not flops |

A `sky130_fd_sc_hd__dfxtp_1` is about 25 µm². 742 K flip-flops is roughly
18 mm² of flops before a single gate of logic, and at 40% utilisation that is a
~46 mm² die. For scale, a whole Caravel user project area on a sky130 shuttle is
about 10 mm².

So: the predictor is not a block that happens to be large, it *is* the area of
this chip, because 93 KB of predictor state is implemented as registers. On any
real machine those tables would be SRAM — which is the same reason the caches
are already `cache_bank` and not arrays. If you want a tapeable version of this
core, converting the TAGE and SC tables to banked SRAM is the change that makes
the difference, and it is a much bigger change than anything in this directory.

With that said, roughly what you can expect:

| target | plausible |
| --- | --- |
| `prf`, `btb`, `issue_queue`, `cache_bank`, the two arbiters | minutes, clean |
| `rename_rob` | tens of minutes |
| `statistical_corrector` (238 K flops) | hours, large die |
| `frontend`, `tage_m1` (504 K flops) | many hours |
| `core` | expect to iterate on the floorplan; this is a research-scale run |

`-j` runs blocks in parallel — the script defaults to 4 at a time and sends each
one's output to `build/<module>.log`. `mips_core` always runs alone.

## Hierarchical: cutting the problem down

`./rtl2gds.sh core` hands OpenROAD the whole machine at once. `./rtl2gds.sh
hier` doesn't: it hardens the deepest block first, then everything above it with
that block as a placed black box carrying its own GDS, LEF and timing model.
Each run's placement and routing problem is bounded by what is left after the
cut.

The mechanism is the one the SRAM already uses. A LibreLane `MACROS` entry does
not care whether the thing behind it came from OpenRAM or from an earlier run of
this same script, so a hardened block plugs into exactly the same slot.

```
./rtl2gds.sh hier
    hierarchical order: statistical_corrector tage_m1 mips_core
```

That order comes out of the instantiation graph (`scripts/hier_order.py`), not a
list, so it stays right if the RTL changes. Each step also rewrites the design's
Verilog to hold only the modules it still needs — cutting `tage_m1` out of
`mips_core` leaves ten modules where the flat file has twelve, and
`statistical_corrector` disappears with it, because nothing at the top
instantiates it directly.

### Where to cut

This is a ratio question: state held inside the block against port bits crossing
its boundary. Every bit of state that goes behind a macro is one fewer instance
for the parent to place; every port bit is a pin the parent has to route to, on
a path a hierarchical flow can no longer optimise across.

| module | port bits | state (flops) | state per port bit |
| --- | --- | --- | --- |
| `tage_m1` | 191 | ~504,000 | **2,640** |
| `statistical_corrector` | 339 | ~238,000 | **700** |
| `btb` | 488 | ~21,500 | 44 |
| `rename_rob` | 2,410 | ~10,000 | 4 |
| `issue_queue` | 1,722 | ~2,200 | 1.3 |

The predictor is a gift: `tage_m1` puts about 504,000 flip-flops behind 191 pins,
because a branch predictor's whole interface is a PC in, a bit out, and an
outcome back. Cutting there and at `statistical_corrector` inside it removes
roughly **90% of the machine's non-cache state** from the top-level run.

`rename_rob` is the opposite and shows why "harden everything" is wrong. 2,410
port bits — four dispatch slots, five writeback ports, the commit interface —
guarding about 10,000 flops. Hardening it would add a halo, a power ring and
pin-access margin, cut the parent off from optimising every one of those 2,410
paths, and remove almost nothing from the placement problem. `HIER_CUTS` is
where you'd change your mind about this; the default is
`statistical_corrector tage_m1`.

### What it costs

Hierarchical P&R buys tractability, not area. It generally costs both:

- **Area.** Each hardened block gets its own halo and power ring, its pins need
  access room, and the parent cannot pack standard cells into the block's
  whitespace. Expect a few per cent to low double digits.
- **Timing.** Paths crossing a boundary are constrained by budgeted input and
  output delays rather than optimised end to end, and the clock tree becomes
  hierarchical — each block builds its own, the parent balances the roots. A
  loose 10 ns period hides this. A tight one will not.

So `hier` is the right call when `core` will not converge or will not fit in the
node's memory, and the wrong call if `core` already runs.

## Could the predictor tables be SRAM?

They are the area of this chip, so it is the right question. The short answer:
yes, but it needs a change to `tage_m1.sv`, not to anything in this directory —
and the payoff is smaller than it looks. Three things decide it.

**Port pressure, which is the real blocker.** Per table, per cycle, the current
RTL does a predict-side read at `q_set[t]`, a feedback-side read at `f_set[t]`,
and a write. That is 2R+1W. The sky130 macro is 1RW+1R — two ports, so it can do
two reads, or a read and a write, but not two reads *and* a write. The fix is to
pipeline the feedback path over two cycles: feedback happens at commit, where an
extra cycle of latency costs nothing except a cycle of staleness in how fast the
predictor learns. That is exactly the kind of change this repository has already
learned to distrust without measurement — the corrector's checkpointed sum was a
net loss of 16,186 predictions until it was fixed — so it needs re-running
against the golden traces, not reasoning about.

**Ways cannot be folded into depth.** All four ways of a set are read together to
compare tags, so they need four parallel arrays; you cannot make one deeper macro
serve them. That fixes the shape at 18 bits (13 tag + 3 counter + 2 useful) by
1024 entries per table per way, against macros that are 32x256, 32x512 or 8x1024.
Only the last one matches the depth, three of them wide, which means 72 macros
for the TAGE tables alone.

**One thing is already right, and it is the thing that usually kills this.** A
textbook TAGE resets its useful bits by flash-clearing the whole array, which no
SRAM can do. This implementation walks instead — `tg_u[t][u_timer[SET_W-1:0]][w]`
decays one set per table per cycle
([tage_m1.sv:573](../mips_cpu/mips_core/branch_predictor_files/tage_m1.sv#L573)).
That is already SRAM-shaped. The only remaining flash clear is at reset, and the
usual answer is to keep the valid bits in flops — 6 x 1024 x 4 = 24,576 of them,
cheap — and let tag, counter and useful bits live in SRAM.

**Then check whether it is worth it,** because in sky130 the answer is not
obvious. The open OpenRAM macros carry a lot of peripheral overhead and a
high-density DFF is small, so the density ratio is nothing like the 10x you would
get from a foundry compiler:

```
./rtl2gds.sh pdk-report
```

reads the macro SIZE out of each LEF and the flop SIZE out of the standard cell
LEF and prints um^2 per bit for both, charging the flop row at your utilisation
because flops need placement density and a macro does not. Run it on the real PDK
before committing to the rewrite — the ratio it reports is the entire case for
doing the work.

## Restarting, repairing, and the knobs that matter

### Every step is already a checkpoint

LibreLane writes `runs/<tag>/<NN>-<step>/state_out.json` after each of the
Classic flow's ~80 steps, holding that step's metrics and the paths to the views
it produced. Nothing is lost when a run dies at step 47.

What the script was getting wrong is that it stamped a fresh timestamp tag on
every invocation, so it never picked those up. `--resume` fixes that:

```
./rtl2gds.sh --resume core                          # continue the newest run
./rtl2gds.sh --from OpenROAD.GlobalRouting core      # re-enter at a named step
```

`--resume` passes LibreLane's `--last-run`, which reuses the newest run
directory for that design and carries its state forward. `--from` adds the step
to re-enter at. Useful step IDs, in flow order: `Yosys.Synthesis`,
`OpenROAD.Floorplan`, `Odb.ManualMacroPlacement`, `OpenROAD.GeneratePDN`,
`OpenROAD.GlobalPlacement`, `OpenROAD.CTS`, `OpenROAD.GlobalRouting`,
`OpenROAD.DetailedRouting`, `Magic.DRC`, `Netgen.LVS`.

A hierarchical run resumes for free at a coarser grain: `hier` rebuilds which
blocks are already macros from what is sitting in `results/`, so re-running it
after a failure skips straight to the block that failed.

### `--repair N`: what it can and cannot do

**It is not `optDesign -postroute -drv -inc`, because OpenROAD has no such
step.** In the Classic flow every resizer — `RepairDesignPostGRT`,
`ResizerTimingPostGRT`, `RepairAntennas` — runs after *global* routing and
before `DetailedRouting`. There is no post-detailed-route incremental
optimisation to call twice. Anything the detailed router cannot fix in place,
it reports.

So `--repair` does the other thing: re-runs with the constraint that produced
the violation loosened, one class at a time, cheapest first.

| attempt | what changes | why it is in this order |
| --- | --- | --- |
| 1 | `DRT_OPT_ITERS` to 128, `DRT_ANTENNA_REPAIR_ITERS` to 5, `GRT_ALLOW_CONGESTION` on, `ERROR_ON_*_DRC` off | costs only time, and turning the errors into counts is what lets you see whether the problem is 4 violations or 40,000 |
| 2 | utilisation down ~10 points, placement density with it | a bigger die is the honest fix for congestion, and it is what "increase chip size" means here |
| 3 | `FP_PDN_VPITCH`/`HPITCH` to 90 µm, utilisation down further | fewer power straps standing between the router and the cells |

Attempt 3 is last because it trades something real away: a sparser grid means
more IR drop. `OpenROAD.IRDropReport` is the number to check afterwards — do not
take a clean DRC from attempt 3 without reading it.

Two things `--repair` deliberately does *not* do. It does not move pins, because
`FP_IO_MODE`/`FP_PIN_ORDER_CFG` need to know what is on the other side and this
script does not. And it does not touch the macro floorplan, because that is
`build/work/<module>/floorplan.json` and editing it by hand is more likely to be
right than any heuristic here.

**Congestion is not suppressed on the first attempt any more.** An earlier
version set `GRT_ALLOW_CONGESTION: true` by default; that threw away the most
useful signal the flow produces about whether the die is big enough. It is now a
repair-attempt escalation.

### Maximum routing layer

`RT_MAX_LAYER` is a PDK variable, so leaving it alone gives you sky130A's
default of **met5** — every layer, which is what you want for a top level. met5
is the thick, low-resistance layer, and on a die this size the long global routes
want it.

**But a block that will be placed inside a parent must stop one layer short.**
If `tage_m1` routes on met5, `mips_core` has nothing left to route *over* it on,
and the PDN wants met5 for straps besides. So `hier` now builds children at
`RT_MAX_LAYER=met4` and gives only the top design every layer. Override with
`--max-layer` for the top, or `CHILD_MAX_LAYER` for the children.

This is the same reason Caravel user projects are built at met4.

### Flattening

`SYNTH_HIERARCHY_MODE` **already defaults to `flatten`** in LibreLane, so the
flat synthesis you would want is what you are getting. `--hierarchy` exposes it
if you want `deferred_flatten` (flatten after synthesis, keeping module
boundaries during optimisation) or `keep`.

The more interesting inverse is `SYNTH_KEEP_HIERARCHY_MODULES`, which preserves
named module boundaries *through* a flattened run. That is worth setting when
you want per-module area attribution out of `Odb.CellFrequencyTables` rather than
one undifferentiated cell count — the cost is that the optimiser stops working
across those boundaries, so use it to measure, not to ship.

### Clock gating

`--clock-gate N` sets `SYNTH_CLOCKGATE_MIN_WIDTH`, which replaces any enabled
flop group of at least N bits with an integrated clock gate. It is off by
default in LibreLane.

On this design it is the one lever that changes power by an order of magnitude
rather than a few per cent, because the ~742,000 predictor flops are written
rarely — a TAGE entry is touched when its table provides or allocates, not every
cycle — but a clock net reaching all of them toggles regardless. `--clock-gate 8`
is a reasonable starting point.

## Which tools the flow actually uses

The Classic flow is ~80 steps and already drives everything the nanoHUB tool
bundles, so "am I using all of it" is mostly yes by construction:

| tool | what runs |
| --- | --- |
| Yosys | `Yosys.Synthesis`, and `Yosys.EQY` — formal equivalence of the final netlist against the RTL |
| OpenROAD | floorplan, PDN, placement, CTS, both routers, all the resizers, STA at every corner, `IRDropReport` |
| Magic | `Magic.DRC`, `StreamOut`, `WriteLEF`, `SpiceExtraction` |
| KLayout | `KLayout.DRC`, `StreamOut`, `Render`, and `KLayout.XOR` — Magic's GDS against KLayout's |
| Netgen | `Netgen.LVS` against the synthesised netlist |
| Verilator | `Verilator.Lint` — **disabled here** (`RUN_LINTER: False`), because the trimmed Verilog holds every module the design needs and linting all of them per run is noise. The simulator lints this RTL already. |
| ngspice | bundled, but not part of a digital flow. `Magic.SpiceExtraction` produces the netlist it would consume if you wanted to simulate an extracted block. |

Worth knowing that `Yosys.EQY` and `KLayout.XOR` are both running: the first is a
formal proof that P&R did not change the logic, the second catches a GDS that
two different tools read differently. Neither has an Innovus equivalent you would
get for free.

## Files

| | |
| --- | --- |
| `rtl2gds.sh` | the whole flow; run this |
| `src/sram_sky130.v` | binds the design's generic `sram` to the sky130 OpenRAM macro |
| `scripts/gen_config.py` | writes a LibreLane config per module; also `--probe` |
| `scripts/gen_floorplan.py` | macro placement and die sizing, mixed macro sizes |
| `scripts/hier_order.py` | topological order for a hierarchical run |
| `scripts/pdk_report.py` | measures um^2 per bit out of the installed PDK |
| `prepare.sh` | only if nanoHUB has no outbound network — lowers the RTL locally in the CSE148 container and tars up what to upload |

## If sv2v isn't there

nanoHUB's LibreLane tool bundles LibreLane, KLayout, OpenROAD and ngspice — not
sv2v. `./rtl2gds.sh --fetch-sv2v ...` downloads the static release binary into
`build/` once, and every later run reuses it. If the session has no outbound
network, run `./prepare.sh` on a machine with the `nonlig/cse148wi24` container,
upload `build/mips_core_asic.tar.gz`, and `rtl2gds.sh` will find the lowered
Verilog already in place and skip the step.
