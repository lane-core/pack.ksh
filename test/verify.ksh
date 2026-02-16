#!/bin/ksh
# verify.ksh — End-to-end verification of pack.ksh package manager
#
# Exercises the 10 verification steps from the project plan against
# real git repos and a synthetic local package. Uses a TMPDIR-based
# test environment so nothing touches the user's real XDG directories.
#
# Usage: ksh test/verify.ksh

set -o nounset

# ── Test Harness ────────────────────────────────────────────────────────────
typeset -i PASS_COUNT=0 FAIL_COUNT=0

function pass {
	print "PASS: $1"
	(( PASS_COUNT++ ))
}

function fail {
	print "FAIL: $1"
	(( FAIL_COUNT++ ))
}

# assert_true DESC CONDITION — eval-based check for [[ ]] and (( )) expressions
function assert_true {
	typeset desc="$1"; shift
	if eval "$*"; then
		pass "$desc"
	else
		fail "$desc"
	fi
}

function summary {
	print ""
	print "──────────────────────────────────────────────"
	print "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
	if (( FAIL_COUNT > 0 )); then
		print "SOME TESTS FAILED"
		return 1
	else
		print "ALL TESTS PASSED"
		return 0
	fi
}

# ── Sandboxed Environment ──────────────────────────────────────────────────
# Redirect all XDG paths into a temp directory so we never touch real config.
TESTDIR=$(mktemp -d "${TMPDIR:-/tmp}/pack-verify.XXXXXX")
export XDG_DATA_HOME="$TESTDIR/data"
export XDG_CONFIG_HOME="$TESTDIR/config"
export XDG_CACHE_HOME="$TESTDIR/cache"
mkdir -p "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME"

# Resolve PACK_SELF to the project root (one level up from test/)
typeset _v_self="${.sh.file%/*}"
_v_self="${_v_self%/test}"
# Handle case where script is run from the project root
[[ "$_v_self" == "${.sh.file%/*}" ]] && _v_self="${.sh.file%/*}/.."
# Normalize to an absolute path
_v_self=$(cd "$_v_self" && pwd)

# Clean up on exit regardless of how we terminate
trap 'rm -rf "$TESTDIR"' EXIT

print "Test environment: $TESTDIR"
print "Pack source:      $_v_self"
print ""

# ── Step 1: Source pack.ksh from test environment ──────────────────────────
print "── Step 1: Source pack.ksh ──────────────────────────"

unset _PACK_SOURCED 2>/dev/null
. "$_v_self/pack.ksh"
typeset _v_src_rc=$?

assert_true "pack.ksh sourced without error" '(( _v_src_rc == 0 ))'
assert_true "PACK_ROOT points into test dir" '[[ "$PACK_ROOT" == "$TESTDIR"/* ]]'
assert_true "PACK_PACKAGES directory exists" '[[ -d "$PACK_PACKAGES" ]]'
assert_true "pack() function is defined" 'typeset -f pack >/dev/null 2>&1'
assert_true "_pack_resolve() function is defined" 'typeset -f _pack_resolve >/dev/null 2>&1'
assert_true "pack_freeze() function is defined" 'typeset -f pack_freeze >/dev/null 2>&1'

print ""

# ── Step 2: Declare test packages ──────────────────────────────────────────
print "── Step 2: Declare test packages ────────────────────"

# Create a local package with an init.ksh and functions/ dir
LOCAL_PKG_DIR="$TESTDIR/my-local-plugin"
mkdir -p "$LOCAL_PKG_DIR/functions"
print 'typeset -x MY_LOCAL_PLUGIN_LOADED=1' > "$LOCAL_PKG_DIR/init.ksh"
print 'function my_local_func { print "hello from local"; }' > "$LOCAL_PKG_DIR/functions/my_local_func"

# 2a: GitHub shorthand — tiny real repo
# readlinkf has no lib/ dir, so no fpath here — just a basic git package
pack "ko1nksm/readlinkf"

# 2b: Full URL with as= and tag=
pack "https://github.com/ko1nksm/getoptions.git" as=getoptions tag=v3.3.0

# 2c: Local package depending on readlinkf
pack "$LOCAL_PKG_DIR" local=true as=my-local-plugin \
	load=now fpath=functions depends=readlinkf

