#!/usr/bin/env bash
#
# rtl2gds.sh -- RTL to GDSII for the MIPS32 out-of-order core, on nanoHUB.
#
# Run this inside a nanoHUB LibreLane session (https://nanohub.org/resources/
# librelane), which bundles LibreLane, OpenROAD, KLayout and ngspice. It also
# runs against a local LibreLane or OpenLane 2 install; nothing in here is
# nanoHUB specific except where it goes looking for the PDK.
#
#   git clone https://github.com/dillwang/Advanced-CPU-Optimization.git
#   cd Advanced-CPU-Optimization/asic
#   ./rtl2gds.sh list                 # what can be hardened, and how big
#   ./rtl2gds.sh tage_m1              # one block
#   ./rtl2gds.sh all-blocks           # every block that stands alone
#   ./rtl2gds.sh core                 # the whole CPU, flat, SRAM macros and all
#   ./rtl2gds.sh hier                 # the whole CPU, bottom up, blocks as macros
#   ./rtl2gds.sh pdk-report           # um^2 per bit: SRAM macro vs flip-flop
#
# The flow runs in six stages and this script drives all of them:
#
#   lower      sv2v            SystemVerilog -> Verilog-2005, sim code dropped
#   synth      Yosys           RTL -> sky130_fd_sc_hd gates
#   floorplan  OpenROAD        die, rows, tracks, power grid, macro placement
#   place      OpenROAD        global + detailed placement, then CTS
#   route      OpenROAD        global + detailed routing, parasitic extraction
#   signoff    OpenROAD/Magic/ static timing, DRC, LVS, antenna, GDS out
#              KLayout/Netgen
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
RTL="$REPO/mips_cpu"
BUILD="$HERE/build"
WORK="$BUILD/work"
RESULTS="$HERE/results"
FLAT="$BUILD/mips_core.v"

# sky130 is the smallest fully open node with a standard cell library and, more
# to the point, the only one whose PDK ships OpenRAM macros -- the caches need
# 54 of them. gf180mcu is 180 nm and has no SRAM; ihp-sg13g2 is also 130 nm but
# is still on LibreLane's dev branch. sky130_fd_sc_hd is the high density
# variant, the smallest cells in the kit.
PDK="${PDK:-sky130A}"
SCL="${SCL:-sky130_fd_sc_hd}"
PDK_ROOT="${PDK_ROOT:-}"

PERIOD=10          # ns; 100 MHz is a deliberately loose starting constraint
UTIL=40            # % core utilisation
TAG="$(date +%Y%m%d_%H%M%S)"
# Blocks in parallel, but not one per core: each flow spawns OpenROAD, Magic
# and KLayout, and four large designs at once will already saturate the memory
# on a shared node.
JOBS="$( { command -v nproc >/dev/null && nproc; } || echo 1 )"
[ "$JOBS" -gt 4 ] && JOBS=4
FETCH_SV2V=0
SYNTH_ONLY=0
DRY=0
RESUME=0
FROM_STEP=""
REPAIR=0
MAX_LAYER=""       # empty = the PDK default, met5 on sky130A
CLOCK_GATE=0
HIER_MODE=""
CHILD_MAX_LAYER="${CHILD_MAX_LAYER:-met4}"
# slang reads the SystemVerilog directly through LibreLane (USE_SLANG) and
# keeps every module. sv2v lowers it here first and inlines anything with an
# interface port. slang is both less work and a better hierarchy to cut, so it
# is the default; sv2v stays for a LibreLane built without the plugin.
FRONTEND="${FRONTEND:-slang}"
SV_FILES=()
FLOW_KIND=""       # librelane | openlane2 | openlane1
FLOW_CMD=""

c_hd=$'\033[1;36m'; c_ok=$'\033[1;32m'; c_wn=$'\033[1;33m'; c_er=$'\033[1;31m'; c_0=$'\033[0m'
say()  { printf '%s==>%s %s\n' "$c_hd" "$c_0" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$c_ok" "$c_0" "$*"; }
warn() { printf '%swarn%s %s\n' "$c_wn" "$c_0" "$*" >&2; }
die()  { printf '%serr %s %s\n' "$c_er" "$c_0" "$*" >&2; exit 1; }

usage() {
	sed -n '3,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
	cat <<'OPT'
Options:
  -p, --period NS      target clock period          (default 10 ns = 100 MHz)
  -u, --util PCT       core utilisation             (default 40)
  -k, --pdk NAME       PDK                          (default sky130A)
  -s, --scl NAME       standard cell library        (default sky130_fd_sc_hd)
  -r, --pdk-root PATH  PDK root                     (default: autodetected)
  -t, --tag TAG        run tag                      (default: a timestamp)
  -j, --jobs N         parallel jobs for all-blocks (default: nproc)
      --fetch-sv2v     download sv2v if it is not already here
      --synth-only     stop after Yosys; area and cell counts, no GDS
      --dry-run        print what would run, run nothing
      --resume         continue the newest run of each design instead of
                       starting a fresh one
      --from STEP      resume from a named step, e.g. OpenROAD.GlobalRouting
      --repair N       on a failed signoff, retry up to N times with looser
                       constraints (default 2)
      --max-layer L    RT_MAX_LAYER for the top design (default: PDK's met5)
      --clock-gate N   gate enabled flop groups of >= N bits (default off)
      --hierarchy M    SYNTH_HIERARCHY_MODE: flatten (LibreLane's default),
                       deferred_flatten, or keep
      --frontend F     slang (default; LibreLane reads the SystemVerilog) or
                       sv2v (lower it to Verilog-2005 here first)

Environment:
  HIER_CUTS   which modules `hier` hardens into macros before the top
              (default: statistical_corrector tage_m1)
OPT
	exit "${1:-0}"
}

TARGETS=()
while [ $# -gt 0 ]; do
	case "$1" in
		-p|--period)   PERIOD="$2"; shift 2 ;;
		-u|--util)     UTIL="$2"; shift 2 ;;
		-k|--pdk)      PDK="$2"; shift 2 ;;
		-s|--scl)      SCL="$2"; shift 2 ;;
		-r|--pdk-root) PDK_ROOT="$2"; shift 2 ;;
		-t|--tag)      TAG="$2"; shift 2 ;;
		-j|--jobs)     JOBS="$2"; shift 2 ;;
		--fetch-sv2v)  FETCH_SV2V=1; shift ;;
		--synth-only)  SYNTH_ONLY=1; shift ;;
		--dry-run)     DRY=1; shift ;;
		--resume)      RESUME=1; shift ;;
		--from)        FROM_STEP="$2"; RESUME=1; shift 2 ;;
		--repair)      REPAIR="${2:-2}"; shift 2 ;;
		--max-layer)   MAX_LAYER="$2"; shift 2 ;;
		--clock-gate)  CLOCK_GATE="${2:-8}"; shift 2 ;;
		--hierarchy)   HIER_MODE="$2"; shift 2 ;;
		--frontend)    FRONTEND="$2"; shift 2 ;;
		-h|--help)     usage 0 ;;
		-*)            usage 1 ;;
		*)             TARGETS+=("$1"); shift ;;
	esac
