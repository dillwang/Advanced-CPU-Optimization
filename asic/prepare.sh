#!/usr/bin/env bash
#
# prepare.sh -- lower the RTL here, so nanoHUB does not have to.
#
# You only need this if the nanoHUB session has no outbound network. rtl2gds.sh
# normally does the lowering itself, fetching sv2v with --fetch-sv2v; this is
# the offline path.
#
# nanoHUB's LibreLane tool bundles LibreLane, KLayout, OpenROAD and ngspice. It
# does not bundle sv2v, and the Yosys inside it reads Verilog-2005, not
# SystemVerilog packages and interfaces. sv2v does live in the same container
# the simulator uses (nonlig/cse148wi24), so that is what this drives.
#
# The result is asic/build/mips_core.v and a tarball of it. Upload the tarball
# and unpack it inside the cloned repo's asic/ directory; rtl2gds.sh will find
# the lowered Verilog already in place and skip the step.
#
# Usage:
#   ./prepare.sh                 # via the CSE148 container
#   ./prepare.sh --no-docker     # via sv2v from $PATH or $CSE148_TOOLS
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
RTL="$REPO/mips_cpu"
BUILD="$HERE/build"
FLAT="$BUILD/mips_core.v"

IMAGE="${CSE148_IMAGE:-nonlig/cse148wi24}"
TOOLS="${CSE148_TOOLS:-/root/mips_cpu_deps}"
USE_DOCKER=1
if [ "${1:-}" = "--no-docker" ]; then USE_DOCKER=0; fi

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# verilator_files is the authoritative list of what is actually in the machine.
# Do not glob mips_core/*.sv: that misses ooo/ and branch_predictor_files/, and
# it drags in the retired predictors that are still sitting in the tree.
[ -f "$RTL/verilator_files" ] || die "no $RTL/verilator_files"
FILES="$(tr -d '\r' < "$RTL/verilator_files" | sed '/^[[:space:]]*$/d' | tr '\n' ' ')"
mkdir -p "$BUILD"

# SIMULATION is deliberately left undefined. That drops every `import "DPI-C"`
# of stats_event along with its call sites and the $display/$fatal blocks, and
# it removes the behavioural OpenRAM model from cache_bank.sv -- which is what
# turns `sram` into the black box src/sram_sky130.v binds to a real macro.
say "lowering $(printf '%s' "$FILES" | wc -w) SystemVerilog files with sv2v"
if [ "$USE_DOCKER" = 1 ]; then
	command -v docker >/dev/null || die "docker not found; try --no-docker"
	if [ -n "${MSYSTEM:-}" ]; then WIN="$(cd "$REPO" && pwd -W)"; else WIN="$REPO"; fi
	MSYS_NO_PATHCONV=1 docker run --rm -v "$WIN:/work" -w /work/mips_cpu "$IMAGE" \
		bash -lc "$TOOLS/sv2v/bin/sv2v -Imips_core --top=mips_core $FILES" > "$FLAT.tmp"
else
	SV2V="$(command -v sv2v || echo "${CSE148_TOOLS:-}/sv2v/bin/sv2v")"
	[ -x "$SV2V" ] || die "no sv2v on PATH and none at $SV2V"
	( cd "$RTL" && "$SV2V" -Imips_core --top=mips_core $FILES ) > "$FLAT.tmp"
fi

[ -s "$FLAT.tmp" ] || die "sv2v produced nothing"
# sv2v exits 0 on some recoverable problems, so check the output itself.
if grep -q 'DPI-C\|stats_event' "$FLAT.tmp"; then
	grep -n 'DPI-C\|stats_event' "$FLAT.tmp" | head
	die "simulation-only statistics calls survived; they need an \`ifdef SIMULATION guard in the RTL"
fi
mv "$FLAT.tmp" "$FLAT"
say "build/mips_core.v ($(wc -l < "$FLAT") lines, $(grep -c '^module ' "$FLAT") modules)"

TAR="$BUILD/mips_core_lowered.tar.gz"
tar -czf "$TAR" -C "$HERE" build/mips_core.v
say "packaged $TAR ($(du -h "$TAR" | cut -f1))"

cat <<'NEXT'

Next, on nanoHUB:

  1. https://nanohub.org/resources/librelane -> Launch Tool
  2. git clone https://github.com/dillwang/Advanced-CPU-Optimization.git
  3. upload mips_core_lowered.tar.gz, then
     tar xzf mips_core_lowered.tar.gz -C Advanced-CPU-Optimization/asic
  4. cd Advanced-CPU-Optimization/asic
     ./rtl2gds.sh list
     ./rtl2gds.sh --synth-only all-blocks
     ./rtl2gds.sh core

NEXT
