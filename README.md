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
 │   ↓                   │   │                 ↓                  │   │   2 wide)    │
 │ RENAME + DISPATCH     │   │   2 ALUs   +   load/store queue     │   │              │
 └───────────────────────┘   │                 ↓                  │   └──────────────┘
            │                │            writeback               │          ▲
            └────────────────┴──── reorder buffer (64 entries) ────┴──────────┘
```

The front end, rename and commit are all in program order and 2 instructions wide. Everything
between dispatch and writeback runs out of order, bounded by the issue queue and the reorder
buffer.

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
| `branch_predictor_files/tournament_predictor.sv` | Perceptron + gshare + chooser |
| `stream_buffer.sv` | Next-line prefetcher |
| `d_cache.sv` | 4-way write-back data cache, non-blocking: miss status holding registers and a decoupled writeback queue |
| `i_cache.sv`, `memory_arbiter.sv` | Unchanged from the baseline, except that the I-cache now returns two contiguous words per fetch |

---

# Branch Prediction

A **perceptron predictor** ([Jimenez and Lin, HPCA 2001](https://www.cs.utexas.edu/~lin/papers/hpca01.pdf))
and a **gshare** predictor run in parallel, with a per-PC chooser deciding which to believe.

![image](https://github.com/user-attachments/assets/a88fff39-ef96-4a6d-b27d-6a73976f5192)

![image](https://github.com/user-attachments/assets/949eee24-9657-49f6-9703-cefa054b7aa6)

Geometry: 1024 perceptrons × 17 weights of 8 bits, 16 bits of global history, a 1024-entry gshare
table and a 1024-entry chooser.

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

- **64-entry reorder buffer**, **32-entry issue queue**, **16-entry load/store queue**
- 2-wide rename/dispatch/commit, 2 issue ports, 2 ALUs, 1 memory port
- Single-cycle execute with no bypass network

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

The I-cache is 2-way set associative with LRU replacement (2 KB), and now returns **two contiguous
words per fetch** to feed the 2-wide front end.

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
| nqueens   | 1,722,402  | 890,370    | 807,339    | 764,041    | 763,961    | 763,332    | 757,970    | **642,551**    | **2.68×** | 1.58 |
| quickSort | 9,572,553  | 5,492,808  | 5,240,726  | 4,528,689  | 4,235,844  | 3,495,796  | 3,400,154  | **3,024,375**  | **3.17×** | 1.36 |
| esift2    | 21,375,975 | 5,814,714  | 4,834,600  | 4,835,486  | 4,835,486  | 4,835,133  | 4,557,362  | **3,333,501**  | **6.41×** | **2.36** |
| coin      | 35,944,392 | 34,162,087 | 27,294,090 | 26,211,879 | 26,212,489 | 25,207,827 | 21,405,644 | **17,682,325** | **2.03×** | **2.02** |

Geometric mean **3.24×**, with two benchmarks past IPC 2.0 against a ceiling that is now 3.0. The columns are cumulative: the out-of-order core at the original 2 KB
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

Nothing measurable, on either side of the machine. This is the clearest negative result here and
worth stating plainly.

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

All four benchmarks are checkable. If `coin.ls.txt.bz2` ever fails to decompress, the archive in
git is intact (md5 `ddb5e9b2a81ebcb95dee219cfebedb1b`) and the working-tree copy has gone bad —
`rm hexfiles/coin.ls.txt.bz2 && git checkout -- hexfiles/coin.ls.txt.bz2` restores it. Note that
coin is far larger than the others (35.7 M instructions against 7.9 M for esift2) and takes
correspondingly longer to simulate.

---

### Where the remaining time goes

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

#### What is left

- **The miss-status registers, and this one needs design work.** All four are full for 5.0% of
  quickSort's run (`Dmiss_regs_full` 174,208 cycles, up from 0 before the window was sized) and
  8,112 misses are refused outright. `NUM_MSHR` cannot simply be raised: the memory model accepts
  four outstanding reads **per AXI id** and the D-cache uses one, so going further means giving it a
  second master id. That is the clearest remaining ceiling on the one memory-bound benchmark.
- **The two large benchmarks are close to the two-wide ceiling.** esift2 is at IPC 1.72 and coin at
  1.67 against a maximum of 2.0 — 86% and 84%. Both now have a front end that delivers two
  instructions on 98% of cycles, so what is left there is genuinely issue width and dependence
  chains rather than any structure that can be resized.
- **`LSQ_ENTRIES` 64 was measured and rejected twice.** Against the narrow front end it was worth
  1.025× on coin and nothing on the other three. It was re-measured afterwards, because coin's
  dispatch stalls had risen to 2,837,999 and all of them were the load/store queue — and on the
  wide-fetch design it is worth **nothing at all**: coin 21,405,644 → 21,405,568, quickSort
  identical to the cycle. What it does is move coin's stall from the load/store queue to the
  reorder buffer, 2,838,567 → 3,095,390, for **76 cycles**.

  That is the most useful negative result in this file, because it shows a dispatch stall is not
  automatically a cost. When the machine is limited by something else, whichever queue happens to
  fill first is what the counter reports, and relieving it just moves the backlog one structure
  along. `stall_preg` and `stall_rob` were causal — fixing them was worth 1.089× and 1.099×.
  coin's `stall_lsq` never was. The counter tells you where the queue ends, not always why.
- **quickSort's remaining stalls have no single owner**: reorder buffer 166,542, issue queue
  120,351, free list 32,218. The issue queue binding at all is new. There is no next parameter.
- **nqueens is limited by branch accuracy** and nothing structural: 8,548 dispatch stalls in its
  entire run, 1.1% of cycles.
- **nqueens is limited by branch accuracy**, at 76.3%. It is the one benchmark where a stronger
  direction predictor (TAGE) would pay; on coin and esift2 the tournament predictor is already at
  98% and there is nothing to win.
- **esift2 and coin are at IPC 2.36 and 2.02** against a ceiling that is now 3.0. What is left on
  coin is measured and specific: it accepts a single instruction on 32.3% of cycles because the
  decode group ends at every control instruction, and `IQ_ENTRIES` binds for 1,549,018 cycles.

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

**The claim that used to sit here, that wider fetch is not worth building either, was wrong, and
the way it was wrong is worth keeping.** It rested on `fetch_starved`, which is 0.6% on coin — but
that counter only fires when the fetch buffer is *completely empty*. It says nothing about a buffer
holding exactly one instruction, which turns out to be what actually happens. See
[what the front end really delivers](#what-the-front-end-really-delivers).

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
