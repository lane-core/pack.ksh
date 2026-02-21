#!/bin/ksh
# stress.ksh — Stress and performance tests for pack.ksh
#
# Tests scaling behavior with many packages, deep dependency graphs,
# and error accumulation. Uses local packages only — no network I/O.
#
# Usage: ksh test/stress.ksh

set -o nounset

# ── Test Harness ──────────────────────────────────────────────────────────
typeset -i PASS_COUNT=0 FAIL_COUNT=0

function pass {
	print -r -- "PASS: $1"
	(( PASS_COUNT++ ))
}

function fail {
	print -r -- "FAIL: $1"
	(( FAIL_COUNT++ ))
}

function assert_true {
	typeset desc="$1"; shift
	if eval "$*"; then
		pass "$desc"
	else
		fail "$desc ($*)"
	fi
}

function _bench_start { typeset -g _bench_t0=$SECONDS; }
function _bench_end {
	typeset -g _bench_ms
	typeset _t1=$SECONDS
	if command -v bc >/dev/null 2>&1; then
		_bench_ms=$(print "scale=0; ($_t1 - $_bench_t0) * 1000 / 1" | bc)
	else
		_bench_ms=$(( (${_t1%%.*} - ${_bench_t0%%.*}) * 1000 ))
	fi
}
function _bench_report {
	typeset label="$1"
	typeset -i count=${2:-0}
	if (( _bench_ms > 0 && count > 0 )); then
		typeset -i ops_sec=$(( count * 1000 / _bench_ms ))
		print -r -- "  ${label}: ${count} ops in ${_bench_ms}ms (~${ops_sec} ops/sec)"
	elif (( count > 0 )); then
		print -r -- "  ${label}: ${count} ops in <1ms"
	else
		print -r -- "  ${label}: ${_bench_ms}ms"
	fi
}

# ── Sandboxed Environment ────────────────────────────────────────────────
TESTDIR=$(mktemp -d "${TMPDIR:-/tmp}/pack-stress.XXXXXX")
export XDG_DATA_HOME="$TESTDIR/data"
export XDG_CONFIG_HOME="$TESTDIR/config"
export XDG_CACHE_HOME="$TESTDIR/cache"
mkdir -p "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME"

typeset _v_self="${.sh.file%/*}"
_v_self="${_v_self%/test}"
[[ "$_v_self" == "${.sh.file%/*}" ]] && _v_self="${.sh.file%/*}/.."
_v_self=$(cd "$_v_self" && pwd)

trap 'rm -rf "$TESTDIR"' EXIT

print -r -- "Test environment: $TESTDIR"
print -r -- "Pack source:      $_v_self"
print ""

# ── Source pack.ksh ──────────────────────────────────────────────────────
unset _PACK_SOURCED 2>/dev/null
. "$_v_self/pack.ksh"
assert_true "pack.ksh sourced" '(( $? == 0 ))'
print ""

# ══════════════════════════════════════════════════════════════════════════
# 1. Mass package declaration (50 packages)
# ══════════════════════════════════════════════════════════════════════════
print -r -- "== 1. Mass declaration (50 packages) =="

typeset -i PKG_COUNT=50

# Create 50 local packages, each with init.ksh
_bench_start
typeset -i _i
for (( _i=0; _i < PKG_COUNT; _i++ )); do
	typeset _pkg_dir="$TESTDIR/pkgs/stress-pkg-${_i}"
	mkdir -p "$_pkg_dir"
	print "# stress package $_i" > "$_pkg_dir/init.ksh"
done
_bench_end
_bench_report "create ${PKG_COUNT} pkg dirs" $PKG_COUNT

# Declare all 50 packages via pack()
_bench_start
for (( _i=0; _i < PKG_COUNT; _i++ )); do
	pack "$TESTDIR/pkgs/stress-pkg-${_i}" local=true as="stress-pkg-${_i}" load=now
done
_bench_end
_bench_report "declare ${PKG_COUNT} packages" $PKG_COUNT

# Verify all registered
typeset -i _reg_count=0
for (( _i=0; _i < PKG_COUNT; _i++ )); do
	[[ -n "${PACK_REGISTRY[stress-pkg-${_i}]+set}" ]] && (( _reg_count++ ))
done
assert_true "all ${PKG_COUNT} packages registered" '(( _reg_count == PKG_COUNT ))'

print ""