done
[ ${#TARGETS[@]} -gt 0 ] || usage 1

run() { if [ "$DRY" = 1 ]; then printf '   $ %s\n' "$*"; else "$@"; fi; }

# Probe rather than trust `command -v`: on Windows the python3 on PATH is a
# Microsoft Store stub that exits non-zero, and nanoHUB has both names.
PY=""
for c in python3 python; do
	command -v "$c" >/dev/null 2>&1 || continue
	"$c" -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' 2>/dev/null \
		&& { PY="$c"; break; }
done
[ -n "$PY" ] || die "no working python3 on PATH"

# =========================================================== stage 0: tooling
# Where an installation might be, beyond PATH. nanoHUB installs LibreLane under
# /apps and exports PDK_ROOT pointing into it, without necessarily putting the
# entry point on PATH -- so the PDK it already found is the best clue about
# where the rest of it lives.
# Roots that might hold an install, nearest first. PDK_ROOT is the strongest
# clue: nanoHUB exports it pointing inside the very tree the flow lives in.
flow_roots() {
	local roots=() d
	[ -n "$PDK_ROOT" ] && roots+=("${PDK_ROOT%/pdks}")
	[ -n "${LIBRELANE_ROOT:-}" ] && roots+=("$LIBRELANE_ROOT")
	# Anything already on PATH whose own path mentions the tool. nanoHUB puts
	# /apps/librelane/r8/bin at the front of PATH, which says exactly where the
	# install is even when the entry point is not called `librelane`.
	while IFS= read -r d; do
		case "$d" in
		*librelane*|*openlane*|*LibreLane*) roots+=("$d" "${d%/bin}") ;;
		esac
	done < <(printf '%s\n' "${PATH//:/$'\n'}")
	# LibreLane 3 is packaged with Nix, so a real install looks like
	# <root>/nix/store/<hash>-librelane-3.0.4/bin/librelane. Glob straight to
	# those package directories: they are five levels down, and walking a whole
	# Nix store with find is both slow and unnecessary.
	roots+=("${PDK_ROOT%/pdks}"/nix/store/*librelane*
	        /apps/share64/*/librelane/librelane-*/nix/store/*librelane*
	        /apps/librelane/*/nix/store/*librelane*)
	roots+=(/apps/librelane/*/bin /apps/librelane/* /apps/librelane
	        /apps/share64/*/librelane/librelane-* /apps/share64/*/librelane
	        /opt/librelane /usr/local/librelane "$HOME/LIBRELANE" "$HOME/OPENROAD")
	# Prefer roots carrying the same version string as the PDK. There are six
	# LibreLane versions on this machine and picking one at random to drive
	# another one's PDK is how you get a failure that blames the wrong thing.
	local ver=""
	case "$PDK_ROOT" in
	*librelane-*) ver="${PDK_ROOT#*librelane-}"; ver="librelane-${ver%%/*}" ;;
	esac
	printf '%s\n' "${roots[@]}" | awk -v v="$ver" '
		NF && !seen[$0]++ { if (v != "" && index($0, v)) first[++f] = $0; else rest[++r] = $0 }
		END { for (i = 1; i <= f; i++) print first[i]
		      for (i = 1; i <= r; i++) print rest[i] }'
}

# LibreLane needs Python 3.8 or newer -- librelane/__version__.py imports
# importlib.metadata, which does not exist before then. nanoHUB's /usr/bin
# python3 is 3.6, so the interpreter that runs this script is not necessarily
# one that can run the flow. Look for a better one, preferring whatever ships
# beside the install.
flow_python() {
	local r c v
	{
		while read -r r; do
			printf '%s\n' "$r/bin/python3" "$r/venv/bin/python3" \
			              "$r/.venv/bin/python3"
			# A Nix-built LibreLane brings its own interpreter, with the
			# package already importable. Prefer it over anything on PATH:
			# nanoHUB's /usr/bin/python3 is 3.6 and cannot import librelane
			# at all.
			ls -d "$r"/nix/store/*python3*/bin/python3 2>/dev/null || true
		done < <(flow_roots)
		printf '%s\n' python3.13 python3.12 python3.11 python3.10 python3.9 \
		              python3.8 python3
	} | while read -r c; do
		command -v "$c" >/dev/null 2>&1 || [ -x "$c" ] || continue
		v="$("$c" -c 'import sys; print(sys.version_info[0]*100+sys.version_info[1])' 2>/dev/null)" || continue
		[ -n "$v" ] && [ "$v" -ge 308 ] && { printf '%s\n' "$c"; break; }
	done
}

# Search the roots rather than guess at bin/ and venv/bin/. A Nix-built
# LibreLane puts its entry point somewhere none of those guesses would reach,
# and there is no reason to keep adding guesses when find will just tell us.
flow_candidates() {
	local r
	while read -r r; do
		[ -d "$r" ] || continue
		# Not just the exact names: a nanoHUB install may wrap it as
		# librelane.sh, librelane-3.0.4, or a launcher with a version suffix.
		find "$r" -maxdepth 3 -type f -perm -u+x \
			\( -name 'librelane*' -o -name 'openlane*' \) 2>/dev/null \
			| grep -vE '\.(py|pyc|json|yaml|yml|md|txt|log|nix)$'
	done < <(flow_roots)
}

# Failing an executable, an importable package is just as good: LibreLane is a
# Python module and `python -m librelane` is a documented way in.
flow_python_path() {
	local r p hit
	while read -r r; do
		[ -d "$r" ] || continue
		for p in "$r"/lib/python*/site-packages "$r"/lib64/python*/site-packages \
		         "$r"/venv/lib/python*/site-packages "$r"; do
			[ -d "$p/librelane" ] && { printf '%s\n' "$p"; return 0; }
		done
		# The shallow guesses miss some layouts; look properly before moving on
		# to the next root, so the root nearest the PDK gets a fair chance.
		hit="$(find "$r" -maxdepth 6 -type d -name librelane \
			-exec test -f '{}/__main__.py' \; -print 2>/dev/null | head -1)"
		[ -n "$hit" ] && { printf '%s\n' "$(dirname "$hit")"; return 0; }
	done < <(flow_roots)
	return 1
}

# The flow and the PDK are versioned together. Picking a dev build to drive a
# release PDK is the kind of mismatch that produces a confusing failure three
# steps in, so say so plainly rather than let it pass.
warn_version_skew() {
	local used="$1"
	local pdkroot="${PDK_ROOT%/pdks}"
	[ -n "$pdkroot" ] || return 0
	case "$used" in
	"$pdkroot"*) return 0 ;;
	esac
	warn "the flow and the PDK come from different installs:
     flow $used
     pdk  $pdkroot
     If a step fails oddly, point -r at the PDK beside the flow, or set
     \$LIBRELANE to the entry point beside the PDK."
	return 0
}

