# RTL-to-GDS on nanoHUB — operational rules

Drop this into a repo as `CLAUDE.md`, or append it to an existing one, so it
loads every session. Companion to `PLAYBOOK.md`: that one explains, this one
decides. When they disagree, this one wins.

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
| flow and PDK from different install trees | six versions coexist under `/apps/share64/*/librelane/` | match them; `$PDK_ROOT` says which the environment intends |

## CANONICAL COMMANDS

```bash
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
  destroys your hierarchical cut points. Slang does not.
- sky130 SRAM beats flops by ~**2.9×** per bit, not 10×. OpenRAM carries heavy
  peripheral overhead. Measure: macro `SIZE` from LEF, flop `SIZE` from the SCL
  LEF. Reference: `dfxtp_1` 20.0 µm²/bit (50.0 at 40% util),
  `sram_2kbyte_32x512` 17.4, `sram_1kbyte_32x256` 23.3.
- A multi-ported register file **cannot** be SRAM. Async read alone rules it
  out. Measured: a 128×32 PRF with 8 async reads + 5 writes was 581,694 µm², of
  which the flops were 87,123 (15%) — the mux network is 85%.
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
- Adding a fourth guessed path? Stop and `find` instead.
- Authoring on Windows: commit `.gitattributes` with `*.sh text eol=lf`, or the
  shebang arrives as `^M` and Linux reports `bad interpreter`.
- Probe interpreters by running them; `command -v python3` can find a stub.

## ORDER OF WORK (each step gates the next)

```
1. working shell            -> librelane --version exits 0
2. measure the PDK          -> um^2/bit per macro and per flop
3. parse RTL, list modules  -> no tools needed
4. synth-only, SMALLEST     -> proves frontend + config keys. minutes.
5. synth-only, everything   -> area table; decides if the full chip is viable
6. full flow, one small block -> proves P&R and signoff
7. big runs
```

Do not skip 4 and 5. They are the difference between finding a bad config key
in five minutes and finding it in five hours.