assert_true "readlinkf registered in PACK_REGISTRY" '[[ -n "${PACK_REGISTRY[readlinkf]+set}" ]]'
assert_true "getoptions registered in PACK_REGISTRY" '[[ -n "${PACK_REGISTRY[getoptions]+set}" ]]'
assert_true "my-local-plugin registered in PACK_REGISTRY" '[[ -n "${PACK_REGISTRY[my-local-plugin]+set}" ]]'

# Verify URL resolution: shorthand -> github URL
typeset _v_rlf_meta="${PACK_REGISTRY[readlinkf]}"
typeset _v_rlf_source="${_v_rlf_meta#*source=}"; _v_rlf_source="${_v_rlf_source%%;*}"
assert_true "readlinkf source expanded to github URL" '[[ "$_v_rlf_source" == "https://github.com/ko1nksm/readlinkf.git" ]]'

# Verify as= rename worked
typeset _v_geo_meta="${PACK_REGISTRY[getoptions]}"
typeset _v_geo_source="${_v_geo_meta#*source=}"; _v_geo_source="${_v_geo_source%%;*}"
assert_true "getoptions source is full URL" '[[ "$_v_geo_source" == "https://github.com/ko1nksm/getoptions.git" ]]'

# Verify local package metadata
typeset _v_lp_meta="${PACK_REGISTRY[my-local-plugin]}"
typeset _v_lp_local="${_v_lp_meta#*local=}"; _v_lp_local="${_v_lp_local%%;*}"
assert_true "my-local-plugin marked as local" '[[ "$_v_lp_local" == true ]]'

# Verify depends= stored in config
typeset _v_lp_config="${PACK_CONFIGS[my-local-plugin]:-}"
assert_true "my-local-plugin has depends in config" '[[ "$_v_lp_config" == *"depends=(readlinkf)"* ]]'

print ""

# ── Step 3: Verify dependency resolution ───────────────────────────────────
print "── Step 3: Dependency resolution ────────────────────"

_pack_resolve
typeset _v_resolve_rc=$?

assert_true "_pack_resolve succeeds" '(( _v_resolve_rc == 0 ))'
assert_true "PACK_ORDER is non-empty" '(( ${#PACK_ORDER[@]} > 0 ))'

# readlinkf must appear before my-local-plugin (dependency ordering)
typeset -i _v_rlf_idx=-1 _v_lp_idx=-1 _v_idx=0
typeset _v_name
for _v_name in "${PACK_ORDER[@]}"; do
	[[ "$_v_name" == readlinkf ]] && _v_rlf_idx=$_v_idx
	[[ "$_v_name" == my-local-plugin ]] && _v_lp_idx=$_v_idx
	(( _v_idx++ ))
done

assert_true "readlinkf is in PACK_ORDER" '(( _v_rlf_idx >= 0 ))'
assert_true "my-local-plugin is in PACK_ORDER" '(( _v_lp_idx >= 0 ))'
assert_true "readlinkf ordered before my-local-plugin" '(( _v_rlf_idx < _v_lp_idx ))'

print ""

# ── Step 4: pack install clones git packages ──────────────────────────────
print "── Step 4: pack install ─────────────────────────────"

pack install
typeset _v_install_rc=$?

assert_true "pack install completes" '(( _v_install_rc == 0 ))'
assert_true "readlinkf directory exists" '[[ -d "$PACK_PACKAGES/readlinkf" ]]'
assert_true "readlinkf has .git directory" '[[ -d "$PACK_PACKAGES/readlinkf/.git" ]]'
assert_true "getoptions directory exists" '[[ -d "$PACK_PACKAGES/getoptions" ]]'
assert_true "getoptions has .git directory" '[[ -d "$PACK_PACKAGES/getoptions/.git" ]]'

# Verify getoptions was cloned at the correct tag
typeset _v_geo_tag
_v_geo_tag=$(command git -C "$PACK_PACKAGES/getoptions" describe --tags --exact-match 2>/dev/null)
assert_true "getoptions cloned at tag v3.3.0" '[[ "$_v_geo_tag" == "v3.3.0" ]]'

print ""

# ── Step 5: Verify load applies FPATH/PATH correctly ─────────────────────
print "── Step 5: Load packages (FPATH/PATH extension) ─────"