find_flow() {
	local c
	if [ -n "${LIBRELANE:-}" ];              then FLOW_KIND=librelane; FLOW_CMD="$LIBRELANE"
	elif command -v librelane >/dev/null;    then FLOW_KIND=librelane; FLOW_CMD=librelane
	elif $PY -c 'import librelane' 2>/dev/null; then
		FLOW_KIND=librelane; FLOW_CMD="$PY -m librelane"
	elif command -v openlane >/dev/null;     then FLOW_KIND=openlane2; FLOW_CMD=openlane
	elif $PY -c 'import openlane' 2>/dev/null; then
		FLOW_KIND=openlane2; FLOW_CMD="$PY -m openlane"
	elif [ -n "${OPENLANE_ROOT:-}" ] && [ -f "$OPENLANE_ROOT/flow.tcl" ]; then
		FLOW_KIND=openlane1; FLOW_CMD="$OPENLANE_ROOT/flow.tcl"
	elif c="$(flow_candidates | head -1)" && [ -n "$c" ]; then
		case "$c" in
		*openlane) FLOW_KIND=openlane2 ;;
		*)         FLOW_KIND=librelane ;;
		esac
		FLOW_CMD="$c"
		ok "found $FLOW_CMD off PATH"
		warn_version_skew "$c"
	elif c="$(flow_python_path)" && [ -n "$c" ]; then
		local interp
		interp="$(flow_python)"
		[ -n "$interp" ] || die "found a librelane package at
     $c
     but no Python 3.8+ to run it with. \$(command -v python3) is
     $($PY -c 'import sys; print(".".join(map(str, sys.version_info[:3])))'),
     and librelane/__version__.py imports importlib.metadata, which needs 3.8.

     The install almost certainly ships its own interpreter. Look for it:
       ls /apps/librelane/*/bin
       ls ${PDK_ROOT%/pdks}/bin
     then re-run with  LIBRELANE='/path/to/python3 -m librelane' ./rtl2gds.sh ..."
		FLOW_KIND=librelane
		FLOW_CMD="env PYTHONPATH=$c${PYTHONPATH:+:$PYTHONPATH} $interp -m librelane"
		ok "importing librelane from $c"
		ok "running it with $interp ($("$interp" -c 'import sys; print(".".join(map(str, sys.version_info[:3])))'))"
		warn_version_skew "$c"
	elif [ "$DRY" = 1 ]; then
		FLOW_KIND=librelane; FLOW_CMD=librelane
		warn "no flow installed; --dry-run assumes LibreLane"
	else
		printf '%ssearched these roots, no executable and no importable\n     librelane package under any of them:%s\n' "$c_wn" "$c_0" >&2
		flow_roots | sed 's/^/     /' >&2
		die "no LibreLane, OpenLane 2 or OpenLane 1 found.

     PDK_ROOT is ${PDK_ROOT:-unset}, so the install is right there and only
     its entry point is missing. Show what the tree actually looks like:

       ls ${PDK_ROOT%/pdks}
       find ${PDK_ROOT%/pdks} -maxdepth 4 -name 'librelane*' 2>/dev/null | head -30

     PATH already carries a librelane directory, so look there first:

       ls $(printf '%s\n' "${PATH//:/$'\n'}" | grep -i 'librelane\|openlane' | head -1)

     nanoHUB also runs tools through 'submit' rather than directly -- a .submit
     file in a directory is the trace of that. If that is how it works here,
     the whole invocation goes in \$LIBRELANE, which is expanded as a command:

       LIBRELANE='submit -v librelane-3.0.4 librelane' ./rtl2gds.sh ...

     Once you know the entry point:  LIBRELANE='...' ./rtl2gds.sh ..."
	fi
	say "flow: $FLOW_KIND ($FLOW_CMD)"
	[ "$FLOW_KIND" = openlane1 ] && warn "OpenLane 1 is Tcl-era and upstream-dead.
     Blocks will run; 'core' needs LibreLane for its macro handling."
	return 0
}

find_pdk() {
	if [ -z "$PDK_ROOT" ]; then
		for c in "${VOLARE_PDK_ROOT:-}" "$HOME/.volare" "$HOME/.ciel" \
		         /opt/pdk /usr/share/pdk "${OPENLANE_ROOT:-}/pdks"; do
			[ -n "$c" ] && [ -d "$c/$PDK" ] && { PDK_ROOT="$c"; break; }
		done
	fi
	if [ -z "$PDK_ROOT" ]; then
		# LibreLane can fetch the PDK itself; let it, rather than guessing.
		warn "no \$PDK_ROOT holding $PDK found -- letting the flow fetch it"
		return 0
	fi
	[ -d "$PDK_ROOT/$PDK" ] || die "$PDK_ROOT has no $PDK in it"
	say "pdk: $PDK/$SCL under $PDK_ROOT"
	if [ -d "$PDK_ROOT/$PDK/libs.ref/sky130_sram_macros" ]; then
		ok "OpenRAM macros present (the caches need them)"
	else
		warn "no sky130_sram_macros in this PDK build; 'core' will not place caches"
	fi
	return 0
}

find_sv2v() {
	local env_sv2v="${SV2V:-}"
	SV2V=""
	for c in "$env_sv2v" "$BUILD/sv2v" "$(command -v sv2v || true)" \
	         "${CSE148_TOOLS:-}/sv2v/bin/sv2v"; do
		# lower() runs sv2v from inside $RTL, so a relative path would break.
		[ -n "$c" ] && [ -x "$c" ] && { SV2V="$(cd "$(dirname "$c")" && pwd)/$(basename "$c")"; return 0; }
	done
	if [ "$FETCH_SV2V" = 1 ]; then
		# The published sv2v binaries are dynamically linked against a recent
		# glibc. nanoHUB is Rocky 8, which is glibc 2.28, and the current
		# release wants 2.34 -- it downloads fine and then will not run. Check
		# that it actually executes before believing in it.
		say "fetching sv2v"
		mkdir -p "$BUILD"
		local url=https://github.com/zachjs/sv2v/releases/latest/download/sv2v-Linux.zip
		curl -fsSL "$url" -o "$BUILD/sv2v.zip" || die "could not download sv2v (no network?)"
		( cd "$BUILD" && unzip -oq sv2v.zip && find . -name sv2v -type f -exec cp {} sv2v \; )
		chmod +x "$BUILD/sv2v"
		if "$BUILD/sv2v" --version >/dev/null 2>&1; then
			SV2V="$BUILD/sv2v"
			return 0
		fi
		warn "the downloaded sv2v will not run here:
$("$BUILD/sv2v" --version 2>&1 | sed 's/^/     /' | head -4)"
		rm -f "$BUILD/sv2v"
	fi
	return 1
}

# ====================================================== stage 1: lower the RTL
# Yosys reads Verilog-2005. This core is SystemVerilog throughout -- packages,
# interfaces, structs, unpacked arrays of them -- so it has to be lowered first.
#
# SIMULATION is deliberately left undefined, which does three things at once:
# it drops every `import "DPI-C"` of stats_event and its call sites, it drops
# the $display/$fatal assertion blocks, and it removes the behavioural OpenRAM
# model from cache_bank.sv so that `sram` becomes the black box the macro
# mapping in src/sram_sky130.v then binds to a real 32x256 array.
# The authoritative file list, absolute, in compile order. Globbing
# mips_core/*.sv misses ooo/ and branch_predictor_files/ and picks up the
# retired predictors, so verilator_files is what decides.
sv_files() {
	[ -f "$RTL/verilator_files" ] || die "no $RTL/verilator_files"
	SV_FILES=()
	local f
	while read -r f; do
		[ -n "$f" ] || continue
		[ -f "$RTL/$f" ] || die "verilator_files names $f, which is not there"
		SV_FILES+=("$RTL/$f")
	done < <(tr -d '' < "$RTL/verilator_files" | sed '/^[[:space:]]*$/d')
	ok "${#SV_FILES[@]} SystemVerilog sources"
}

lower() {
	[ -f "$RTL/verilator_files" ] || die "no $RTL/verilator_files"
	if [ -s "$FLAT" ] && [ "$FLAT" -nt "$RTL/verilator_files" ] &&
	   [ -z "$(find "$RTL/mips_core" -name '*.sv' -newer "$FLAT" -print -quit)" ]; then
		ok "build/mips_core.v is up to date"
		return 0
	fi
	if ! find_sv2v; then
		# A file uploaded from prepare.sh is the whole point of that script, and
		# a fresh git clone can stamp the .sv files after it. Use it and say so
		# rather than refusing to run.
		if [ -s "$FLAT" ]; then
			warn "no sv2v here, but build/mips_core.v exists -- using it as is.
     If you changed the RTL, it is stale: re-run with --fetch-sv2v."
			return 0
		fi
		die "sv2v is not usable here, and there is no build/mips_core.v to fall
     back on. You probably do not need it: --frontend slang (the default)
     has LibreLane read the SystemVerilog directly and skips sv2v entirely.
     Otherwise run asic/prepare.sh on a machine with the CSE148 container
     and upload the resulting build/mips_core.v."
	fi
	# verilator_files is the authoritative list of what is in the machine.
	# Globbing mips_core/*.sv misses ooo/ and branch_predictor_files/, and picks
	# up the retired predictors still sitting in the tree.
	local files
	files="$(tr -d '\r' < "$RTL/verilator_files" | sed '/^[[:space:]]*$/d' | tr '\n' ' ')"
	say "lowering $(printf '%s' "$files" | wc -w) SystemVerilog files with sv2v"
	mkdir -p "$BUILD"
	( cd "$RTL" && $SV2V -Imips_core --top=mips_core $files ) > "$FLAT.tmp"
	[ -s "$FLAT.tmp" ] || die "sv2v produced nothing"
	# sv2v exits 0 on some recoverable problems, so check the output itself.
	if grep -q 'DPI-C\|stats_event' "$FLAT.tmp"; then
		grep -n 'DPI-C\|stats_event' "$FLAT.tmp" | head
		die "simulation-only statistics calls survived. They need an
     \`ifdef SIMULATION guard around the always block in the RTL."
	fi
	mv "$FLAT.tmp" "$FLAT"
	ok "build/mips_core.v ($(wc -l < "$FLAT") lines, $(grep -c '^module ' "$FLAT") modules)"
}

# sv2v inlines any module with a SystemVerilog interface port into its parent,
# so d_cache, i_cache, alu, decoder, lsq and the rest vanish into mips_core.
# Whatever survives as a real module is exactly what can be hardened alone.
# Everything downstream asks for the sources through these two, so the choice
# of frontend is made once, here.
front() {
	case "$FRONTEND" in
	slang) sv_files ;;
	sv2v)  lower; SV_FILES=() ;;
	*)     die "unknown --frontend '$FRONTEND'; try slang or sv2v" ;;
	esac
}

# The arguments that name this design's RTL, whichever frontend is in use.
src_args() {
	if [ "$FRONTEND" = slang ]; then
		local f
		for f in "${SV_FILES[@]}"; do printf '%s
--sv-file
%s
' "" "$f"; done 			| sed '/^$/d'
		printf -- '--include-dir
%s
' "$RTL/mips_core"
	else
		printf -- '--verilog
%s
' "$FLAT"
	fi
}

# Ask the config generator, so this answers for whichever frontend is in use.
# It used to read $FLAT directly, which does not exist under --frontend slang.
modules() {
	local src=()
	while IFS= read -r line; do src+=("$line"); done < <(src_args)
	"$PY" "$HERE/scripts/gen_config.py" --list-modules "${src[@]}"
}
block_list()   { modules | grep -vx 'mips_core'; }

do_list() {
	front
	say "hardenable modules ($FRONTEND frontend)"
	local src=()
	while IFS= read -r line; do src+=("$line"); done < <(src_args)
	"$PY" "$HERE/scripts/gen_config.py" --probe "${src[@]}"
	if [ "$FRONTEND" = sv2v ]; then
		cat <<'NOTE'

    sv2v inlines any module with a SystemVerilog interface port into its
    parent, so d_cache, i_cache, alu, decoder, lsq, ooo_backend, stream_buffer
    and d_prefetcher are not here -- they went into mips_core. --frontend slang
    keeps them, and is the default.
NOTE
	fi
}

# ==================================== stages 2-6: hand one module to the flow
# LibreLane's Classic flow is what actually walks synthesis -> floorplan ->
# placement -> CTS -> routing -> signoff. These functions' job is to hand it a
# correct config and then get the results back out.
#
# MACRO_OF holds the modules already hardened, mapped to where their views ended
# up. A module listed there is cut out of its parent's source and declared as a
# placed black box instead, which is what bounds the parent's problem.
declare -A MACRO_OF=()

write_config() {
	local mod="$1"
	local extra="${2:-}"
	local dir="$WORK/$mod"
	mkdir -p "$dir"

	local args=()
	if [ -f "$HERE/src/sram_sky130.v" ]; then
		args+=(--sram-verilog "$HERE/src/sram_sky130.v")
	fi
	local child
	for child in "${!MACRO_OF[@]}"; do
		args+=(--macro "$child=${MACRO_OF[$child]}")
	done

	# RT_MAX_LAYER. MOD_MAX_LAYER is set per design by do_hier: a block that is
	# going to be placed inside a parent must stop a layer short, so the parent
	# has one to route over it on and the PDN keeps met5 for straps.
	local layer="${MOD_MAX_LAYER:-$MAX_LAYER}"
	[ -n "$layer" ] && args+=(--max-layer "$layer")
	[ "$CLOCK_GATE" != 0 ] && args+=(--clock-gate "$CLOCK_GATE")
	[ -n "$HIER_MODE" ] && args+=(--hierarchy-mode "$HIER_MODE")

	# Always run, even under --dry-run: this only writes local files, and doing
	# it is what lets the dry run tell you which designs carry macros and so
	# need two passes. It also leaves the configs there to read.
	#
	# The status has to be checked by hand. harden() is called from an || list,
	# and bash turns errexit off for everything underneath one -- so a failure
	# here would otherwise print its message and carry on to hand the flow a
	# config.json that does not exist.
	local src=()
	while IFS= read -r line; do src+=("$line"); done < <(src_args)

	rm -f "$dir/config.json"
	if ! "$PY" "$HERE/scripts/gen_config.py" "$mod" \
		"${src[@]}" ${args[@]+"${args[@]}"} \
		--out "$dir/config.json" \
		--period "$PERIOD" --util "$UTIL" \
		--pdk-root "$PDK_ROOT" --pdk "$PDK" \
		--flow "$([ "$FLOW_KIND" = openlane1 ] && echo openlane1 || echo librelane)" \
		${extra:+--extra "$extra"}
	then
		warn "$mod: could not write a config"
		return 1
	fi
	[ -s "$dir/config.json" ] || { warn "$mod: gen_config wrote nothing"; return 1; }
	return 0
}

run_flow() {
	local mod="$1"
	local stop="${2:-}"
	local dir="$WORK/$mod"

	# LibreLane checkpoints every step into runs/<tag>/<NN>-<step>/state_out.json
	# on its own. What makes a run resumable is not re-tagging it: --last-run
	# picks up the newest run directory for this design and carries its state
	# forward, and --from re-enters at a named step.
	local fargs=()
	if [ "$RESUME" = 1 ] && [ -d "$dir/runs" ] && [ -n "$(ls -A "$dir/runs" 2>/dev/null)" ]; then
		fargs+=(--last-run)
		[ -n "$FROM_STEP" ] && fargs+=(--from "$FROM_STEP")
		say "$mod: resuming $(basename "$(ls -1dt "$dir"/runs/*/ | head -1)")"
	else
		fargs+=(--run-tag "$TAG")
	fi
	[ -n "$PDK_ROOT" ] && fargs+=(--pdk-root "$PDK_ROOT")
	fargs+=(--pdk "$PDK" --scl "$SCL")
	[ "$stop" = synth ] && fargs+=(--to Yosys.Synthesis)

	if [ "$FLOW_KIND" = openlane1 ]; then
		run $FLOW_CMD -design "$dir" -tag "$TAG" \
			$([ "$stop" = synth ] && echo "-to synthesis")
	else
		run $FLOW_CMD "${fargs[@]}" "$dir/config.json"
	fi
}

