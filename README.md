# Advanced-CPU-Optimization

A CPU architecture design project that replaces a simple in-order MIPS32 core with a
**superscalar out-of-order machine**, and measures what each optimization is actually worth.

Implemented:

- Tournament branch prediction (perceptron + gshare with a chooser)
- Register renaming (MIPS R10000 style)
- Superscalar out-of-order execution
- Branch target buffer, so prediction happens in fetch rather than decode
- Non-blocking data cache with miss status holding registers
- Memory dependence speculation, with a predictor and a stress-tested recovery path
- Next-line hardware prefetching with a stream buffer

Every number in this README was measured with the simulator on this repository. See
[Results](#results) for the method.

---

# Baseline

The starting point is the classic five-stage in-order pipeline with a forwarding unit, a hazard
controller, split I/D caches and an AXI memory arbiter.

![image](https://github.com/user-attachments/assets/92958813-c3e5-4a26-98b2-04022365c847)

The original in-order RTL is still in the tree for reference (`fetch_unit.sv`, `forward_unit.sv`,
`glue_circuits.sv`, `hazard_controller.sv`, `pipeline_registers.sv`, `reg_file.sv`,
`branch_controller.sv`), but it is no longer built — `mips_cpu/verilator_files` selects the
out-of-order core instead.

---

# Architecture

```
        in order                          out of order                      in order
 ┌───────────────────────┐   ┌────────────────────────────────────┐   ┌──────────────┐
 │ FETCH + PREDICT (BTB) │   │            issue queue             │   │              │
 │   ↓                   │──▶│         (32 entries, oldest-       │──▶│   COMMIT     │
 │ fetch buffer → DECODE │   │          ready-first select)       │   │  (in order,  │
 │   ↓                   │   │                 ↓                  │   │   4 wide)    │
 │ RENAME + DISPATCH     │   │   4 ALUs   +   load/store queue     │   │              │
 └───────────────────────┘   │                 ↓                  │   └──────────────┘
            │                │            writeback               │          ▲
            └────────────────┴─── reorder buffer (128 entries) ────┴──────────┘
```

The front end, rename and commit are all in program order and `FE_WIDTH` instructions wide.
Everything between dispatch and writeback runs out of order, bounded by the issue queue and the
reorder buffer.

Current sizing, all in `mips_core_pkg.sv` unless noted:

| | |
| --- | --- |
| fetch / decode / rename / dispatch / commit | `FETCH_WIDTH` **8** words in, `FE_WIDTH` **4** instructions out |
| issue | `ISSUE_WIDTH` **4**, so 4 ALUs, 8 register-file read ports, 5 write ports |
| window | reorder buffer **128**, issue queue **32**, load/store queue **32**, **128** physical registers |
| branch prediction | TAGE-SC-L: 6 tagged tables x 1024 sets x 4 ways over two path histories, plus a statistical corrector (~90 KB total) |
| target buffer | **512** entries |
| I-cache | **8 KB**, 2-way, 8-word lines, with a next-line stream buffer |
| D-cache | **32 KB**, 4-way, 8-word lines, non-blocking, **8** miss registers over **two** AXI read ids |
| D-side prefetcher | 64 lines, 16 stream detectors, spatial + temporal, on its own AXI read id |

The history of how each of these was arrived at — and the several that were arrived at twice
because the first answer was wrong — is in [Results](#results).

**All architectural state changes happen at commit** — the architectural register map, freeing
physical registers, stores reaching the D-cache, and the simulation event stream. A squashed
instruction can therefore never be observed.

## Code structure

| File | Role |
| --- | --- |
| `ooo/frontend.sv` | Fetch, prediction, fetch buffer, decode, delay-slot-aware redirect control |
| `ooo/btb.sv` | Branch target buffer: what makes prediction in fetch possible |
| `ooo/rename_rob.sv` | Register map, free list, busy table, reorder buffer, commit, recovery |
| `ooo/issue_queue.sv` | The instruction window: wakeup and oldest-first select |
| `ooo/lsq.sv` | Load/store queue, disambiguation, store-to-load forwarding, memory order violation detection, D-cache port |
| `ooo/prf.sv` | Unified physical register file |
| `ooo/ooo_backend.sv` | Back-end glue and the execution units |
| `branch_predictor_files/tage_m1.sv` | **The predictor in use**: TAGE shaped after the Apple Firestorm design, on two path histories |
| `branch_predictor_files/statistical_corrector.sv` | The SC of TAGE-SC-L: bias, path and local-history counter banks that can override the tagged prediction |
| `branch_predictor_files/tournament_predictor.sv` | Perceptron + gshare + chooser. Not wired in; kept as the baseline the others are measured against |
| `branch_predictor_files/tage_predictor.sv` | Textbook TAGE on a direction history, for the same comparison |
| `stream_buffer.sv` | Next-line instruction prefetcher |
| `d_prefetcher.sv` | Data-side prefetcher: spatial stream detection and a temporal correlation table, with its own line storage and AXI id |
| `d_cache.sv` | 4-way write-back data cache, non-blocking: miss status holding registers, a decoupled writeback queue, and two AXI read ids |
| `i_cache.sv`, `memory_arbiter.sv` | Close to the baseline. The I-cache returns a whole 8-word line per fetch; the arbiter now carries five read masters |

---

# Branch Prediction

The predictor is **TAGE-SC-L**: a tagged, path-history TAGE shaped after the Apple Firestorm design
(`tage_m1.sv`), with a perceptron-style statistical corrector sitting on top of it
(`statistical_corrector.sv`). Three predictors were built and measured against each other at a
matched 64 KB before this one was settled on; the comparison is in
[Statistical Correction](#statistical-correction).

## The M1-shaped TAGE

TAGE ([Seznec and Michaud](https://jilp.org/vol8/v8paper1.pdf)) keeps several tagged tables indexed
by progressively longer histories. A branch is answered by the **longest history that has seen this
exact context before**, with a short-history bimodal underneath for anything no table matches. The
shape here follows Firestorm as reverse engineered in
[Yavarzadeh et al, *Whisper: Timing the Transient Execution of Apple Silicon*](https://arxiv.org/html/2411.13900v1),
and three things in it are deliberately not textbook TAGE:

**Path history, not direction history.** A textbook TAGE folds a register of taken/not-taken bits.
This folds *addresses*, so the history records which branches ran and where they went rather than
only which way they fell. Two branches that both fall through are the same event to a direction
history and different events here.

**Two history registers, updated from different places:**

```
PHRT_new = (PHRT_old << 1) ^ T[31:2]      target address    100 bits
PHRB_new = (PHRB_old << 1) ^ B[5:2]       branch address     28 bits
```

PHRT is long and carries *where control went*; PHRB is short and carries *which branch it came
from*. Every table indexes on both.

**Six tables, four-way set associative**, 1024 sets each, on the paper's history lengths:

| table | 1 | 2 | 3 | 4 | 5 | 6 |
| --- | --- | --- | --- | --- | --- | --- |
| PHRT bits | 100 | 57 | 32 | 18 | 11 | 6 |
| PHRB bits | 28 | 28 | 28 | 18 | 11 | 6 |

Associativity matters more here than in a direct-mapped TAGE, because a path history aliases
differently: four branches sharing an index can each keep an entry. Each way holds a 13-bit tag, a
3-bit prediction counter, a 2-bit usefulness counter and a valid bit, over a 2048-entry bimodal
base.

**Recovery costs more than it does for a direction history, and this is the interesting part.** A
direction history is a pure shift, so undoing *k* branches is a right shift — which is exactly what
the tournament predictor does with the sequence numbers described
[below](#training-at-commit-and-rewinding-history). A path history is `(PHR << 1) ^ A`, which is
**not invertible without knowing A**. So both registers are checkpointed into a 256-entry file
indexed by the same sequence number the branch already carries, and recovery restores the
checkpoint and re-applies the branch with the target control actually took. That is why the
predictor is fed the resolved target on the recovery path at all.

## Why a perceptron corrector on top

The case for adding one is a measurement, not an aesthetic. Counters were added to split the
mispredictions into the two things that can go wrong, and they are not close:

| nqueens mispredictions | count |
| --- | --- |
| a tagged entry matched and was wrong | **36,535** |
| no tagged entry matched at all | 2,198 |

**94% of the misses are a table matching and giving the wrong answer.** More tables, longer
histories and bigger tables all attack the second row. None of them touches the first. A tagged
predictor answers from the single longest context that matches and commits to it — which is exactly
right when the context *determines* the outcome, and confidently wrong when it merely *correlates*.

The other predictor already in this tree does the opposite thing. A
[perceptron](https://www.cs.utexas.edu/~lin/papers/hpca01.pdf) never matches a context at all; it
**sums many individually weak correlations** and takes the sign. That is a worse answer when one
context really does determine the outcome, and a better one when no single context does. The
measurement said so directly, before any corrector existed — on nqueens, at a matched 64 KB:

| nqueens | accuracy |
| --- | --- |
| tournament (perceptron + gshare) | 76.9% |
| TAGE-M1 alone | 76.3% |
| **TAGE-M1 + corrector** | **80.6%** |

A far simpler predictor was **beating** the tagged one on that benchmark, and the
[component breakdown](#branch-prediction-accuracy) shows the perceptron was the half carrying it —
on its own it scored *above* the chooser there. The two families are not ranked; they are good at
different branches, and the combination beats both by more than the gap between them.

That is also why the corrector's bias tables are indexed by the TAGE's own prediction and its
confidence, rather than by the pc alone. What they learn is not "which way does this branch go" but
**"when the tables say weakly taken at this pc, what actually happens"** — the systematic error of
the tagged predictor, which is the only thing worth a second opinion.

So the corrector is the perceptron idea reused as a *second opinion* rather than as a standalone
predictor. It sums signed counters drawn from three families — a **bias** on the pc, on the pc with
the TAGE prediction, and on the pc with that prediction *and* how confident the tables were; **path**
GEHL banks folded from the same two path registers the TAGE indexes with; and **local** GEHL banks
over each branch's own recent outcomes, which is the one family the TAGE has no equivalent of.
It overrides the tagged prediction only when the magnitude of its sum clears an adaptive threshold,
so it stays silent on everything the TAGE already gets right.

The local-history family is worth isolating, because it is where the largest single gain comes
from and it is structurally unavailable to TAGE: TAGE indexes by *global* path, so a branch whose
own recent outcomes are regular while its global context never repeats is invisible to it. nqueens
is a backtracking search and is precisely that shape — the family is worth 2.8 accuracy points
there and a rounding error everywhere else.

Sizing, the ablations, and two implementation defects that made the corrector a net *loss* before
they were found, are in [Statistical Correction](#statistical-correction).

## The tournament predictor, as baseline

Still in the tree, not wired in, and the thing all three of the others are measured against.

A **perceptron predictor** ([Jimenez and Lin, HPCA 2001](https://www.cs.utexas.edu/~lin/papers/hpca01.pdf))
and a **gshare** predictor run in parallel, with a per-PC chooser deciding which to believe.

![image](https://github.com/user-attachments/assets/a88fff39-ef96-4a6d-b27d-6a73976f5192)

![image](https://github.com/user-attachments/assets/949eee24-9657-49f6-9703-cefa054b7aa6)

Geometry: 1024 perceptrons × 17 weights of 8 bits, 16 bits of global history, a 1024-entry gshare
table and a 1024-entry chooser.

### Training at commit, and rewinding history

The part that matters in an out-of-order machine is **when** the predictor is trained. A prediction
and its outcome are separated by an arbitrary number of cycles, and the tables move in between, so
the predictor hands back every piece of state it used — the table index, the history it dotted
against, whether the result was inside the training threshold, and what each component said. That
state rides with the branch through the reorder buffer and comes back **at commit**, which is both
in program order and on the correct path. Training therefore uses exactly the state that produced
the prediction rather than whatever happens to be current.

The global history register is speculative: it advances at predict time so that closely spaced
branches see each other, and is rewound on a misprediction from the history the offending branch
carried.

### Predicting in fetch, not decode

Direction is only half the problem. Knowing that a branch *will* be taken is worth nothing if you
find out a cycle after you already fetched the instructions behind it.

The first version of this design predicted in **decode**. A taken branch was recognised one cycle
too late, the sequential instructions behind it were already in the fetch buffer, and taking the
redirect flushed the buffer. Fetch supplies at most two words per cycle and rename consumes at most
two, so there was no slack to absorb the refill: the buffer ran dry. On a loop-dominated program
this costs very nearly **one lost cycle per taken branch**, and it was by a wide margin the largest
remaining inefficiency in the machine — 21% of coin's cycles.

A **branch target buffer** moves the decision into fetch. It is a 512-entry tagged table mapping a
pc to the target of the control instruction living there, probed with the address being fetched in
parallel with the instruction cache access for that same address. It answers the two questions
fetch needs — *is this a branch* and *where does it go* — from the pc alone, so the next fetch
address is already the target and **nothing on the wrong path is ever fetched**. There is nothing
to flush, and the fetch buffer keeps its contents straight across a taken branch.

Three details make it work:

- **It is filled from decode**, which is the first place the answers are actually known. A static
  branch misses once, is filled, and hits from then on. Direct branch and jump targets are a fixed
  function of the pc, so an entry never goes stale and a filled entry is always right. The tag is
  every pc bit above the index, so a hit is exact.
- **Decode still checks fetch's work.** Each fetch buffer entry records where fetch went after it;
  decode computes where it should have gone and redirects only when the two differ. That single
  comparison covers a target buffer miss, a stale target, and a cold branch uniformly.
- **`jr`/`jalr` never allocate.** Their target lives in a register and changes between executions,
  so a target buffer entry would be a guess fetch has no way to check. They keep taking their
  redirect from execute.

Delay slots need handling in both places now. If a predicted branch's delay slot did not come back
from the cache in the same cycle as its branch, the target is held in a pending register and fetch
spends one more cycle going sequentially to pick the delay slot up before redirecting.

The measured effect on coin, where this was diagnosed: fetch-starved cycles fell from **7,224,093
to 148,004** (a 98% reduction) and the entire 35.8 M instruction run raised exactly **one** decode
redirect. Cycles fell 34,162,087 → 28,492,663, **1.20×**.

Two indexing details are worth calling out, because getting them backwards costs a lot of accuracy:

- the **perceptron is indexed by PC alone** — the history is what the weights are dotted against, so
  folding it into the index as well scatters a single branch's weights across many rows and it can
  never learn one;
- **gshare is indexed by PC XOR history** — that is the whole idea of gshare.

---

# Register Renaming

Renaming turns every write-after-read and write-after-write dependence into nothing, leaving only
true read-after-write dependences, which is what makes a wide out-of-order window worth having.

![image](https://github.com/user-attachments/assets/08b2c3e7-3301-4921-99dd-292728afd216)

![image](https://github.com/user-attachments/assets/ebead8e1-23b0-4016-b5b0-e7a66c4efb3f)

Structure follows the MIPS R10000: a register map table, a free list of physical registers, a busy
table, and the reorder buffer acting as the active list. 64 physical registers back 32
architectural ones.

Physical register 0 is never allocated and never written, so it reads as a hard zero. The decoder
already clears `uses_r*` for architectural register zero, so every unused operand renames to that
tag and needs no special case anywhere in the back end.

**Misprediction recovery uses a reorder-buffer walk rather than a branch stack.** On a
misprediction the map is repaired by walking the squashed entries from youngest to oldest, putting
each one's previous mapping back. Because the walk visits younger entries first, the oldest write
to any architectural register lands last and wins — which is exactly the mapping that was live when
the branch issued. The free list rolls back by the number of squashed destinations, since those
tags were popped in order and nothing has pushed over them. It all happens in a single cycle and
needs no snapshot storage at all.

---

# Out of Order Execution

- **128-entry reorder buffer**, **32-entry issue queue**, **32-entry load/store queue**
- 4-wide rename/dispatch/commit, 4 issue ports, 4 ALUs, 1 memory port
- Single-cycle execute with no bypass network

> **This section describes the machine as first built: 64-entry reorder buffer, 16-entry load/store
> queue, 2-wide, 2 ALUs.** The mechanisms below are unchanged, but every size has since moved, and
> the two widenings were the largest wins in the project. How each size was arrived at is in
> [What actually bounds the window](#what-actually-bounds-the-window) and
> [Going Four Wide](#going-four-wide-and-what-memory-actually-costs).

**Wakeup needs no CAM.** The physical register file is written at the end of the cycle an
instruction executes and read asynchronously, so a result produced in cycle N is readable in cycle
N+1, and the busy table clears on the same edge. Readiness is therefore just a combinational look
at the busy bits of the two source tags, and dependent instructions still issue back to back.

**Select is oldest-first.** Age is the distance between an entry's reorder buffer index and the
reorder buffer head, so it stays correct across wraps and needs no age matrix.

### Delay slots

MIPS executes the instruction after a branch whichever way the branch goes, and that shapes several
rules:

- the front end will not redirect until the delay slot has been accepted — if it is already in the
  decode group both are taken and the redirect happens immediately, otherwise the target is
  remembered and applied after the next cycle accepts the delay slot;
- **a branch is not allowed to issue until its delay slot has been dispatched.** That guarantees the
  delay slot is already in the reorder buffer, so recovery can simply squash everything from the
  branch's index + 2 onwards.

### Memory ordering

- Stores never touch the cache speculatively. A store computes its address and data when it issues,
  sits in the queue, and is written to the cache only when the reorder buffer retires it — so a
  squashed store cannot have changed memory.
- A load may issue ahead of an older store whose address is not known yet. That is a guess, checked
  when the store resolves — see [memory dependence
  speculation](#speculating-on-memory-dependences).
- A load matching an older store in the queue takes its value straight from the queue
  (**store-to-load forwarding**); the youngest matching older store wins.

The D-cache port is **pipelined**. The cache addresses its SRAM from `addr_next` and compares tags
against `addr`, which are a cycle apart, so an access can be set up in the same cycle the previous
one completes — the cache has always been able to accept an address every cycle. The original queue
walked every access through `M_IDLE → M_LOAD → M_IDLE`, which meant even a **hit** occupied the port
for two cycles and capped memory throughput at 0.5 accesses per cycle. Replacing that state machine
with a one-deep pipeline register removes the idle cycle and doubles the ceiling. A stalled access
holds its own address on `addr_next` so the SRAM read is set up again for when the refill finishes.

Because the cache is [non-blocking](#non-blocking-data-cache), an access gets one of three answers
in the cycle it is presented, and only the third keeps the port:

| answer | meaning |
| --- | --- |
| `dc_out.valid` | it hit; the access is finished |
| `dc_miss_pending` | it missed and register `dc_mshr_id` has taken on the fill. The access leaves the port immediately and its queue entry is marked *waiting*; `dc_fill_valid` later announces that id, every entry waiting on it is marked for *replay*, and the queue puts it back on the port, where it hits |
| neither | the cache could not take it. The access stays on the port and is presented again |

Waiting lives in the queue entry rather than on the port, which is what lets several loads be
outstanding at once. A committing store that misses parks the same way, keeping `st_valid` asserted
in the reorder buffer instead of holding the port for the whole refill.

`jr`/`jalr` targets come out of a register, so they are resolved at execute and redirect through the
same recovery path as a mispredicted branch. Direct `j`/`jal` are resolved by the front end.

### Speculating on memory dependences

The rule this replaces was the conservative one: a load waits until **every** older store has
computed its address, and is then disambiguated exactly, so no replay mechanism is ever needed. It
is correct by construction and it is cheap — except when there is nothing else to run.

Measuring that directly is what justified changing it. Counting the cycles where *nothing at all is
ready to issue* **and** at least one load has both its operands and is held only by this rule:

| benchmark | a load held by the rule | *and nothing else ready to issue* |
| --- | --- | --- |
| quickSort | 991,094 (21.9%) | **854,588 (18.9%)** |
| coin      | 1,576,494 (6.0%) | **0** |
| nqueens   | 43,334 (5.7%) | **0** |
| esift2    | 3,131 (0.1%) | 3 |

The second column is the whole story. coin holds a load 6% of the time and it never costs a cycle,
because something else is always ready to take the slot. quickSort has nothing else.

**Loads therefore issue past unresolved stores, and the store checks the guess when it resolves.**
The check has to happen in the cycle the store's address appears, because a load that has already
issued has already chosen where its data comes from — at issue, from the forwarding search. So when
a store computes its address, the queue scans for younger loads that already have an address and hit
the same word. The oldest offender wins; squashing it takes the younger ones with it.

One refinement keeps the check exact rather than merely safe. A load that forwarded from a store
*younger* than the one resolving now already holds the right value — that younger store is the last
write to the word before it — so each load records which store it forwarded from, and those are not
violations.

The violation signal is **registered before it leaves the queue**, and that is not optional: the
squash it raises reaches the issue queue, which is what produced the store issue that detected it,
so passing it out combinationally would close a loop. Waiting a cycle costs nothing, because the
load cannot commit in the meantime — the store that caught it is older and has not committed either.

#### Recovery, and the delay slot

A memory order violation is anchored differently from a mispredicted branch. A branch **survives**
its own recovery: it and its delay slot are kept and fetch is redirected to the target. A violating
load must **die**, because its physical register already holds the wrong value, so recovery
re-fetches from the load's own pc.

Except that a load in a delay slot has no reachable pc of its own. Control only arrives there
through its branch, and re-fetching from it would run on to pc + 4 instead of the branch target. So
when the entry before the load is a control transfer, the squash is anchored on the **branch**
instead, which simply re-executes. This is not a corner case: on nqueens, **20 of 42** forced
violations took that path.

#### The brake

Left alone, a load that aliases a store would violate on every execution and speculation would cost
more than it saves. The predictor is one bit per load pc — 1024 entries, set when that load is
caught, read at dispatch — and a load whose bit is set goes back to waiting for every older store.
Almost all violations come from a handful of static loads, so one bit each is enough. The table is
cleared every 65,536 cycles so that an aliasing pc, or a phase that has ended, does not disable a
load for the whole run.

#### What it is worth

| benchmark | conservative | speculative | gain | speculative loads | violations |
| --- | --- | --- | --- | --- | --- |
| quickSort | 4,528,689  | **4,235,844**  | **1.069×** | 22,990 | **0** |
| nqueens   | 764,041    | 763,961        | 1.000×     | 87     | 0 |
| esift2    | 4,835,486  | 4,835,486      | 1.000×     | 1      | 1 |
| coin      | 26,211,879 | 26,212,489     | 1.000×     | 45,309 | 0 |

It is a one-benchmark change, and the idle-cycle count above predicted exactly that. It is worth
6.9% on quickSort and nothing anywhere else — and on coin, where 45,309 loads do issue
speculatively, the effect is 610 cycles in 26 M, because unblocking those loads only makes them
queue up behind an issue width that was already full. `ready_mem_ge2` on coin rises from 7.5% of
cycles to 12.0%; `issue_0` does not move.

Not one of the four benchmarks produces a violation in normal operation except esift2's single one.
That is the point — real code does not alias here — but it also means the recovery path would
otherwise never be tested.

#### Testing a path that never runs

`MDP_STRESS` drops the address comparison, so **every** store that resolves behind an issued load
reports a violation. The golden traces still have to match:

| benchmark | violations | delay-slot anchored | cycles | trace |
| --- | --- | --- | --- | --- |
| nqueens   | 42  | **20** | 764,396   | clean |
| quickSort | 162 | —      | 4,521,096 | clean |
| esift2    | 1   | —      | 4,835,486 | clean |

The quickSort row is the useful one for a second reason. Under a pathological violation rate the
predictor learns to stop speculating — 22,990 speculative loads collapse to 493 — and the cycle
count returns to 4,521,096 against a conservative 4,528,689. The mechanism degrades to its own
baseline rather than below it, which is the property that makes speculating here safe to leave on.

---

# Non-blocking Data Cache

The original data cache ran one miss at a time. An access that missed took the whole cache into a
refill state machine, and every later access -- including ones that would have hit -- waited out
the full memory latency behind it. On quickSort that was **22,179 misses at 112 cycles each, 47% of
the entire run, none of them overlapping**.

**Miss status holding registers** (Kroft, 1981) remove that. Each register records one line fill
that is in flight: its address and the way it will land in, and nothing else. On a miss the cache
allocates one and answers *pending* rather than stalling, so the very next cycle it can serve a hit
or take another miss. Four fills can be outstanding, and their latencies overlap.

Three things make this tractable here:

- **Replies do not have to be matched to registers.** Reads on one AXI id are returned in order, so
  the registers are a FIFO and returning data always belongs to the entry at the head.
- **A second access to a line already in flight merges** into the existing register instead of
  allocating a new one, and shares its memory request. On quickSort 41,550 of 63,729 parked
  accesses -- 65% -- are merges.
- **Dirty evictions are decoupled.** The victim line is copied out of the data banks into a
  writeback queue in the same cycle the miss is taken, and the way is invalidated immediately, so
  the refill can land whenever it likes and the queue drains to memory on its own.

The requests *waiting* on a fill are not tracked in the cache at all -- that is the load/store
queue's job, described under [memory ordering](#memory-ordering). Keeping the wait list out of the
cache is what keeps a register down to a tag, an index and a way.

### The two rules that have to be enforced by hand

**Writebacks can be overtaken.** The memory model delays writes by 120 cycles and reads by 100, so
a read issued after a write to the same address can still beat it to memory and return stale data.
An access whose line is sitting in the writeback queue is therefore *refused* until that writeback
has been acknowledged, and the queue simply presents it again.

**A way that a fill is aimed at cannot be picked again.** Victim selection skips any way already
reserved by a valid register at that index; otherwise two fills for different lines would land in
the same way, or one line would end up resident in two ways at once. With four ways and four
registers this can leave no legal victim, in which case the miss is refused and retried -- which
happened **twice** in the whole of quickSort.

### What it is worth

| benchmark | blocking cache | non-blocking | gain |
| --- | --- | --- | --- |
| quickSort | 5,240,726  | **4,528,689**  | **1.157×** |
| nqueens   | 807,339    | **764,041**    | 1.057× |
| coin      | 27,294,090 | **26,211,879** | 1.041× |
| esift2    | 4,834,600  | 4,835,486      | 0.9998× |

quickSort is the benchmark this was built for and gains the most, but the change is not only about
misses: nqueens takes 96 D-cache misses in its entire run and still gains 5.7%, and coin takes 29
and gains 4.1%. That part is the port discipline the rewrite allowed. A miss no longer stalls, so
the queue no longer has to gate *all* memory issue on the port being free -- a memory operation may
now issue whenever the load writeback port is not about to be contended, and only loads that
actually need the cache wait for a slot. On coin that alone drops `rename_stall` from 3,225,107 to
2,104,286.

esift2 loses 886 cycles out of 4.8 M, one part in 5,500, from the occasional cycle the port is held
back so a forwarded load can use the writeback port. It takes 783 misses in the whole run, so there
is nothing there for the registers to recover.

Measured on quickSort, where the overlap actually happens:

| | cycles | share of run |
| --- | --- | --- |
| at least one fill outstanding | 1,884,974 | 41.6% |
| two or more outstanding | 509,445 | 11.2% |
| a load parked waiting on a fill | 1,831,430 | 40.4% |
| registers full, forcing a miss to be refused | 0 | -- |

Those 22,179 fills carry 2.48 M cycles of memory latency between them, and they now fit inside a
1.88 M cycle window -- and, unlike before, the core keeps retiring instructions throughout it. The
registers themselves are never the constraint: four is already as many reads as the memory model
will accept on one id.

---

# Hardware Prefetching

A next-line prefetcher with a Jouppi-style **stream buffer** sits beside the instruction cache on
its own memory read port (read master id 2).

![image](https://github.com/user-attachments/assets/d619eeec-c238-4fb5-b9d0-15bc34627fa6)

Instruction fetch is overwhelmingly sequential and a miss costs about a hundred cycles of memory
latency, so the buffer keeps a window of consecutive lines running ahead of the program counter.
When fetch misses in both structures the stream restarts just past the line that missed; when fetch
lands on a line the buffer holds, the words go straight to the front end.

**The requests are pipelined, and this is the whole point.** A single outstanding request only ever
puts the buffer one line — four instructions — ahead, which is worthless cover against a hundred
cycle miss. The memory model accepts four reads per master id and answers them in order, so up to
four lines are kept in flight and their latencies overlap. A restart abandons the lines already in
flight by bumping a generation counter; replies whose generation no longer matches are dropped on
arrival.

The instruction cache still refills normally in the background, so lines become resident there and
a loop that fits will hit in the cache on its next pass. The buffer only covers the streaming case
the cache is bad at.

The I-cache is 2-way set associative with LRU replacement, and returns several contiguous words per
fetch to feed a front end wider than decode. It has since grown to 8 KB on 8-word lines with
`FETCH_WIDTH` 8 — see [eight-word lines](#eight-word-lines-and-a-cache-result-that-went-the-other-way).

**There is now a data-side prefetcher too**, on branch `tage-sc-l`, built very differently and for
reasons the [negative result below](#what-the-prefetchers-are-worth) explains — see
[the prefetcher](#the-prefetcher-which-this-file-called-a-dead-end).

---

# Statistical Correction

The predictor on this branch is the Firestorm shaped TAGE of `tage_m1.sv` with the **SC of
TAGE-SC-L** bolted to it (`statistical_corrector.sv`). It is the one structure here built without
regard to the 64 KB budget the three compared predictors were held to.

### Why a corrector rather than a bigger TAGE

A tagged predictor answers a branch by finding the longest history that has seen this exact context
before and replaying what happened. It fails in one specific way: when the context matches but the
outcome is only *correlated* rather than determined, the entry commits to an answer and is
confidently wrong. Counters were added to separate the two failure modes, and they are not close:

| nqueens mispredictions | count |
| --- | --- |
| a tagged entry matched and was wrong | **36,535** |
| no tagged entry matched at all | 2,198 |

94% of the misses are the first kind, and no amount of extra tables or history touches them. The
corrector answers the same branch a different way -- many weakly correlated signed counters summed,
perceptron style, with the sign of the sum as a second opinion -- and overrides the TAGE only when
the magnitude clears an adaptive threshold, so it stays silent on branches the TAGE already has.

Three families: **bias** tables indexed by pc, then by pc with the TAGE prediction, then with its
confidence; **path** GEHL banks folded from the same two path history registers the TAGE indexes
with; and **local** GEHL banks over a per branch history of that branch's own recent outcomes.

### What the local family is worth

| | full corrector | no local history |
| --- | --- | --- |
| nqueens   | **587,259** / 80.58% | 606,238 / 77.75% |
| quickSort | 2,863,656 / 87.61% | 2,860,652 / 87.65% |
| esift2    | 3,296,264 / 98.53% | 3,295,359 / 98.54% |

It is almost entirely an nqueens component -- worth 2.8 accuracy points and 1.032x there, and a
rounding error *against* on the other two. That is the shape to expect: it is the one family with no
equivalent in the TAGE, because TAGE indexes by global path, and a branch whose own recent outcomes
are regular while its global context never repeats is invisible to it. nqueens is a backtracking
search and is exactly that.

### The bug that made the corrector a net loss

The first version recomputed the sum at commit from the checkpointed path history. The indices
recovered that way are correct, but the *contents* are whatever every branch since has trained into
them, so the perceptron rule and the adaptive threshold were both learning from a number the
machine never acted on. Measured against `tage_only_correct`, a counter recording what the TAGE
alone would have answered:

| corrector net effect | recomputed sum | sum carried from prediction |
| --- | --- | --- |
| nqueens   | +7,095  | +7,003 |
| quickSort | +2,908  | +3,441 |
| esift2    | **-83** | +549 |
| coin      | **-16,186** | **+17,703** |

It was a net *loss* on coin, the benchmark where the TAGE is right 98.8% of the time and the
threshold most needed to learn to stay quiet. The fix is the trick the path history already uses:
carry the sum down the pipeline in a file indexed by the sequence number the branch is already
stamped with. That also deletes the commit-side sum entirely -- only the indices need recomputing.
A useful check that it worked: the override counters now reconcile exactly with
`bp_correct - tage_only_correct`, which they did not before.

### Result

Every predictor below is trace-verified on all four benchmarks. The first three are held to 64 KB;
the last is ~90.6 KB, of which 29 KB is the corrector.

| benchmark | tournament | TAGE | TAGE-M1 | TAGE-M1 + SC |
| --- | --- | --- | --- | --- |
| nqueens   |    613,396 / 76.88% |    635,432 / 73.40% |    617,156 / 76.26% | **587,259 / 80.58%** |
| quickSort |  2,916,578 / 86.63% |  2,874,266 / 87.00% |  2,865,268 / 87.32% | **2,863,656 / 87.61%** |
| esift2    |  3,296,052 / 98.53% |  3,306,491 / 98.42% |  3,299,695 / 98.49% |   3,296,264 / 98.53% |
| coin      | 17,157,529 / 98.04% | 16,838,092 / 98.50% | 16,468,716 / 98.82% | **16,429,702 / 99.07%** |

**1.027x geometric mean over the tournament predictor**, of which the corrector itself is 1.013x.

### One allocation defect worth recording

Before the corrector was built, instrumenting *where* the TAGE allocates found that 26% of nqueens'
allocations were going into table 0 -- 100 bits of path history -- which provides **zero**
predictions in the entire run. Half went into the two tables that between them serve 0.3% of that
benchmark's predictions. The cause was allocating uniformly at random among every table with a
longer history than the provider, where Seznec's TAGE allocates into the *nearest* longer table with
a decaying skip probability. On a backtracking search a 100-bit path never repeats, so the entry is
written and never read. Fixing it moved nqueens 617,156 -> 612,957 and dropped table 0 allocations
9,928 -> 596.

Worth recording because the accuracy only moved 0.1 points: the wasted allocations were real, and
they were not what the gap to the perceptron was made of. The corrector was.

---

# Going Four Wide, and What Memory Actually Costs

Four changes, in the order the counters asked for them. Three of the four
reverse a conclusion recorded earlier in this file, and in every case the
earlier verdict had been measured on a materially different machine.

### Four wide, which was supposed to be a dead end

The entry under [what actually bounds the window](#what-actually-bounds-the-window)
said 4-wide was not worth building, on the grounds that three or more
instructions were ready on only 8.8% of coin's cycles. That was measured
against a **64-entry reorder buffer behind a 2-wide front end**. With a 128
entry window and a 3-wide front end filling it, the same counter reads 68% on
esift2, and `issue_3` -- the machine issuing its full width -- fires on 68% of
its cycles. It was at the ceiling two cycles in three.

`FE_WIDTH` and `ISSUE_WIDTH` turned out to be fully parameterised already: the
ALUs are a generate loop, the register file ports scale as `2 * W` read and
`W + 1` write, and rename and commit loop over `FE_WIDTH`. The change is two
parameters and three statistics counters.

| benchmark | 3-wide | 4-wide | speedup |
| --- | --- | --- | --- |
| coin      | 16,429,702 | **12,838,826** | **1.280x** |
| esift2    |  3,296,264 |  **2,696,938** | **1.222x** |
| nqueens   |    587,259 |    **535,271** | 1.097x |
| quickSort |  2,863,656 |  **2,741,565** | 1.045x |

esift2's free list stall -- 447,156 cycles, and 100% of its dispatch stalls at
3-wide -- went to **zero**, because at 4-wide instructions retire fast enough
to recycle their own tags. A `PHYS_REGS` 192 experiment was queued to fix that
stall and was abandoned unfinished, since the number it would have reported no
longer meant anything.

### The data cache line, and then its capacity

Both are quickSort's, and they compound. The instruction cache halved its own
misses when it went to 8-word lines; the same change on the data side does the
same thing for the same reason.

| quickSort | cycles | IPC | D-cache misses |
| --- | --- | --- | --- |
| 16 KB, 4-word lines | 2,732,905 | 1.50 | 87,593 |
| 16 KB, 8-word lines | 2,630,100 | 1.56 | 72,846 |
| **32 KB, 8-word lines** | **2,469,870** | **1.66** | **53,253** |

**1.107x for no extra capacity in the first step and one doubling in the
second.** esift2 is indifferent to the capacity -- its working set fits either
way -- and 64 KB buys another 1.065x on quickSort alone, which is not obviously
worth the area.

### A second AXI id, which fixed the structure and bought nothing

`Dmiss_regs_full` was 205,478 cycles, 7.2% of quickSort's run, with 12,581
misses refused outright, and this file called it "the clearest remaining
ceiling on the one memory-bound benchmark". The memory model allows four
outstanding reads **per AXI id**, so the fix is a second id: requests alternate
between ARID 1 and ARID 3, and `NUM_MSHR` goes to 8.

| quickSort | before | after |
| --- | --- | --- |
| cycles | 2,863,656 | 2,859,460 (**1.0015x**) |
| `Dmiss_regs_full` | 205,478 | **0** |
| `Dmiss_refused` | 12,581 | **14** |
| `Dmiss_inflight` | 1,007,068 | 999,208 |

The registers never fill again and no miss is ever refused again, and it is
worth **0.15%**. `Dmiss_inflight` barely moves, which is the whole story: the
misses were already overlapping as far as the *program* allows. They are
dependent, so more capacity finds no more independent misses to run in
parallel. This is the same trap as coin's `stall_lsq`, in the memory domain --
**a full structure is not automatically a cost.**

It is kept because it is correct, costs nothing, and removes a cap that would
otherwise distort every later memory measurement.

Fills still retire in allocation order; the younger channel's data waits on the
bus with RREADY low. That is not free in principle, because `memory_arbiter`'s
read data splitter is one shared pipeline register for every read master, so a
held beat blocks the instruction cache behind it. It was measured rather than
assumed: esift2 is **cycle identical** with and without the second channel, and
quickSort is faster with it.

### The prefetcher, which this file called a dead end

It was a dead end. The note read: 0.002% on esift2, *negative* on nqueens, 13
prefetches across all of coin, deleted from `d_cache.sv`. The same note also
recorded that the miss addresses were highly predictable -- 51.3% same-delta on
quickSort, 99.5% on esift2 -- so **prediction was never what failed. Absorption
was.** The cache was blocking, with four registers on one id, so a prefetch
could only ever take a resource a demand miss was about to need.

That is no longer true, so `d_prefetcher.sv` is built the other way round: a
structure off to the side with its own storage, its own AXI id and its own
port, never competing for a miss register. It is asked about a line only when
the cache takes a demand miss, and on a hit the whole line is handed over in
one cycle and latched into the register, turning a hundred cycle miss into a
fill that starts immediately. It never installs into the cache and never probes
the cache's tags -- so it cannot put two ways of a set under one tag, and it
does not need the bank read port the demand path owns.

Two engines feed one queue. **Spatial**: a table of streams matched by nearness
rather than by pc, since the cache is never told which instruction missed; a
repeated delta promotes a stream to confident and it runs `DEGREE` lines ahead.
**Temporal**: a table remembering which line missed after which, for the
repeats a stride cannot catch.

| | before | after | prefetch hit rate |
| --- | --- | --- | --- |
| quickSort | 2,469,870 | **2,154,366** (1.146x) | 69% |
| esift2    | 2,655,842 | **2,615,127** (1.016x) | **99.2%** |
| nqueens   |   531,470 |   **527,256** (1.008x) | 84% |

#### The bug the counters found

The first working version was worth 0.15% on quickSort, and `pf_spatial` said
why: a confident stream had been detected **7,806 times** and the prefetcher had
issued **146 requests**. There was no replacement policy. A slot is released
when a demand miss takes its line, so a prefetch nobody asks for holds one
forever; sixteen of those and the buffer is full for the rest of the run.

esift2 hid the bug completely, at a 99.2% hit rate, because its stream is
exactly sequential and every line it fetches is demanded. Adding a round robin
victim took quickSort's `pf_hit` from 41 to 5,527 and `Dmiss_inflight` from
563,768 to 233,806; going from 16 slots to 64 took `pf_no_slot` from 51,717 to
4,134 and was worth another 1.027x.

### What a squash actually costs, and where quickSort ends up

`squash_refill` counts the cycles between a redirect and rename getting an
instruction in again. It was added to decide whether to spend on the predictor
or on the pipe in front of it, and it answered immediately:

| | squashes | refill cycles | per squash |
| --- | --- | --- | --- |
| nqueens   |  36,420 |  41,512 | **1.14** |
| quickSort | 126,422 | 131,045 | 1.04 |
| esift2    |  18,790 |  19,585 | 1.04 |

**The front end recovers from a redirect in about one cycle.** A 32-deep fetch
buffer at `FETCH_WIDTH` 8, with the target buffer redirecting in fetch, refills
essentially immediately. So the entire cost of a misprediction is wrong-path
work already dispatched, and shortening the redirect path would gain nothing.
That retired a plan to do exactly that.

What it costs instead is visible in the dispatch counters. On quickSort the
front end offers 0/1/2/3/4 instructions on 248,284 / 180,959 / 372,946 /
484,147 / 868,021 cycles, which sums to the cycle count; dispatch pushed
**5,508,199** instructions and only **4,103,867** committed.

**1,404,332 dispatched instructions -- 25.5% of everything the machine did --
were thrown away**, at 123,250 squashes and ~11.4 instructions each. Against
that, `Dmiss_inflight` is 7.7% of cycles and `rename_stall` 4.0%. Memory went
from 36% of quickSort's cycles to under 8%; misprediction is now the whole
remainder, and `wrong_prov` is 123,249 of 123,387 -- 99.9% of the misses are a
tagged entry matching and being wrong.

There is a second, harder ceiling underneath it. The front end offers 2.716
instructions per cycle on average and a full four on only 40% of cycles, with
`fe_line_edge` firing 1,278,852 times -- a fetch starting mid-line gets only the
words to the end of it, and every redirect lands at an arbitrary pc. So even
perfect branch prediction would leave quickSort near 2.7 IPC. Its branches are
comparisons on unsorted data; 87.6% is close to what is there.

### The load/store queue, and the same trap for the third time

At 4-wide, coin's `stall_only_lsq` reads **3,415,793 cycles -- 26.6% of its
run**, by far the largest single stall left anywhere in the suite, and the
obvious last thing to fix. `LSQ_ENTRIES` 32 -> 64:

| coin | LSQ 32 | LSQ 64 |
| --- | --- | --- |
| `stall_only_lsq` | 3,415,793 | **gone** |
| `stall_only_iq` | 195,795 | **3,593,966** |
| cycles | 12,836,687 | 12,836,677 |

**3.4 million cycles of stall relieved, worth ten cycles.** The backlog moved
one structure along and nothing else changed. esift2 gained 348 cycles,
quickSort was identical to the cycle, nqueens gained 897. Reverted.

This is the third instance in this section alone -- coin's load/store queue
here, quickSort's miss status registers at 0.15%, and the 256-entry window that
left esift2 identical to the cycle. **Relieving a full structure buys nothing
unless there is independent work waiting behind it.** The counter tells you
where the queue ends, not why. It is the most repeated mistake on this project
and it survives being written down, so: attribute *what is being waited on*
before scaling anything.

### A very large window, which is the weakest of the four

Apple-style: `ROB_ENTRIES` and `PHYS_REGS` both to 256.

| | ROB 256 + PRF 256 |
| --- | --- |
| quickSort | 2,419,808 (**1.021x**) |
| esift2 | **identical, to the cycle** |
| nqueens | identical |

`stall_only_rob` went from 234,022 to 1,463, and `stall_only_iq` rose from
187,657 to 239,499. The backlog moved one structure along. A deeper window only
pays if there is independent work behind the miss, and on the one benchmark
that misses, there is not.

---

# Results

Measured on this repository with the command in [Simulation](#simulation). The correctness bar is
the harness itself: `verilator_main.cpp` diffs every committed pc, write-back and load/store event
against the golden traces in `hexfiles/`, and aborts on the first mismatch. **All benchmarks below
run to completion with all three streams matching.**

Cycle counts, lower is better. Instruction counts match the baseline exactly on every benchmark,
so cycles and CPI carry all the information.

| benchmark | baseline (in-order) | + caches | + front end | + non-blocking | + memory spec. | + window sizing | + wide fetch | **+ 3-wide** | speedup | IPC |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| nqueens   | 1,722,402  | 890,370    | 807,339    | 764,041    | 763,961    | 763,332    | 757,970    | **618,655**    | **2.78×** | 1.64 |
| quickSort | 9,572,553  | 5,492,808  | 5,240,726  | 4,528,689  | 4,235,844  | 3,495,796  | 3,400,154  | **2,910,430**  | **3.29×** | 1.41 |
| esift2    | 21,375,975 | 5,814,714  | 4,834,600  | 4,835,486  | 4,835,486  | 4,835,133  | 4,557,362  | **3,294,956**  | **6.49×** | **2.38** |
| coin      | 35,944,392 | 34,162,087 | 27,294,090 | 26,211,879 | 26,212,489 | 25,207,827 | 21,405,644 | **17,160,099** | **2.09×** | **2.08** |

Geometric mean **3.34×**, with two benchmarks past IPC 2.0 against a ceiling that is now 3.0. The
last column also folds in eight-word instruction cache lines with `FETCH_WIDTH` 8.

**Branch `tage-sc-l` carries this further.** With the TAGE-SC-L predictor, a 4-wide machine, a
32 KB data cache on 8-word lines, eight miss registers across two AXI ids and a working data
prefetcher — all documented in [Statistical Correction](#statistical-correction) and
[Going Four Wide](#going-four-wide-and-what-memory-actually-costs):

| benchmark | in-order baseline | 3-wide above | **branch `tage-sc-l`** | speedup | IPC (ceiling 4.0) |
| --- | --- | --- | --- | --- | --- |
| nqueens   | 1,722,402  |    618,655 |    **527,256** | **3.27×** | 1.93 |
| quickSort | 9,572,553  |  2,910,430 |  **2,154,366** | **4.44×** | 1.90 |
| esift2    | 21,375,975 |  3,294,956 |  **2,615,127** | **8.17×** | **3.00** |
| coin      | 35,944,392 | 17,160,099 | **12,836,687** | **2.80×** | **2.79** |

Geometric mean **4.27×** over the in-order baseline. esift2 and coin sit at 75% and 70% of a
4-wide ceiling. nqueens and quickSort are both limited by branch misprediction and nothing else:
quickSort dispatches 5,508,199 instructions to commit 4,103,867, so a quarter of everything the
machine does is thrown away on wrong paths, against memory at under 8% of cycles.

The columns are
cumulative: the out-of-order core at the original 2 KB
caches, then 8 KB instruction cache and 4-way 16 KB data cache, then prediction moved into fetch
with a branch target buffer and the D-cache port pipelined, then the data cache made non-blocking,
then loads allowed to speculate past unresolved stores, then the window sized against
[measured stall attribution](#what-actually-bounds-the-window) rather than guesswork —
`PHYS_REGS` and `ROB_ENTRIES` to 128, `LSQ_ENTRIES` to 32 — then
[fetch made wider than decode](#fetching-wider-than-decode), and finally the whole machine
[widened to three](#going-three-wide) once fetch could feed it.

The last four columns are worth isolating, since they are where the recent work went:

| benchmark | before front end work | + BTB in fetch | + pipelined D-cache port | + non-blocking D-cache | + memory spec. | + window sizing | + wide fetch | total |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| nqueens   | 890,370    | 860,124    | 807,349    | 764,041    | 763,961    | 763,332    | **757,970**    | **1.17×** |
| quickSort | 5,492,808  | 5,273,026  | 5,239,953  | 4,528,689  | 4,235,844  | 3,495,796  | **3,400,154**  | **1.62×** |
| esift2    | 5,814,714  | 4,834,598  | 4,834,598  | 4,835,486  | 4,835,486  | 4,835,133  | **4,557,362**  | **1.28×** |
| coin      | 34,162,087 | 28,492,663 | 27,294,122 | 26,211,879 | 26,212,489 | 25,207,827 | **21,405,644** | **1.60×** |

The changes are almost disjoint in what they fix, which is why each was worth doing separately.
esift2's entire gain is the BTB. coin's is mostly the BTB with a tail from the memory port becoming
free to issue into. quickSort gains from none of the front-end work and from both memory changes,
and it is the only benchmark that gains from the last column at all — which is exactly what the
idle-cycle measurement predicted before any of it was built.

### Where the time goes

Splitting cycles into memory stall (I-cache + D-cache miss cycles) and everything else shows what
the out-of-order core is and is not doing. Measured at the stock 2 KB caches, so the two columns
are comparable:

| benchmark | | baseline | out-of-order | ratio |
| --- | --- | --- | --- | --- |
| nqueens | memory stall | 585,606 | 753,382 | 0.78× |
| | everything else | 1,136,796 | 856,514 | **1.33×** |
| quickSort | memory stall | 4,899,827 | 4,886,487 | 1.00× |
| | everything else | 4,672,726 | 2,854,002 | **1.64×** |
| esift2 | memory stall | 12,898,616 | 12,898,636 | 1.00× |
| | everything else | 8,477,359 | 4,355,688 | **1.95×** |

On the cycles where memory is not stalling the machine reaches 1.33× to 1.95× — esift2 is
essentially the theoretical maximum for a 2-wide core. Memory stall cycles are untouched at this
point in the history, because both caches were still blocking and the load/store queue serviced one
access at a time: a miss stalled exactly as hard as it did in order. That is the column the
[non-blocking data cache](#non-blocking-data-cache) went after, and it is why quickSort — the one
benchmark whose "everything else" column was already good and whose memory column was flat — was
the one that gained most from it.

That is the whole story of this design. The out-of-order core roughly halves the compute half of
the workload and can do nothing at all about the memory half, so what each benchmark gains depends
entirely on its mix.

### Cache capacity and associativity

The caches turned out to be worth more than the entire out-of-order back end. Each change below is
a parameter, measured on top of the design as it stood:

| change | benchmark | before | after | gain |
| --- | --- | --- | --- | --- |
| I-cache 2 KB -> 8 KB | nqueens | 1,609,772 | 890,282 | **1.81×** |
| D-cache 2 KB -> 8 KB | quickSort | 7,740,489 | 6,233,906 | 1.24× |
| | esift2 | 17,254,324 | 14,431,835 | 1.20× |
| D-cache 2-way 8 KB -> 4-way 16 KB, true LRU | quickSort | 6,233,906 | 5,492,808 | 1.13× |
| | esift2 | 14,431,835 | **5,814,714** | **2.48×** |

esift2's D-cache miss cycles fall from 9,754,499 to 85,357, a **114× reduction**; nqueens'
I-cache miss cycles fall from 742,759 to 16,807, a 44× reduction. Both were capacity and conflict
misses, and in both cases the working set crossed a cliff rather than improving gradually.

The replacement policy had to change with the associativity. The original single `lru_rp` bit per
set is exact LRU for two ways and meaningless for four, so it is now a per-set recency permutation
(`lru_age`) with invalid ways preferred as victims.

### What the prefetchers are worth

> **Superseded on branch `tage-sc-l`.** The data-side conclusion below was correct for the machine
> it was measured on — a *blocking* cache with four miss registers on one AXI id, where a prefetch
> could only ever take a resource a demand miss was about to need. Rebuilt as a structure off to
> the side with its own storage and its own id, against a non-blocking cache, the same idea is
> worth **1.146× on quickSort** at a 69% hit rate and 99.2% on esift2. The table below also records
> that the miss addresses were highly predictable all along, which is exactly the clue that
> prediction was never the thing failing. See
> [the prefetcher](#the-prefetcher-which-this-file-called-a-dead-end).

Nothing measurable, on either side of the machine, *at the time this was written*.

| prefetcher | benchmark | D-cache | with | without | difference |
| --- | --- | --- | --- | --- | --- |
| D-cache stride | quickSort | 16 KB | 5,492,808 | 5,496,366 | 0.065% |
| | esift2 | 16 KB | 5,814,714 | 5,814,715 | 1 cycle |
| | nqueens | 8 KB | 890,370 | 890,282 | **-0.010%** |
| | quickSort | 8 KB | 6,259,582 | 6,265,445 | 0.094% |
| | esift2 | 8 KB | 14,533,079 | 14,533,324 | 0.002% |

The 8 KB rows were run specifically to test the obvious hypothesis — that a prefetcher earns its
keep once the cache is under real capacity pressure — and it does not hold. At half the capacity,
with esift2 taking **114× more D-cache misses**, the prefetcher still recovers 0.002% of its
cycles. On nqueens it is very slightly *negative*. Across the whole of coin it issues 13
prefetches.

Shrinking the cache to pay for the prefetcher is a losing trade in both directions:

| benchmark | 4-way 16 KB | 4-way 8 KB | cost of halving |
| --- | --- | --- | --- |
| nqueens   | 890,370   | 890,370    | none — working set fits either way |
| quickSort | 5,492,808 | 6,259,582  | **1.14×** |
| esift2    | 5,814,714 | 14,533,079 | **2.50×** |

esift2's working set sits between the two sizes, and crossing that cliff costs 8.7 M cycles —
roughly 35,000 times what the prefetcher recovers there.

The instruction-side stream buffer tells the same story: 162 hits on nqueens against 16,641
misses. Next-line prefetching is the wrong model for these programs. The instruction misses were
capacity misses on a loop working set, not a sequential stream, and enlarging the cache addressed
them completely.

Both prefetchers are correctly implemented and both pipeline their requests, and neither earns its
area, because these benchmarks miss on capacity and conflicts rather than on predictable address
streams. Once the caches were sized properly there was almost nothing left to predict.

The measurement that settled it was on the miss addresses themselves: on quickSort **51.3%** of
consecutive D-cache misses repeat the previous stride and only 12.4% go to the next line, and on
esift2 99.5% repeat the stride — yet a stride prefetcher recovers nothing from either. Prediction
was never what was missing. What was missing was **overlap**: 22,179 misses that each stalled the
whole cache for 112 cycles, one at a time. That is what the
[non-blocking cache](#non-blocking-data-cache) fixed, and it is worth 1.16× on quickSort against
the prefetcher's 0.065%.

**The D-cache stride prefetcher has therefore been removed from the tree** — it was deleted with
the non-blocking rewrite rather than carried along disabled, since a prefetcher and a set of
miss-status registers contend for exactly the same structures and the ablation above had already
answered the question. The instruction-side stream buffer stays, because the I-cache is still
blocking and the buffer is its only source of overlap.

### What the front end really delivers

Splitting the cycles that issue nothing into three exclusive causes — the window was empty, the
window held work but nothing had its operands, or something was ready and could not start — gives
the clearest picture of the machine there has been:

| benchmark | issues nothing | window empty | none ready | ready but blocked | window ≥16 when stuck |
| --- | --- | --- | --- | --- | --- |
| coin      | 22.9% | 0.9%  | **20.6%** | 1.4% | 0% |
| quickSort | 18.1% | 6.9%  | **10.6%** | 0.6% | **69%** |
| esift2    | 8.3%  | 2.6%  | **5.7%**  | 0.0% | 0% |
| nqueens   | 16.0% | **12.8%** | 1.8%  | 1.4% | 1% |

Structural conflicts are finished as a source of loss: `iq_blocked` is 1.4% on coin and **six
cycles** on esift2. Mispredictions are not coin's problem either — 145,176 of them produce only
232,820 empty-window cycles, 1.6 cycles each, because the branch target buffer refills the window
almost immediately.

That leaves *nothing ready*, which is much the largest loss in the machine at 5.85 M cycles across
the suite against 695 k of empty window. But it is two different problems sharing a name, and the
occupancy buckets separate them. On quickSort the window holds **16 or more entries 69% of the
time** it is stuck: a deep window waiting on memory, which matches a fill outstanding 31.2% of the
run. On coin and esift2 the window **never reaches 16 entries at all**.

A shallow window with nothing ready is the interesting case, because instructions that cannot issue
should pile up. They were not piling up, which means they were not arriving:

| | offers 0 | offers **1** | offers 2 | mean | actual IPC |
| --- | --- | --- | --- | --- | --- |
| coin   | 1.2% | **49.0%** | 49.8% | 1.487/cycle | **1.419** |
| esift2 | 0.8% | **30.2%** | 69.0% | 1.681/cycle | **1.625** |

**coin's front end offers rename a single instruction on half of all cycles, and its IPC is within
5% of its delivery rate.** The two-wide back end is being fed 1.49 instructions per cycle and
retiring 1.42. It is not short of parallelism; it is short of instructions. The 20.6% "nothing
ready" is a consequence — at 1.42 arrivals per cycle against two issue slots the window can never
accumulate, which is exactly why its occupancy never reaches 16.

The obvious suspect was the rule that cuts a fetch group after a control instruction and its delay
slot, so that only one prediction is in flight per cycle. That was wrong: at `FE_WIDTH = 2` a branch
in the first word still takes its delay slot with it, and the rule never costs a slot. Counting the
short fetches directly gives two causes instead, of near-equal size:

| why fetch pushed one word | coin | share |
| --- | --- | --- |
| the pair straddles the end of a 4-word cache line | 5,859,615 | 45.0% |
| the delay slot of a taken branch fell outside the pair | 7,008,269 | 53.8% |
| no room in the fetch buffer | 149,545 | 1.1% |

The second number is worth reading twice: **7,008,269 short fetches against 7,181,543 conditional
branches, 0.98 per branch.** Essentially every taken branch cost a half-width fetch cycle, because
MIPS has to run the delay slot and it was not in the pair.

Neither cause empties the buffer, which is exactly why `fetch_starved` never saw them -- and that is
the real lesson. A completely empty fetch buffer is rare. A half-empty one was the common case, cost
just as much, and the counter being used to rule out wider fetch could not tell them apart.

### Fetching wider than decode

Both causes disappear if fetch reads a whole line, so fetch width is now decoupled from decode
width: **`FETCH_WIDTH` 4 words in, `FE_WIDTH` 2 instructions out**, with the fetch buffer absorbing
the difference. The instruction cache already read a full line into its banks; it was refusing to
offer words past the end of a line, and being asked for only two in any case.

- A line-aligned fetch never crosses the end of a line, so the straddle case is gone outright.
- The delay-slot case narrows to a branch in the **last** word of the group. `push_limit` is
  `hit_slot + 2`, so a branch recognised in word 0, 1 or 2 brings its delay slot with it.
- The fetch buffer went from 8 entries to 16, to absorb four in against two out.

Nothing in decode, rename or the back end changed.

| benchmark | before | after | gain | IPC |
| --- | --- | --- | --- | --- |
| **coin**  | 25,207,827 | **21,405,644** | **1.178x** | 1.419 -> **1.671** |
| esift2    | 4,835,133  | **4,557,362**  | 1.061x | 1.625 -> **1.724** |
| quickSort | 3,495,796  | **3,400,154**  | 1.028x | 1.174 -> 1.207 |
| nqueens   | 763,332    | **757,970**    | 1.007x | 1.330 -> 1.339 |

esift2 reaches **86% of the theoretical maximum** for a two-wide machine, and coin -- the benchmark
this design served worst of all, at 1.05x when the out-of-order core was first built -- reaches
1.68x.

The confirmation that the diagnosis was right is what happened to the back end without a single
execution resource being touched:

| coin | before | after |
| --- | --- | --- |
| front end offers two instructions | 49.8% | **98.1%** |
| cycles issuing nothing | 22.9% | **6.6%** |
| window holds work but nothing is ready | 5,191,260 | **1,571** |

That last row is the whole argument. The 20.6% of cycles with "nothing ready" reads like dependence
chains, and would ordinarily be answered with a deeper window or a wider issue stage. It was
**entirely** an artefact of a window that could not accumulate at 1.42 arrivals per cycle, and
feeding the same back end properly made it vanish.

### Going three wide

Widening the machine had been rejected twice, both times on the same evidence: three or more
instructions were ready on only 8.8% of coin's cycles and 23.4% of esift2's, so there was nothing
to feed a third slot with. That was true, and it stopped being true the moment fetch stopped
starving the window:

| coin, entries ready | before wide fetch | after |
| --- | --- | --- |
| ≥2 | 71.7% | 84.8% |
| **≥3** | 20.9% | **38.4%** |
| ≥4 | 12.4% | 16.0% |
| ready but could not start | 1.4% | **4.5%** |

Both widths are single parameters — the ALUs, register file ports and writeback ports are all
generate loops over `ISSUE_WIDTH`, and decode, rename, dispatch and commit are all loops over
`FE_WIDTH` — so the two were measured separately, which turned out to matter:

| benchmark | 2-wide | `ISSUE_WIDTH` 3 only | + `FE_WIDTH` 3 |
| --- | --- | --- | --- |
| nqueens   | 757,970    | 720,143 (1.053×)    | **647,872** (1.112×) |
| quickSort | 3,400,154  | 3,331,071 (1.021×)  | **3,050,477** (1.092×) |
| esift2    | 4,557,362  | 4,521,289 (1.008×)  | **3,333,506** (1.356×) |
| coin      | 21,405,644 | 21,405,604 (**1.000×**) | **17,682,190** (1.211×) |

coin is the instructive row. A third issue slot on its own bought it **40 cycles**, because dispatch
and commit still capped it at two per cycle — the machine issued three on many cycles and could not
retire them any faster. Widening the rest of the pipeline released it for 1.21×. A wider issue stage
is worth nothing without a wider front end to feed it and a wider commit to drain it, and the two
measured separately say so exactly.

esift2 reaches **IPC 2.356** and coin **2.023**, both clean through the old two-wide ceiling.

#### The group cut, and a prediction that was wrong

At three wide the decode group ending at every control instruction started to cost: coin accepted a
single instruction on 32.3% of its cycles. Since the cut only exists so that decode raises at most
one redirect per cycle, and coin takes **two decode redirects in 35.8 M instructions**, ending the
group only when a redirect is actually needed looked like it should recover most of that.

It did not. Relaxing it left coin's `fe_accept_1` at 5,711,492 against 5,711,419 — unchanged — and
coin 135 cycles slower. The cut was not what was costing it. One stage earlier, `fb_only1` is
5,971,894: the fetch *buffer* holds a single entry on 33.8% of cycles, and decode cannot accept
three when only one is there. Fetch is short for the old reason, one branch at a time:

```
coin, three wide:  fe_push_1  7,957,395  (45% of cycles push one word)
                   of which pend  7,051,895   vs 7,181,543 conditional branches
```

Still essentially one per branch. Widening fetch from two to four moved the boundary without
removing the mechanism: a branch landing in the last *pushed* slot still forces its delay slot into
a fetch cycle of its own.

The relaxation is kept because it is a small real gain where the group was binding — quickSort
1.009×, nqueens 1.008×, +0.4% geometric mean, and all four still match their traces, so the
delay-slot reasoning held even though the sizing did not.

#### Eight-word lines, and a cache result that went the other way

The mechanism that survived both widenings is a branch landing in the **last pushed slot**, which
forces its delay slot into a fetch cycle of its own. At a four-word group that is roughly one branch
in four; at eight it is one in eight. So the instruction cache was regeometried to eight-word lines
at the same 8 KB — 2 ways × 128 sets × 8 words — and `FETCH_WIDTH` raised to 8.

| benchmark | four-word lines | eight-word lines | gain |
| --- | --- | --- | --- |
| quickSort | 3,024,375  | **2,910,430**  | **1.039×** |
| nqueens   | 642,551    | **618,655**    | **1.039×** |
| coin      | 17,682,325 | **17,160,099** | 1.030× |
| esift2    | 3,333,501  | **3,294,956**  | 1.012× |

The first change in a long while to help all four. The short-fetch mechanism is now essentially
dead — coin accepts a full group of three on **97.3%** of cycles:

| accepted one instruction of three | four-word | eight-word |
| --- | --- | --- |
| coin      | 5,711,492 | **139,617** (0.81%) |
| esift2    | 555,595   | **25** |
| quickSort | 299,915   | 111,357 |

**The interesting part is the cache.** Halving the set count from 256 to 128 to pay for the longer
lines should cost hit rate, and nqueens is the most instruction-cache-sensitive of the four. It went
the other way: nqueens' instruction misses fell from 16,814 to **9,653** and its stall cycles from
16,560 to **8,777**, both roughly halved, for the same 8 KB. Instruction fetch is sequential enough
that an eight-word line fetches the next four words for free, and that is worth more than the sets
it costs. The equivalent trade on the *data* side was measured earlier and lost badly — the two
sides of the machine do not behave alike, and neither result generalises to the other.

### What actually bounds the window

Widening the window was on the dead-end list at 1.02×, and that turned out to be an artefact: the
measurement was taken with a *blocking* D-cache, where D-cache miss cycles came out identical to
within one cycle whatever the window size, because the cache serialised everything regardless. Once
misses overlap, the window decides how many independent ones can be found — so the ablation was
redone, and this time the first step was to ask **which** resource dispatch was actually short of
rather than scaling everything and hoping.

Every dispatch stall attributed to the resource that ran out:

| benchmark | dispatch stalls | free list | reorder buffer | issue queue | load/store queue |
| --- | --- | --- | --- | --- | --- |
| quickSort | 1,251,515 (29.5%) | **100%** | 0 | 0 | 0 |
| coin      | 2,105,508 (8.0%)  | ~0 | ~0 | 0 | **99.98%** |
| esift2    | 93,576 (1.9%)     | 0  | 0  | 0 | **100%** |
| nqueens   | 10,713 (1.4%)     | 17% | 0 | 0 | 84% |

**The reorder buffer and the issue queue were never the constraint on any benchmark**, and the
reason is arithmetic rather than subtle. The free list holds `PHYS_REGS - ARCH_REGS` spare tags. At
64 physical registers that is 32, so at most 32 register-writing instructions can be in flight
against a **64-entry** reorder buffer: the buffer physically could not fill, because the free list
ran out at half its capacity first. On quickSort that accounted for 100% of every stalled cycle.

Raising `PHYS_REGS` to 128 is the whole fix at that point, and the isolation is exact:

| quickSort configuration | cycles | |
| --- | --- | --- |
| `PHYS_REGS` 64, `ROB_ENTRIES` 64, `LSQ_ENTRIES` 16 | 4,235,844 | |
| `LSQ_ENTRIES` 32 alone | 4,235,844 | identical to the cycle |
| **`PHYS_REGS` 128 alone** | **3,890,402** | **1.089×** |
| `PHYS_REGS` 128 + `IQ_ENTRIES` 64 + `LSQ_ENTRIES` 32 | 3,890,402 | identical to `PHYS_REGS` alone |

Doubling the issue queue and the load/store queue is worth exactly nothing there, in both
directions — the same cycle count to the digit.

#### Then the reorder buffer, and only then the queue

With the free list no longer binding, quickSort's stalls became **100% reorder buffer** — 852,550
cycles, the first time that structure had bound anything. Raising it is four lines and no RTL
change, despite the note in this repository's history that said otherwise. The five errors
Verilator reports at `ROB_ENTRIES = 128` are all `BLKLOOPINIT` on the same construct — a
non-blocking assignment to an element of an *unpacked* array inside a `for` loop, in the reset and
squash walks over `rob` and `rmt`. Verilator accepts that only when it can fully unroll the loop,
and its default unroll budget is 64, which is exactly why the design elaborates at 64 entries and
fails at 128. `--unroll-count 512 --unroll-stmts 100000` in the Makefile clears all five.

| quickSort configuration | cycles | gain | vs in-order baseline |
| --- | --- | --- | --- |
| `PHYS_REGS` 64, `ROB_ENTRIES` 64, `LSQ_ENTRIES` 16 | 4,235,844 | — | 2.26× |
| + `PHYS_REGS` 128 | 3,890,402 | 1.089× | 2.46× |
| + `ROB_ENTRIES` 128 | 3,540,153 | 1.099× | 2.70× |
| + `LSQ_ENTRIES` 32 | **3,495,796** | 1.013× | **2.74×** |

`LSQ_ENTRIES` is the interesting row. Doubling it measured **exactly zero** at 64 reorder buffer
entries and is worth 44,357 cycles at 128 — it only becomes visible once the structure in front of
it stops being the constraint. Scaling everything at once would have credited the load/store queue
with a win it does not deserve on its own; scaling one at a time in the wrong order would have
written it off entirely. Attributing the stall first is what made the order obvious.

And on **coin** the same `LSQ_ENTRIES` change is worth **1.04×** on its own — 26,212,464 to
25,207,827, IPC 1.36 to 1.42 — because coin's dispatch stalls were 99.98% load/store queue all
along. Its `rename_stall` falls from 2,105,364 to 819,124. That is the largest gain coin has seen
since the branch target buffer, and it very nearly went unnoticed: the isolating runs were done on
the three fast benchmarks, and coin was only measured at the end. **A parameter sweep that skips the
slow benchmark is not a sweep.**

nqueens and esift2 gain nothing from any of it, which their stall columns predicted: esift2's
load/store queue stalls move only from 93,576 to 93,186, because there the queue is full behind a
commit blocked on memory rather than short of capacity.

#### Where it stops

quickSort's remaining 322,121 stall cycles no longer have a single owner. They split across the
reorder buffer (166,542), the **issue queue** (120,351, binding for the first time in this project)
and the free list (32,218). There is no next parameter to turn. coin still stalls on the load/store
queue for 818,731 cycles, so it has further to go, but doubling that queue again is the obvious
thing to measure rather than to assume.

What there is instead is a ceiling that these two changes walked the machine straight into:

| | `Dmiss_regs_full` | `Dmiss_refused` |
| --- | --- | --- |
| before the window work | 0 | 5 |
| `PHYS_REGS` 128 | 451 | 96 |
| + `ROB_ENTRIES` 128 | 157,219 | 4,761 |
| + `LSQ_ENTRIES` 32 | **174,208** (5.0% of cycles) | 8,112 |

All four miss-status registers are now full for 5% of quickSort's run, and `NUM_MSHR` cannot simply
be raised: the memory model accepts four outstanding reads **per AXI id**, and the D-cache uses one.
Going further means giving it a second master id, which is design work rather than a parameter.

### Branch prediction accuracy

| benchmark | tournament | perceptron alone | gshare alone |
| --- | --- | --- | --- |
| nqueens | 76.3% | 77.3% | 66.9% |
| quickSort | 86.7% | 86.6% | 83.5% |
| esift2 | 98.6% | 98.6% | 98.3% |

The chooser is close to a wash: it wins slightly on quickSort and loses slightly on nqueens, where
the perceptron on its own would have been better. gshare is the weaker component throughout.

On branch `tage-sc-l` the tournament predictor is replaced, and the numbers above are the baseline
it is measured against — nqueens goes 76.9% to **80.6%** and coin 98.0% to **99.1%**. See
[Statistical Correction](#statistical-correction).

All four benchmarks are checkable. If `coin.ls.txt.bz2` ever fails to decompress, the archive in
git is intact (md5 `ddb5e9b2a81ebcb95dee219cfebedb1b`) and the working-tree copy has gone bad —
`rm hexfiles/coin.ls.txt.bz2 && git checkout -- hexfiles/coin.ls.txt.bz2` restores it. Note that
coin is far larger than the others (35.7 M instructions against 7.9 M for esift2) and takes
correspondingly longer to simulate.

---

### Where the remaining time goes

*The state of the machine at 3-wide. For where it went next, see
[Going Four Wide](#going-four-wide-and-what-memory-actually-costs) — every "limited by" in the
table below has since changed, and two of them turned out to be wrong.*

With the caches fixed, the front end fixed and the data cache no longer blocking, the bottleneck
moved again, and it is now different on each benchmark. The D-cache column is the share of cycles
with at least one line fill outstanding — no longer a stall, since the core keeps running through
it, but still the window in which memory is the thing being waited on:

| benchmark | IPC (ceiling 3.0) | D-cache misses | I-cache stall | limited by |
| --- | --- | --- | --- | --- |
| esift2    | **2.36** | 783    | 0.07%  | 79% of ceiling |
| coin      | **2.02** | 29     | 0.017% | the group cut in decode, then `IQ_ENTRIES` |
| nqueens   | 1.57 | 96     | 2.6%   | branch accuracy |
| quickSort | 1.35 | 22,188 | 0.16%  | the miss-status registers |

#### How the front-end problem was found, and what fixing it did

coin is the most useful diagnostic in the suite: it has essentially no cache misses at all, so it
measures what the core alone is leaving on the table. Before this round of work it recorded
**7,224,093 fetch-starved cycles** — 21% of its run with the fetch buffer empty — against an
instruction cache miss rate of 0.009%. The cache was not the cause. It also retires 7,181,552
conditional branches, so there was very nearly **one starved cycle per branch**:

```
fetch_starved 7,224,093 / conditional branches 7,181,552 = 1.006
```

That ratio pointed straight at where prediction happened. Predicting in decode meant a redirect was
discovered a cycle after those instructions were fetched, and taking it flushed the fetch buffer.
Two other candidates were ruled out by the same run: branch *accuracy* was already 98.0%, and
`rename_stall` was only 7.9%, so neither the predictor nor the reorder buffer was the constraint.

The [branch target buffer](#predicting-in-fetch-not-decode) removed it:

| coin | before | after BTB | after pipelined port | after non-blocking D-cache |
| --- | --- | --- | --- | --- |
| cycles | 34,162,087 | 28,492,663 | 27,294,122 | **26,211,879** |
| fetch_starved | 7,224,093 | 148,004 | 148,004 | 148,094 |
| decode redirects | ~7.1 M | **1** | **1** | **1** |
| cycles issuing nothing | 12,712,810 | 6,915,565 | 6,184,585 | 6,367,780 |
| rename_stall | 2,687,230 | 4,536,081 | 3,225,107 | **2,104,286** |
| IPC | 1.047 | 1.255 | 1.310 | **1.364** |

One decode redirect in a 35.8 M instruction run: after the first execution of each static branch,
the target buffer answers every one of them. `rename_stall` rising after the BTB is the bottleneck
moving downstream — the front end started delivering faster than the back end was draining, which
is exactly what the pipelined D-cache port then relieved.

#### What is left, and what became of it

*Every item here was written at 3-wide. Three of the four have since been settled, and two of them
against what this section predicted — see
[Going Four Wide](#going-four-wide-and-what-memory-actually-costs).*

- **The miss-status registers, and this one needs design work.** All four are full for 5.0% of
  quickSort's run (`Dmiss_regs_full` 174,208 cycles, up from 0 before the window was sized) and
  8,112 misses are refused outright. `NUM_MSHR` cannot simply be raised: the memory model accepts
  four outstanding reads **per AXI id** and the D-cache uses one, so going further means giving it a
  second master id. That is the clearest remaining ceiling on the one memory-bound benchmark.

  **SETTLED, and this was wrong.** The second master id was built, `NUM_MSHR` went to 8,
  `Dmiss_regs_full` went to **0** and `Dmiss_refused` 12,581 → 14 — and it was worth **0.15%**.
  `Dmiss_inflight` barely moved, because quickSort's misses are *dependent*: they were already
  overlapping as far as the program allows, and more capacity finds no more independent misses.
  Calling it "the clearest remaining ceiling" was the same mistake as the `LSQ_ENTRIES` entry
  below, made two bullets away from the warning about it.
- **The two large benchmarks are close to the two-wide ceiling.** esift2 is at IPC 1.72 and coin at
  1.67 against a maximum of 2.0 — 86% and 84%. Both now have a front end that delivers two
  instructions on 98% of cycles, so what is left there is genuinely issue width and dependence
  chains rather than any structure that can be resized.

  **SETTLED: it was issue width, and the ceiling moved twice.** Both are now past IPC 2.75 at
  4-wide.
- **`LSQ_ENTRIES` 64 was measured and rejected twice.** Against the narrow front end it was worth
  1.025× on coin and nothing on the other three. It was re-measured afterwards, because coin's
  dispatch stalls had risen to 2,837,999 and all of them were the load/store queue — and on the
  wide-fetch design it is worth **nothing at all**: coin 21,405,644 → 21,405,568, quickSort
  identical to the cycle. What it does is move coin's stall from the load/store queue to the
  reorder buffer, 2,838,567 → 3,095,390, for **76 cycles**.

  **Rejected a third time, at 4-wide, and the third time was the most extreme.** coin's
  `stall_only_lsq` had risen to 3,415,793 cycles — 26.6% of its run and the largest single stall
  anywhere in the suite. Relieving it entirely moved `stall_only_iq` 195,795 → 3,593,966 and was
  worth **ten cycles**.

  That is the most useful negative result in this file, because it shows a dispatch stall is not
  automatically a cost. When the machine is limited by something else, whichever queue happens to
  fill first is what the counter reports, and relieving it just moves the backlog one structure
  along. `stall_preg` and `stall_rob` were causal — fixing them was worth 1.089× and 1.099×.
  coin's `stall_lsq` never was. The counter tells you where the queue ends, not always why.
- **quickSort's remaining stalls have no single owner**: reorder buffer 166,542, issue queue
  120,351, free list 32,218. The issue queue binding at all is new. There is no next parameter.

  **SETTLED: there was no next parameter, and there did not need to be.** quickSort's stalls fell
  from 496,807 cycles to 85,869 through the cache and the prefetcher rather than through any
  structure resizing.
- **nqueens is limited by branch accuracy**, at 76.3%, and by nothing structural: 8,548 dispatch
  stalls in its entire run, 1.1% of cycles. It is the one benchmark where a stronger direction
  predictor would pay; on coin and esift2 the tournament predictor is already at 98%.

  **STILL TRUE, and it is the one item here that survived.** At 80.6% accuracy and 4-wide it has
  2,468 cycles of dispatch stall in the whole run. `squash_refill` shows the front end recovers
  from a redirect in ~1.14 cycles, so the entire remaining cost is wrong-path work — accuracy is
  the only lever, and there is no structure left to resize.

For reference, the in-order baseline runs coin at IPC 0.995 — 99.5% of *its* ceiling. coin was the
benchmark this design served worst, at 1.05×; it is now **2.03× at IPC 2.02**. Essentially all of
that gap was the front end — predicting in fetch with a target buffer, then fetching wider than
decode, then widening the machine once fetch could feed it — and almost none of it was the
out-of-order machinery it was originally blamed on.

Window occupancy was measured directly to answer whether a **wider machine** would help, by
counting how many issue-queue entries are ready each cycle. All of it is measured on the final
design, and `fetch_starved` is included because widening fetch is the other obvious thing to reach
for:

| benchmark | ≥1 ready | ≥2 | ≥3 | ≥4 | ≥2 memory ops | fetch starved |
| --- | --- | --- | --- | --- | --- | --- |
| esift2    | 91.7% | 71.4% | 23.4% | ~0    | ~0    | 0.4% |
| coin      | 78.5% | 71.7% | 20.9% | 12.4% | 17.9% | 0.6% |
| nqueens   | 85.4% | 65.4% | 44.9% | 19.1% | 20.4% | 7.7% |
| quickSort | 82.5% | 59.5% | 29.8% | 4.6%  | 1.6%  | 4.0% |

Three or more instructions are ready on 13.1% of coin's cycles and 23.4% of esift2's, so **4-wide is
not worth it** — the parallelism to feed it is not in the window.

**That conclusion was wrong too, and this is the second time this table has misled.** The numbers
are real, but they were taken with a **64-entry reorder buffer behind a 2-wide front end**, and
they measure the window that machine could fill rather than the parallelism in the program. At ROB
128 with a 3-wide front end feeding it, `ready_ge3` on esift2 reads **68%**, not 23.4%, and
`issue_3` — the machine issuing its full width — fires on 68% of its cycles. Going 4-wide is worth
**1.280× on coin and 1.222× on esift2**, the largest single win in this file. See
[four wide](#four-wide-which-was-supposed-to-be-a-dead-end).

**The claim that used to sit here, that wider fetch is not worth building either, was wrong in the
same way, and the way it was wrong is worth keeping.** It rested on `fetch_starved`, which is 0.6%
on coin — but that counter only fires when the fetch buffer is *completely empty*. It says nothing
about a buffer holding exactly one instruction, which turns out to be what actually happens. See
[what the front end really delivers](#what-the-front-end-really-delivers).

Twice now, a window-occupancy measurement has been read as a fact about the *programs* when it was
a fact about the *machine measuring them*. An occupancy counter is only ever an upper bound set by
whatever is upstream of it.

These numbers moved a lot when the cache stopped blocking, and in the informative direction.
Before, two memory operations were ready together on a quarter of nqueens' cycles and 26% of
quickSort's, which looked like a clear argument for a second cache port. Almost all of that was
memory operations *piling up ready behind a blocked port* — with the port free, quickSort's figure
collapses from 26% to 1.2%. The second port would have been built to relieve a queue that no
longer forms.

# Simulation

Verilator and gtkwave come from the [oss-cad-suite](https://github.com/YosysHQ/oss-cad-suite-build)
binary release. `mips_cpu/Makefile` expects `$CSE148_TOOLS` to point at the directory containing it.

```
cd mips_cpu
make verilate
./obj_dir/Vmips_core -b nqueens      # -b selects the benchmark
```

The golden traces are stored compressed and must be expanded once before the first run:

```
cd hexfiles && for f in *.bz2; do bunzip2 -kf "$f"; done
```

If the toolchain is only available as a container image, the same build works inside it:

```
docker run --rm -v "$PWD:/work" -w /work/mips_cpu <image> bash -lc \
  'source /root/cse148env; source $CSE148_TOOLS/oss-cad-suite/environment; \
   make verilate && ./obj_dir/Vmips_core -b nqueens'
```

Useful flags: `-b <benchmark>`, `-d` (dump `simx.fst`), `-m` (memory model debug, repeat for more),
`-s` (skip stream checks), `-p` (print events).

Building with `-DMDP_STRESS` turns every store that resolves behind an issued load into a memory
order violation, which is the only way to exercise the
[recovery path](#testing-a-path-that-never-runs) — real code almost never aliases there. The traces
still have to match; it is simply very slow.

```
verilator --cc --exe --build -DSIMULATION -DMDP_STRESS -Imips_core -f verilator_files   --top-module mips_core verilator_main.cpp memory.cpp memory_driver.cpp
```

# Synthesis

1. FreePDK45 from NCSU
2. OpenRAM — use the binaries directly
3. OpenSTA — build from the repo
4. sv2v — build from the repo (some binaries already available)
5. Python 3.6+