# Save pre-load FPATH for comparison
typeset _v_old_fpath="${FPATH:-}"

# Reset data structures that load.ksh populates
PACK_LOADED=()
PACK_ORDER=()

# Source load.ksh at top level (as required — not inside a function)
. "$_v_self/load.ksh"
typeset _v_load_rc=$?

assert_true "load.ksh sourced without error" '(( _v_load_rc == 0 ))'
assert_true "readlinkf marked as loaded" '[[ -n "${PACK_LOADED[readlinkf]+set}" ]]'
assert_true "getoptions marked as loaded" '[[ -n "${PACK_LOADED[getoptions]+set}" ]]'
assert_true "my-local-plugin marked as loaded" '[[ -n "${PACK_LOADED[my-local-plugin]+set}" ]]'

# readlinkf has no fpath= declaration, so verify it was still marked loaded
assert_true "readlinkf loaded despite no fpath" '[[ -n "${PACK_LOADED[readlinkf]+set}" ]]'

# my-local-plugin should have sourced init.ksh (load=now)
assert_true "my-local-plugin init.ksh was sourced" '[[ "${MY_LOCAL_PLUGIN_LOADED:-}" == 1 ]]'

# my-local-plugin's functions/ dir should be in FPATH
assert_true "FPATH extended with my-local-plugin functions" '[[ "$FPATH" == *"my-local-plugin/functions"* ]]'

print ""

# ── Step 6: pack freeze generates lockfile ───────────────────────────────
print "── Step 6: pack freeze ──────────────────────────────"

pack freeze
typeset _v_freeze_rc=$?

typeset _v_lockfile="$PACK_STATE_DIR/pack.lock"

assert_true "pack freeze succeeds" '(( _v_freeze_rc == 0 ))'
assert_true "pack.lock file exists" '[[ -f "$_v_lockfile" ]]'

# Lockfile should contain entries for both git packages (not local)
typeset -i _v_rlf_in_lock=0 _v_geo_in_lock=0 _v_local_in_lock=0
typeset _v_line
while IFS= read -r _v_line; do
	[[ "$_v_line" == '#'* || -z "$_v_line" ]] && continue
	case "$_v_line" in
		readlinkf\|*) _v_rlf_in_lock=1 ;;
		getoptions\|*) _v_geo_in_lock=1 ;;
		my-local-plugin\|*) _v_local_in_lock=1 ;;
	esac
done < "$_v_lockfile"

assert_true "readlinkf in lockfile" '(( _v_rlf_in_lock == 1 ))'
assert_true "getoptions in lockfile" '(( _v_geo_in_lock == 1 ))'
assert_true "local package NOT in lockfile" '(( _v_local_in_lock == 0 ))'