# True if the config declares any macros. Anything that does needs an explicit
# floorplan: LibreLane places standard cells on its own, never a hard macro.
has_macros() {
	local cfg="$WORK/$1/config.json"
	[ -f "$cfg" ] || return 1
	"$PY" -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("MACROS") else 1)' \
		"$cfg" 2>/dev/null
}

# Where a run left its metrics. A run stopped early with --to writes no final/,
# but the numbers are still in the last step's state_out.json.
run_metrics() {
	local run="$1"
	if [ -f "$run/final/metrics.json" ]; then
		printf '%s' "$run/final/metrics.json"
	else
		ls -1dt "$run"/*/state_out.json 2>/dev/null | head -1 || true
	fi
}

# OpenROAD is not Innovus and this is worth being straight about: the Classic
# flow has no post-detailed-route optimisation step. Its resizers --
# RepairDesignPostGRT, ResizerTimingPostGRT, RepairAntennas -- all run after
# GLOBAL routing and before DetailedRouting, so there is no `optDesign
# -postroute -drv -inc` to call twice. What you can do instead is re-run with
# the constraint that caused the violation loosened, and that is what this does.
#
# Each attempt changes one class of thing, cheapest first:
#
#   1  let the router work harder      more DRT_OPT_ITERS, more antenna repair
#                                      iterations, and stop erroring out so the
#                                      count is reported rather than fatal
#   2  give it room                    drop utilisation ~10 points, which grows
#                                      the die, and relax placement density
#   3  unblock the tracks              widen the PDN pitch, so there are fewer
#                                      straps standing between the router and
#                                      the cells, and free a routing layer
#
# 3 is last because it is the one that trades a real thing away: a sparser grid
# means more IR drop, and OpenROAD.IRDropReport is the number to check after.
repair_extra() {
	local attempt="$1"
	case "$attempt" in
	1) cat <<'JSON'
{"DRT_OPT_ITERS": 128,
 "DRT_ANTENNA_REPAIR_ITERS": 5,
 "GRT_ALLOW_CONGESTION": true,
 "ERROR_ON_MAGIC_DRC": false,
 "ERROR_ON_KLAYOUT_DRC": false,
 "ERROR_ON_KLAYOUT_ANTENNA": false}
JSON
	   ;;
	2) "$PY" -c 'import json,sys
u = float(sys.argv[1])
print(json.dumps({
    "FP_CORE_UTIL": max(u - 10.0, 15.0),
    "PL_TARGET_DENSITY_PCT": max(u - 5.0, 20.0),
    "DRT_OPT_ITERS": 128,
    "DRT_ANTENNA_REPAIR_ITERS": 5,
    "GRT_ALLOW_CONGESTION": True,
    "ERROR_ON_MAGIC_DRC": False,
    "ERROR_ON_KLAYOUT_DRC": False,
    "ERROR_ON_KLAYOUT_ANTENNA": False,
}))' "$UTIL"
	   ;;
	*) "$PY" -c 'import json,sys
u = float(sys.argv[1])
print(json.dumps({
    "FP_CORE_UTIL": max(u - 15.0, 12.0),
    "PL_TARGET_DENSITY_PCT": max(u - 10.0, 18.0),
    "FP_PDN_VPITCH": 90.0,
    "FP_PDN_HPITCH": 90.0,
    "DRT_OPT_ITERS": 128,
    "DRT_ANTENNA_REPAIR_ITERS": 5,
    "DRT_THREADS": 4,
    "GRT_ALLOW_CONGESTION": True,
    "ERROR_ON_MAGIC_DRC": False,
    "ERROR_ON_KLAYOUT_DRC": False,
    "ERROR_ON_KLAYOUT_ANTENNA": False,
}))' "$UTIL"
	   ;;
	esac
}

# How many DRC, antenna and LVS errors the newest run of $1 reported.
violations() {
	local m="$1"
	local f="$RESULTS/$m/metrics.json"
	[ -f "$f" ] || { echo "-1"; return; }
	"$PY" -c 'import json,sys
m = json.load(open(sys.argv[1]))
m = m.get("metrics", m)
keys = ("magic__drc_error__count", "klayout__drc_error__count",
        "design__lvs_error__count", "route__antenna_violation__count",
        "route__drc_errors")
print(sum(int(m.get(k) or 0) for k in keys))' "$f" 2>/dev/null || echo "-1"
}

# Run the full flow, and if it comes back dirty, try again with one class of
# constraint loosened. `base` is JSON merged into every attempt -- the floorplan,
# for a design that has macros.
run_with_repair() {
	local mod="$1"
	local base="${2:-}"
	local attempt=0
	local rc=0

	while :; do
		local extra="$base"
		if [ "$attempt" -gt 0 ]; then
			say "$mod: repair attempt $attempt of $REPAIR"
			extra="$("$PY" -c 'import json,sys
base = json.loads(sys.argv[1]) if sys.argv[1] else {}
base.update(json.loads(sys.argv[2]))
print(json.dumps(base))' "$base" "$(repair_extra "$attempt")")"
			write_config "$mod" "$extra" || return 1
		fi

		rc=0
		run_flow "$mod" || rc=$?
		[ "$DRY" = 1 ] && return 0

		collect "$mod"
		local v; v="$(violations "$mod")"

		if [ "$rc" = 0 ] && [ "$v" = 0 ]; then
			[ "$attempt" -gt 0 ] && ok "$mod: clean after $attempt repair attempt(s)"
			return 0
		fi
		if [ "$attempt" -ge "$REPAIR" ]; then
			[ "$REPAIR" -gt 0 ] && warn "$mod: still $v violation(s) after $REPAIR attempt(s)"
			return "$rc"
		fi
		warn "$mod: exit $rc, $v violation(s) -- retrying with looser constraints"
		attempt=$((attempt + 1))
	done
}

harden() {
	local mod="$1"
	local dir="$WORK/$mod"

	write_config "$mod" || return 1

	if [ "$SYNTH_ONLY" = 1 ]; then
		say "$mod: synthesis only"
		run_flow "$mod" synth
		return 0
	fi

	if ! has_macros "$mod"; then
		say "$mod: running the flow (no macros, so one pass)"
		run_with_repair "$mod"
		return $?
	fi

	# With macros the run is two passes: their instance paths do not exist
	# until synthesis has flattened the hierarchy, and the floorplan needs them.
	say "$mod: pass 1 of 2, synthesis, to find out what the macro instances are called"
	run_flow "$mod" synth
	[ "$DRY" = 1 ] && return 0

	local runsdir; runsdir="$(ls -1dt "$dir"/runs/*/ 2>/dev/null | head -1)"
	local nl
	nl="$(find "$runsdir" \( -name '*.nl.v' -o -name '*.synthesis.v' \) 2>/dev/null | head -1)"
	[ -n "$nl" ] || { warn "$mod: no synthesised netlist under $runsdir"; return 1; }

	say "$mod: pass 2 of 2, floorplanning its macros, then the full flow"
	"$PY" "$HERE/scripts/gen_floorplan.py" \
		--netlist "$nl" \
		--config "$dir/config.json" \
		--metrics "$(run_metrics "$runsdir")" \
		--util "$UTIL" \
		--out "$dir/floorplan.json" || return 1

	local fp; fp="$(cat "$dir/floorplan.json")"
	write_config "$mod" "$fp" || return 1
	local pass1="$TAG"
	TAG="${TAG}_full"
	run_with_repair "$mod" "$fp"
	local rc=$?
	TAG="$pass1"
	return $rc
}