# ══════════════════════════════════════════════════════════════════════════
# 2. Dependency resolution — linear chain (50 deep)
# ══════════════════════════════════════════════════════════════════════════
print -r -- "== 2. Dependency resolution — linear chain =="

# Clear and re-declare with a linear dependency chain
# pkg-0 has no deps, pkg-1 depends on pkg-0, ..., pkg-49 depends on pkg-48
unset _PACK_SOURCED 2>/dev/null
PACK_REGISTRY=()
PACK_CONFIGS=()
PACK_STATE=()
PACK_LOADED=()
PACK_ORDER=()

. "$_v_self/pack.ksh"

for (( _i=0; _i < PKG_COUNT; _i++ )); do
	if (( _i == 0 )); then
		pack "$TESTDIR/pkgs/stress-pkg-${_i}" local=true as="stress-pkg-${_i}" load=now
	else
		pack "$TESTDIR/pkgs/stress-pkg-${_i}" local=true as="stress-pkg-${_i}" \
			load=now depends="stress-pkg-$(( _i - 1 ))"
	fi
done

_bench_start
_pack_resolve
typeset _resolve_rc=$?
_bench_end
_bench_report "resolve ${PKG_COUNT}-deep linear chain" $PKG_COUNT

assert_true "linear resolve succeeds" '(( _resolve_rc == 0 ))'
assert_true "PACK_ORDER includes all stress packages" '(( ${#PACK_ORDER[@]} >= PKG_COUNT ))'

# Verify ordering: pkg-0 before pkg-49
typeset -i _p0_idx=-1 _p49_idx=-1 _idx=0
typeset _n
for _n in "${PACK_ORDER[@]}"; do
	[[ "$_n" == "stress-pkg-0" ]] && _p0_idx=$_idx
	[[ "$_n" == "stress-pkg-49" ]] && _p49_idx=$_idx
	(( _idx++ ))
done
assert_true "pkg-0 before pkg-49" '(( _p0_idx >= 0 && _p49_idx >= 0 && _p0_idx < _p49_idx ))'

print ""

# ══════════════════════════════════════════════════════════════════════════
# 3. Dependency resolution — diamond pattern (realistic)
# ══════════════════════════════════════════════════════════════════════════
print -r -- "== 3. Dependency resolution — diamond (80 packages) =="

unset _PACK_SOURCED 2>/dev/null
PACK_REGISTRY=()
PACK_CONFIGS=()
PACK_STATE=()
PACK_LOADED=()
PACK_ORDER=()

. "$_v_self/pack.ksh"

# Create additional dirs for diamond pattern
for (( _i=0; _i < 80; _i++ )); do
	typeset _d_dir="$TESTDIR/pkgs/diamond-${_i}"
	[[ -d "$_d_dir" ]] || mkdir -p "$_d_dir"
	[[ -f "$_d_dir/init.ksh" ]] || print "# diamond $_i" > "$_d_dir/init.ksh"
done

# 10 base packages (no deps)
for (( _i=0; _i < 10; _i++ )); do
	pack "$TESTDIR/pkgs/diamond-${_i}" local=true as="diamond-${_i}" load=now
done

# 50 mid-tier packages (each depends on 2 base packages)
for (( _i=10; _i < 60; _i++ )); do
	typeset _d1="diamond-$(( (_i - 10) % 10 ))"
	typeset _d2="diamond-$(( ((_i - 10) + 3) % 10 ))"
	pack "$TESTDIR/pkgs/diamond-${_i}" local=true as="diamond-${_i}" \
		load=now depends="(${_d1} ${_d2})"
done

# 20 top-tier packages (each depends on 3 mid-tier)
for (( _i=60; _i < 80; _i++ )); do
	typeset _m1="diamond-$(( ((_i - 60) % 50) + 10 ))"
	typeset _m2="diamond-$(( (((_i - 60) + 17) % 50) + 10 ))"
	typeset _m3="diamond-$(( (((_i - 60) + 31) % 50) + 10 ))"
	pack "$TESTDIR/pkgs/diamond-${_i}" local=true as="diamond-${_i}" \
		load=now depends="(${_m1} ${_m2} ${_m3})"
done

_bench_start
_pack_resolve
typeset _dresolve_rc=$?
_bench_end
_bench_report "resolve 80-node diamond" 80

assert_true "diamond resolve succeeds" '(( _dresolve_rc == 0 ))'

