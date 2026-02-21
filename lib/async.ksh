# pack.ksh — Async clone operations via func.ksh defer/await
# Sourced by pack.ksh at startup; not intended for standalone execution.
#
# Wraps _pack_git_clone in defer/await to parallelize I/O-bound clones
# during startup (load.ksh) and lockfile restore (pack_restore). Clones
# run concurrently; results are consumed in PACK_ORDER for correct
# dependency sequencing.

# ── Clone Futures ─────────────────────────────────────────────────────
# Maps package name -> "pid channel" so Future_t can be reconstructed at
# await time without keeping the original compound in scope.
typeset -A _PACK_CLONE_FUTURES

# ── Clone Task ────────────────────────────────────────────────────────
# func.ksh deferred callback wrapping _pack_git_clone.
# Runs in a subshell spawned by defer — Result_t serializes through the
# channel file, so nameref constraints don't apply across the fork.
function _pack_clone_task {
	typeset -n _pct_r=$1; shift
	typeset _pct_source="$1" _pct_dest="$2"
	typeset _pct_branch="${3:-}" _pct_tag="${4:-}" _pct_commit="${5:-}"

	# 1-level nameref: local Result_t for _pack_git_clone, transfer to caller
	Result_t _pct_tmp
	_pack_git_clone _pct_tmp "$_pct_source" "$_pct_dest" \
		"$_pct_branch" "$_pct_tag" "$_pct_commit"

	if _pct_tmp.is_ok; then
		_pct_r.ok "${_pct_tmp.value}"
	else
		_pct_r.err "${_pct_tmp.error}" ${_pct_tmp.code}
	fi
}

# ── Defer Clone ───────────────────────────────────────────────────────
# Start a package clone as a keyed future. Channel path is deterministic
# ($_FUNC_KSH_ASYNC_DIR/pack_${name}), so stale data from crashed runs
# is evicted automatically by defer -k.
# Usage: _pack_defer_clone name source dest [branch] [tag] [commit]
function _pack_defer_clone {
	typeset _pdc_name="$1"; shift

	Future_t _pdc_fut
	defer -k "pack_${_pdc_name}" _pdc_fut _pack_clone_task "$@" || {
		print -u2 "pack: ${_pdc_name}: failed to start async clone"
		return 1
	}

	# Only track if defer actually started the background process
	if _pdc_fut.is_pending; then
		_PACK_CLONE_FUTURES[$_pdc_name]="${_pdc_fut.pid} ${_pdc_fut.channel}"
	fi
}

# ── Await Clone ───────────────────────────────────────────────────────
# Block until a deferred clone completes, yield Result_t to caller.
# Consumes the future (linear) and removes the tracking entry.
# Usage: _pack_await_clone result_varname name
function _pack_await_clone {
	typeset -n _pac_r=$1
	typeset _pac_name="$2"

	typeset _pac_stored="${_PACK_CLONE_FUTURES[$_pac_name]}"
	if [[ -z "$_pac_stored" ]]; then
		_pac_r.err "no deferred clone for ${_pac_name}" 1
		return 0
	fi

	# Reconstruct Future_t from stored pid/channel
	Future_t _pac_fut
	_pac_fut.pid=${_pac_stored%% *}
	_pac_fut.channel=${_pac_stored#* }
	_pac_fut.key="pack_${_pac_name}"
	_pac_fut.status=pending

	# 1-level nameref: local Result_t for await, transfer to caller
	Result_t _pac_tmp
	await _pac_tmp _pac_fut

	if _pac_tmp.is_ok; then
		_pac_r.ok "${_pac_tmp.value}"
	else
		_pac_r.err "${_pac_tmp.error}" ${_pac_tmp.code}
	fi

	unset "_PACK_CLONE_FUTURES[$_pac_name]"
}