# Hierarchical: harden the leaves first, then everything above them with those
# leaves as placed black boxes. The order comes out of the instantiation graph,
# so it stays right if the RTL changes.
#
# Which modules are worth cutting is a ratio question -- state held against port
# bits crossing the boundary. tage_m1 keeps ~504,000 flops behind 191 port bits
# and statistical_corrector ~238,000 behind 339, so cutting there takes about
# 90% of the machine's non-cache state out of the top-level run. rename_rob is
# the opposite -- 2,410 port bits guarding ~10,000 flops -- and hardening it
# would cost area and cross-boundary timing for nothing.
HIER_CUTS_DEFAULT="statistical_corrector tage_m1"

do_hier() {
	local top="${1:-mips_core}"
	local cuts="${HIER_CUTS:-$HIER_CUTS_DEFAULT}"
	local order
	# hier_order takes the same source arguments, minus the include path,
	# which only the config needs.
	local hsrc=() src=()
	while IFS= read -r line; do src+=("$line"); done < <(src_args)
	local i=0
	while [ "$i" -lt "${#src[@]}" ]; do
		if [ "${src[$i]}" = "--include-dir" ]; then i=$((i + 2)); continue; fi
		hsrc+=("${src[$i]}")
		i=$((i + 1))
	done
	order="$("$PY" "$HERE/scripts/hier_order.py" "${hsrc[@]}" --top "$top" $cuts)"
	say "hierarchical order: $order"

	local m
	for m in $order; do
		say "=== $m ==="
		# A block that is going to be placed inside a parent must stop one
		# routing layer short of the top. Otherwise it fills met5 with its own
		# nets, and the parent has nothing left to route over it on -- and the
		# PDN wants met5 for straps besides. Only the top gets every layer.
		if [ "$m" = "$top" ]; then
			MOD_MAX_LAYER="$MAX_LAYER"
		else
			MOD_MAX_LAYER="$CHILD_MAX_LAYER"
			say "$m: RT_MAX_LAYER=$MOD_MAX_LAYER, reserving the top layer for $top"
		fi
		harden "$m" || { warn "$m did not finish; the designs above it need it"; MOD_MAX_LAYER=""; return 1; }
		MOD_MAX_LAYER=""
		[ "$DRY" = 1 ] || collect "$m"
		# Only feed a block upward once it actually has views to feed.
		if [ "$m" = "$top" ]; then
			continue
		elif [ -f "$RESULTS/$m/$m.lef" ]; then
			MACRO_OF["$m"]="$RESULTS/$m"
			ok "$m is now a macro for everything above it"
		elif [ "$DRY" = 1 ]; then
			warn "$m has no LEF yet, so the designs above it are previewed
     without it -- a dry run can only show the first link of a chain."
		else
			warn "$m produced no LEF, so it cannot be a macro; stopping"
			return 1
		fi
	done
	return 0
}