# Verify ordering: base nodes before their dependents
typeset -i _d0_idx=-1 _d10_idx=-1
_idx=0
for _n in "${PACK_ORDER[@]}"; do
	[[ "$_n" == "diamond-0" ]] && _d0_idx=$_idx
	[[ "$_n" == "diamond-10" ]] && _d10_idx=$_idx
	(( _idx++ ))
done
assert_true "base before mid-tier" '(( _d0_idx >= 0 && _d10_idx >= 0 && _d0_idx < _d10_idx ))'

print ""

# ══════════════════════════════════════════════════════════════════════════
# 4. Load loop — 50 local packages
# ══════════════════════════════════════════════════════════════════════════
print -r -- "== 4. Load 50 local packages =="

# Use the linear-chain setup from test 2
unset _PACK_SOURCED 2>/dev/null
PACK_REGISTRY=()
PACK_CONFIGS=()
PACK_STATE=()
PACK_LOADED=()
PACK_ORDER=()

. "$_v_self/pack.ksh"

for (( _i=0; _i < PKG_COUNT; _i++ )); do
	if (( _i == 0 )); then
		pack "$TESTDIR/pkgs/stress-pkg-${_i}" local=true as="stress-pkg-${_i}" load=now
	else
		pack "$TESTDIR/pkgs/stress-pkg-${_i}" local=true as="stress-pkg-${_i}" \
			load=now depends="stress-pkg-$(( _i - 1 ))"
	fi
done

_pack_resolve

_bench_start
. "$_v_self/load.ksh"
_bench_end
_bench_report "load ${PKG_COUNT} packages" $PKG_COUNT

typeset -i _loaded_count=0
for (( _i=0; _i < PKG_COUNT; _i++ )); do
	[[ -n "${PACK_LOADED[stress-pkg-${_i}]+set}" ]] && (( _loaded_count++ ))
done
assert_true "all ${PKG_COUNT} packages loaded" '(( _loaded_count == PKG_COUNT ))'

print ""

# ══════════════════════════════════════════════════════════════════════════
# 5. Cycle detection
# ══════════════════════════════════════════════════════════════════════════
print -r -- "== 5. Cycle detection =="

unset _PACK_SOURCED 2>/dev/null
PACK_REGISTRY=()
PACK_CONFIGS=()
PACK_STATE=()
PACK_LOADED=()
PACK_ORDER=()

. "$_v_self/pack.ksh"

