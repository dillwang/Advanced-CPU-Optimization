# Advanced-CPU-Optimization

A CPU architecture design project that replaces a simple in-order MIPS32 core with a
**superscalar out-of-order machine**, and measures what each optimization is actually worth.

Implemented:

- Tournament branch prediction (perceptron + gshare with a chooser)
- Register renaming (MIPS R10000 style)
- Superscalar out-of-order execution
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
| `ooo/lsq.sv` | Load/store queue, disambiguation, store-to-load forwarding, D-cache port |
| `ooo/prf.sv` | Unified physical register file |
| `ooo/ooo_backend.sv` | Back-end glue and the execution units |
| `branch_predictor_files/tournament_predictor.sv` | Perceptron + gshare + chooser |
| `stream_buffer.sv` | Next-line prefetcher |
| `i_cache.sv`, `d_cache.sv`, `memory_arbiter.sv` | Unchanged from the baseline, except that the I-cache now returns two contiguous words per fetch |

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
- A load may issue ahead of older stores only once every older store has computed its address. At
  that point it can be disambiguated exactly, so **no replay mechanism is needed**.
- A load matching an older store in the queue takes its value straight from the queue
  (**store-to-load forwarding**); the youngest matching older store wins.

The D-cache port is **pipelined**. The cache addresses its SRAM from `addr_next` and compares tags
against `addr`, which are a cycle apart, so an access can be set up in the same cycle the previous
one completes — the cache has always been able to accept an address every cycle. The original queue
walked every access through `M_IDLE → M_LOAD → M_IDLE`, which meant even a **hit** occupied the port
for two cycles and capped memory throughput at 0.5 accesses per cycle. Replacing that state machine
with a one-deep pipeline register removes the idle cycle and doubles the ceiling. A stalled access
holds its own address on `addr_next` so the SRAM read is set up again for when the refill finishes.

`jr`/`jalr` targets come out of a register, so they are resolved at execute and redirect through the
same recovery path as a mispredicted branch. Direct `j`/`jal` are resolved by the front end.

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

| benchmark | baseline (in-order) | out-of-order core | + caches | **final** | speedup | IPC |
| --- | --- | --- | --- | --- | --- | --- |
| nqueens   | 1,722,402  | 1,609,896  | 890,370    | **807,339**    | **2.13×** | 1.26 |
| quickSort | 9,572,553  | 7,740,489  | 5,492,808  | **5,240,726**  | **1.83×** | 0.78 |
| esift2    | 21,375,975 | 17,254,324 | 5,814,714  | **4,834,600**  | **4.42×** | 1.62 |
| coin      | 35,944,392 | —          | 34,162,087 | **27,294,090** | **1.32×** | 1.31 |

Geometric mean **2.18×**. The columns are cumulative: the out-of-order core at the original 2 KB
caches, then 8 KB instruction cache and 4-way 16 KB data cache, then prediction moved into fetch
with a branch target buffer and the D-cache port pipelined.

The last column is worth isolating, because it is the only change that helped every benchmark:

| benchmark | before front end work | + BTB in fetch | + pipelined D-cache port | total |
| --- | --- | --- | --- | --- |
| nqueens   | 890,370    | 860,124    | **807,349**    | **1.10×** |
| quickSort | 5,492,808  | 5,273,026  | **5,239,953**  | **1.05×** |
| esift2    | 5,814,714  | 4,834,598  | **4,834,598**  | **1.20×** |
| coin      | 34,162,087 | 28,492,663 | **27,294,122** | **1.25×** |

esift2 gains nothing at all from the pipelined port — to the cycle — and coin gains 1.04×. The two
changes are almost disjoint in what they fix, which is why both were worth doing.

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
essentially the theoretical maximum for a 2-wide core. Memory stall cycles are untouched, because
both caches are blocking and the load/store queue services one access at a time: a miss stalls
exactly as hard as it did in order.

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
**`ENABLE_PREFETCH` therefore defaults to 0**; the logic stays in the tree so the ablation above
reproduces.

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

With the caches fixed and the front end fixed, the bottleneck moved again, and it is now different
on each benchmark:

| benchmark | IPC (ceiling 2.0) | D-cache miss | I-cache miss | limited by |
| --- | --- | --- | --- | --- |
| esift2    | 1.62 | 1.5%  | 0.04%  | the core |
| coin      | 1.31 | 0.01% | 0.009% | the core |
| nqueens   | 1.26 | 1.2%  | 1.9%   | branch accuracy |
| quickSort | 0.78 | 45%   | 0.09%  | memory |

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

| coin | before | after BTB | after pipelined port |
| --- | --- | --- | --- |
| cycles | 34,162,087 | 28,492,663 | **27,294,122** |
| fetch_starved | 7,224,093 | 148,004 | 148,004 |
| decode redirects | ~7.1 M | **1** | **1** |
| cycles issuing nothing | 12,712,810 | 6,915,565 | 6,184,585 |
| rename_stall | 2,687,230 | 4,536,081 | 3,225,107 |
| IPC | 1.047 | 1.255 | **1.310** |

One decode redirect in a 35.8 M instruction run: after the first execution of each static branch,
the target buffer answers every one of them. `rename_stall` rising after the BTB is the bottleneck
moving downstream — the front end started delivering faster than the back end was draining, which
is exactly what the pipelined D-cache port then relieved.

#### What is left

- **quickSort is memory bound and stays that way.** 45% of its accesses miss, both caches block, and
  the load/store queue services one miss at a time. Miss-status holding registers, so that
  independent misses overlap instead of serialising, are the only thing that would move it.
- **nqueens is limited by branch accuracy**, at 76.3%. It is the one benchmark where a stronger
  direction predictor (TAGE) would pay; on coin and esift2 the tournament predictor is already at
  98% and there is nothing to win.
- **esift2 and coin are core limited** at IPC 1.62 and 1.31 against a ceiling of 2.0. What is left
  there is issue width and dependence chains, not any single structure.

For reference, the in-order baseline runs coin at IPC 0.995 — 99.5% of *its* ceiling. coin was the
benchmark this design served worst, at 1.05×; it is now 1.32×, and the gap that closed was entirely
front end.

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

# Synthesis

1. FreePDK45 from NCSU
2. OpenRAM — use the binaries directly
3. OpenSTA — build from the repo
4. sv2v — build from the repo (some binaries already available)
5. Python 3.6+