# ============================================================ results, summary
collect() {
	local mod="$1" dir="$WORK/$1"
	local run; run="$(ls -1dt "$dir"/runs/*/ 2>/dev/null | head -1)" || true
	[ -n "$run" ] || { warn "$mod: no run directory"; return 0; }
	mkdir -p "$RESULTS/$mod"
	local f
	for f in "$run/final/gds/$mod.gds" "$run/final/def/$mod.def" \
	         "$run/final/nl/$mod.nl.v" "$run/final/metrics.json"; do
		[ -e "$f" ] && cp "$f" "$RESULTS/$mod/" 2>/dev/null || true
	done
	# lef, lib and per-corner spef are what let this block become a macro in
	# whatever sits above it, so keep the directory structure -- gen_config
	# reads the corner from each file's parent directory name.
	local d
	for d in lef lib spef; do
		[ -d "$run/final/$d" ] && cp -r "$run/final/$d" "$RESULTS/$mod/" 2>/dev/null || true
	done
	# LibreLane names the abstract LEF after the design; make sure it is where
	# gen_config looks for it either way.
	[ -f "$RESULTS/$mod/lef/$mod.lef" ] && [ ! -f "$RESULTS/$mod/$mod.lef" ] &&
		cp "$RESULTS/$mod/lef/$mod.lef" "$RESULTS/$mod/" 2>/dev/null || true
	# A run stopped early with --to has no final/ at all. Its numbers are still
	# there, in the last step's state_out.json, and --synth-only is the first
	# thing worth running -- so fall back to that rather than reporting nothing.
	if [ ! -f "$RESULTS/$mod/metrics.json" ]; then
		local last
		last="$(ls -1dt "$run"/*/state_out.json 2>/dev/null | head -1)" || true
		if [ -n "$last" ]; then
			"$PY" -c 'import json,sys
d = json.load(open(sys.argv[1]))
json.dump(d.get("metrics", d), open(sys.argv[2], "w"), indent=2)' \
				"$last" "$RESULTS/$mod/metrics.json" 2>/dev/null || true
		fi
	fi

	if [ -f "$RESULTS/$mod/$mod.gds" ]; then
		ok "$mod: $RESULTS/$mod/$mod.gds"
	elif [ "$SYNTH_ONLY" = 1 ]; then
		ok "$mod: synthesis only, metrics in $RESULTS/$mod/metrics.json"
	else
		warn "$mod: no GDS -- see $run for where it stopped"
	fi
	return 0
}