# Verify lockfile format: name|source|commit|timestamp
# Each data line should have exactly 3 pipe separators
typeset -i _v_format_ok=1
while IFS= read -r _v_line; do
	[[ "$_v_line" == '#'* || -z "$_v_line" ]] && continue
	typeset _v_stripped="${_v_line//[^|]/}"
	if (( ${#_v_stripped} != 3 )); then
		_v_format_ok=0
		print "  Bad lockfile line: $_v_line"
	fi
done < "$_v_lockfile"
assert_true "lockfile entries have correct pipe-delimited format" '(( _v_format_ok == 1 ))'

# Verify getoptions commit hash is a full 40-char SHA
typeset _v_geo_lock_commit=""
typeset _v_lname _v_lsource _v_lcommit _v_lts
while IFS='|' read -r _v_lname _v_lsource _v_lcommit _v_lts; do
	[[ "$_v_lname" == getoptions ]] && _v_geo_lock_commit="$_v_lcommit"
done < "$_v_lockfile"
assert_true "getoptions lockfile commit is full SHA (40 chars)" '(( ${#_v_geo_lock_commit} == 40 ))'

print ""

# ── Step 7: Delete packages dir, pack restore reinstalls ─────────────────
print "── Step 7: pack restore ─────────────────────────────"

# Save the lockfile commit for readlinkf to verify restore gets the same one
typeset _v_rlf_lock_commit=""
while IFS='|' read -r _v_lname _v_lsource _v_lcommit _v_lts; do
	[[ "$_v_lname" == readlinkf ]] && _v_rlf_lock_commit="$_v_lcommit"
done < "$_v_lockfile"

# Nuke the packages directory
rm -rf "$PACK_PACKAGES"
mkdir -p "$PACK_PACKAGES"

typeset _v_remaining
_v_remaining=$(ls -A "$PACK_PACKAGES" 2>/dev/null)
assert_true "packages directory is now empty" '[[ -z "$_v_remaining" ]]'

pack restore
typeset _v_restore_rc=$?

assert_true "pack restore succeeds" '(( _v_restore_rc == 0 ))'
assert_true "readlinkf restored" '[[ -d "$PACK_PACKAGES/readlinkf/.git" ]]'
assert_true "getoptions restored" '[[ -d "$PACK_PACKAGES/getoptions/.git" ]]'

# Verify restored commit matches lockfile
_pack_git_full_head "$PACK_PACKAGES/readlinkf"
typeset _v_rlf_restored_commit="$REPLY"
assert_true "readlinkf restored at correct commit" '[[ "$_v_rlf_restored_commit" == "$_v_rlf_lock_commit" ]]'

_pack_git_full_head "$PACK_PACKAGES/getoptions"
typeset _v_geo_restored_commit="$REPLY"
assert_true "getoptions restored at correct commit" '[[ "$_v_geo_restored_commit" == "$_v_geo_lock_commit" ]]'

print ""

# ── Step 8: pack update pulls latest ──────────────────────────────────────
print "── Step 8: pack update ──────────────────────────────"

# Record current commit for readlinkf before update
_pack_git_head "$PACK_PACKAGES/readlinkf"
typeset _v_pre_update_head="$REPLY"

pack update readlinkf
typeset _v_update_rc=$?

assert_true "pack update readlinkf succeeds" '(( _v_update_rc == 0 ))'

# After update the directory should still be valid
assert_true "readlinkf still has .git after update" '[[ -d "$PACK_PACKAGES/readlinkf/.git" ]]'

# The commit might be the same if already at HEAD, which is fine
_pack_git_head "$PACK_PACKAGES/readlinkf"
typeset _v_post_update_head="$REPLY"
assert_true "readlinkf has a valid HEAD after update" '[[ -n "$_v_post_update_head" ]]'

print ""

# ── Step 9: pack remove cleanly removes a package ────────────────────────
print "── Step 9: pack remove ──────────────────────────────"

pack remove getoptions
typeset _v_remove_rc=$?

assert_true "pack remove getoptions succeeds" '(( _v_remove_rc == 0 ))'
assert_true "getoptions directory removed from disk" '[[ ! -d "$PACK_PACKAGES/getoptions" ]]'
assert_true "getoptions removed from PACK_REGISTRY" '[[ -z "${PACK_REGISTRY[getoptions]+set}" ]]'
assert_true "getoptions removed from PACK_LOADED" '[[ -z "${PACK_LOADED[getoptions]+set}" ]]'

# readlinkf should be untouched
assert_true "readlinkf still present after removing getoptions" '[[ -d "$PACK_PACKAGES/readlinkf" ]]'

print ""

# ── Step 10: pack list shows status ───────────────────────────────────────
print "── Step 10: pack list ───────────────────────────────"

typeset _v_list_output
_v_list_output=$(pack list)
typeset _v_list_rc=$?

assert_true "pack list succeeds" '(( _v_list_rc == 0 ))'
assert_true "pack list output is non-empty" '[[ -n "$_v_list_output" ]]'
assert_true "pack list shows readlinkf" '[[ "$_v_list_output" == *readlinkf* ]]'
assert_true "pack list shows my-local-plugin" '[[ "$_v_list_output" == *my-local-plugin* ]]'

# getoptions was removed — should NOT appear
assert_true "pack list does not show removed getoptions" '[[ "$_v_list_output" != *getoptions* ]]'

# readlinkf should show as "installed"
assert_true "readlinkf shows as installed" '[[ "$_v_list_output" == *installed* ]]'

# my-local-plugin should show as "local"
assert_true "my-local-plugin shows as local" '[[ "$_v_list_output" == *local* ]]'

print ""

# ── Summary ──────────────────────────────────────────────────────────────
summary
exit $?