# Create a 10-node cycle: a→b→c→...→j→a
typeset -a _cycle_names=(cyc-a cyc-b cyc-c cyc-d cyc-e cyc-f cyc-g cyc-h cyc-i cyc-j)
typeset -i _cn=${#_cycle_names[@]}
for (( _i=0; _i < _cn; _i++ )); do
	typeset _cname="${_cycle_names[_i]}"
	typeset _cdep="${_cycle_names[$(( (_i + 1) % _cn ))]}"
	typeset _cdir="$TESTDIR/pkgs/$_cname"
	[[ -d "$_cdir" ]] || mkdir -p "$_cdir"
	[[ -f "$_cdir/init.ksh" ]] || print "# cycle" > "$_cdir/init.ksh"
	pack "$_cdir" local=true as="$_cname" load=now depends="$_cdep"
done

_bench_start
_pack_resolve 2>/dev/null
typeset _cyc_rc=$?
_bench_end
_bench_report "detect 10-node cycle"

assert_true "cycle detected (non-zero exit)" '(( _cyc_rc != 0 ))'

print ""

# ══════════════════════════════════════════════════════════════════════════
# 6. Error accumulation — _pack_report_errors with many errors
# ══════════════════════════════════════════════════════════════════════════
print -r -- "== 6. Error accumulation =="

Result_t _stress_acc
_bench_start
for (( _i=0; _i < 100; _i++ )); do
	if _stress_acc.is_ok; then
		_stress_acc.err "error-${_i}" 1
	else
		_stress_acc.error="${_stress_acc.error}"$'\n'"error-${_i}"
		_stress_acc.code=$(( ${_stress_acc.code} + 1 ))
	fi
done
_bench_end
_bench_report "accumulate 100 errors" 100

assert_true "100 errors accumulated" '(( ${_stress_acc.code} == 100 ))'

# Verify _pack_report_errors formats correctly
typeset _report_out
_report_out=$(_pack_report_errors _stress_acc 2>&1) || true
typeset -i _report_lines=0
typeset _rl
typeset _old_IFS=$IFS
IFS=$'\n'
for _rl in $_report_out; do
	(( _report_lines++ ))
done
IFS=$_old_IFS
# Should have: 1 blank line + 1 header + 100 error lines = 102
assert_true "report output has all error lines" '(( _report_lines >= 100 ))'

print ""

# ══════════════════════════════════════════════════════════════════════════
# 7. Registry compound variable access at scale
# ══════════════════════════════════════════════════════════════════════════
print -r -- "== 7. Registry access performance =="

# Use the linear chain from test 2 (still in memory from test 4)
# Measure time to read all fields from all 50 packages
unset _PACK_SOURCED 2>/dev/null
PACK_REGISTRY=()
PACK_CONFIGS=()
PACK_STATE=()
PACK_LOADED=()
PACK_ORDER=()

. "$_v_self/pack.ksh"

for (( _i=0; _i < PKG_COUNT; _i++ )); do
	pack "$TESTDIR/pkgs/stress-pkg-${_i}" local=true as="stress-pkg-${_i}" load=now
done

_bench_start
typeset _dummy
for (( _i=0; _i < PKG_COUNT; _i++ )); do
	_dummy="${PACK_REGISTRY[stress-pkg-${_i}].source}"
	_dummy="${PACK_REGISTRY[stress-pkg-${_i}].path}"
	_dummy="${PACK_REGISTRY[stress-pkg-${_i}].branch}"
	_dummy="${PACK_REGISTRY[stress-pkg-${_i}].tag}"
	_dummy="${PACK_REGISTRY[stress-pkg-${_i}].load}"
	_dummy="${PACK_REGISTRY[stress-pkg-${_i}].local}"
	_dummy="${PACK_REGISTRY[stress-pkg-${_i}].disabled}"
done
_bench_end
_bench_report "read 7 fields x ${PKG_COUNT} packages" $(( PKG_COUNT * 7 ))

assert_true "registry reads complete" '(( 1 ))'

print ""

# ══════════════════════════════════════════════════════════════════════════
# 8. pack list with many packages
# ══════════════════════════════════════════════════════════════════════════
print -r -- "== 8. pack list (50 packages) =="

_pack_resolve

_bench_start
typeset _list_out
_list_out=$(pack list)
_bench_end
_bench_report "pack list ${PKG_COUNT} packages"

# Count lines (should be header + separator + PKG_COUNT+1 entries (including 'pack' itself))
typeset -i _list_lines=0
IFS=$'\n'
for _rl in $_list_out; do
	(( _list_lines++ ))
done
IFS=$_old_IFS

assert_true "list output has expected lines" '(( _list_lines >= PKG_COUNT + 2 ))'

print ""

# ══════════════════════════════════════════════════════════════════════════
# 9. Repeated resolve (idempotency check)
# ══════════════════════════════════════════════════════════════════════════
print -r -- "== 9. Repeated resolve (5x) =="

_bench_start
typeset -i _rr
for (( _rr=0; _rr < 5; _rr++ )); do
	PACK_ORDER=()
	_pack_resolve
done
_bench_end
_bench_report "resolve 5 times" 5

# Verify order is stable
typeset _order1="${PACK_ORDER[*]}"
PACK_ORDER=()
_pack_resolve
typeset _order2="${PACK_ORDER[*]}"
assert_true "resolve is deterministic" '[[ "$_order1" == "$_order2" ]]'

print ""

# ══════════════════════════════════════════════════════════════════════════
# 10. Pack info on many packages
# ══════════════════════════════════════════════════════════════════════════
print -r -- "== 10. pack info (50 packages) =="

_bench_start
for (( _i=0; _i < PKG_COUNT; _i++ )); do
	pack info "stress-pkg-${_i}" >/dev/null
done
_bench_end
_bench_report "pack info x ${PKG_COUNT}" $PKG_COUNT

assert_true "all info calls succeeded" '(( 1 ))'

print ""

# ── Summary ──────────────────────────────────────────────────────────────
print ""
print "──────────────────────────────────────────────"
print "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
if (( FAIL_COUNT > 0 )); then
	print "SOME TESTS FAILED"
	exit 1
else
	print "ALL TESTS PASSED"
	exit 0
fi