summary() {
	[ -d "$RESULTS" ] || return 0
	say "summary"
	"$PY" - "$RESULTS" <<'PY'
import json, os, sys
root = sys.argv[1]
cols = ("module", "cells", "area um2", "util %", "WNS ns", "TNS ns", "DRC", "LVS", "antenna")
rows = []
def g(m, *keys):
    for k in keys:
        if k in m and m[k] is not None:
            return m[k]
    return None
for mod in sorted(os.listdir(root)):
    p = os.path.join(root, mod, "metrics.json")
    if not os.path.isfile(p):
        continue
    m = json.load(open(p))
    def fmt(v, n=2):
        return "-" if v is None else (f"{v:.{n}f}" if isinstance(v, float) else str(v))
    rows.append((
        mod,
        fmt(g(m, "design__instance__count")),
        fmt(g(m, "design__instance__area")),
        fmt(g(m, "design__instance__utilization", "design__core__util")),
        fmt(g(m, "timing__setup__ws", "timing__setup__ws__corner:nom_tt_025C_1v80"), 3),
        fmt(g(m, "timing__setup__tns"), 1),
        fmt(g(m, "magic__drc_error__count", "klayout__drc_error__count")),
        fmt(g(m, "design__lvs_error__count")),
        fmt(g(m, "route__antenna_violation__count")),
    ))
if not rows:
    print("    no metrics.json anywhere under", root)
    sys.exit()
w = [max(len(str(r[i])) for r in rows + [cols]) for i in range(len(cols))]
line = "    " + "  ".join(c.ljust(w[i]) for i, c in enumerate(cols))
print(line); print("    " + "-" * (len(line) - 4))
for r in rows:
    print("    " + "  ".join(str(v).ljust(w[i]) for i, v in enumerate(r)))
PY
}

# ========================================================================= main
main() {
	mkdir -p "$BUILD" "$WORK" "$RESULTS"
	case "${TARGETS[0]}" in
		list|--list) do_list; exit 0 ;;
		pdk-report)
			find_pdk
			[ -n "$PDK_ROOT" ] || die "pdk-report needs a PDK; pass -r"
			"$PY" "$HERE/scripts/pdk_report.py" --pdk-root "$PDK_ROOT" \n				--pdk "$PDK" --scl "$SCL" --util "$UTIL"
			exit 0 ;;
	esac

	# PDK first: where it lives is the best clue about where the flow lives.
	find_pdk
	find_flow
	front

	# hier is its own thing: a dependency-ordered sequence, not a set of
	# independent designs, because each run consumes the one before it.
	if [ "${TARGETS[0]}" = hier ]; then
		say "constraint: ${PERIOD} ns period, ${UTIL}% utilisation, tag $TAG"
		do_hier "${TARGETS[1]:-mips_core}" || { summary; return 1; }
		[ "$DRY" = 1 ] || summary
		return 0
	fi

	local want=()
	for t in "${TARGETS[@]}"; do
		case "$t" in
			all-blocks) while read -r m; do want+=("$m"); done < <(block_list) ;;
			core)       want+=(mips_core) ;;
			*)          modules | grep -qx "$t" || die "no module '$t'; try: ./rtl2gds.sh list"
			            want+=("$t") ;;
		esac
	done

	say "hardening: ${want[*]}"
	say "constraint: ${PERIOD} ns period, ${UTIL}% utilisation, tag $TAG"

	# One module at a time keeps the flow's output on the terminal, which is
	# what you want while you are still finding out where it breaks. With -j
	# above 1 the blocks go in parallel and each one's output goes to its own
	# log instead. OpenROAD is mostly single threaded, so the node's cores are
	# otherwise idle; mips_core always runs alone, because it is not.
	local rc=0
	if [ "$JOBS" -gt 1 ] && [ ${#want[@]} -gt 1 ]; then
		say "running $JOBS at a time; per-module logs in $BUILD/<module>.log"
	fi
	for m in "${want[@]}"; do
		if [ "$m" = mips_core ]; then
			wait
			harden mips_core || { warn "mips_core did not finish"; rc=1; }
			[ "$DRY" = 1 ] || collect mips_core
		elif [ "$JOBS" -gt 1 ] && [ ${#want[@]} -gt 1 ] && [ "$DRY" = 0 ]; then
			while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n || true; done
			( harden "$m" && collect "$m" ) > "$BUILD/$m.log" 2>&1 &
		else
			harden "$m" || { warn "$m did not finish"; rc=1; }
			[ "$DRY" = 1 ] || collect "$m"
		fi
	done
	wait

	[ "$DRY" = 1 ] || summary
	return $rc
}

main "$@"
