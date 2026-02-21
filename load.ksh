# load.ksh — Top-level package loader for pack.ksh
#
# This file MUST be sourced at the top level of .kshrc (not inside a
# function) so that typeset calls in plugin init scripts create true
# global variables. ksh93 scopes typeset to the enclosing function; at
# global scope it creates global declarations, which is what plugins expect.

# Resolve if PACK_ORDER wasn't pre-populated (e.g., sourced directly by old .kshrc snippets)
if (( ${#PACK_ORDER[@]} == 0 )); then
	_pack_resolve || return 1
fi

# ── Load Packages ───────────────────────────────────────────────────────────
typeset _pack_l_name _pack_l_path _pack_l_source
typeset _pack_l_branch _pack_l_tag _pack_l_commit
typeset _pack_l_load _pack_l_disabled _pack_l_local _pack_l_entry _pack_l_sf
typeset -i _pack_l_fail=0

# ── Pass 1: Defer clones for missing packages (concurrent) ─────────────────
# All clones start in parallel via defer -k. Network I/O overlaps; the OS
# handles scheduling. No results are consumed here — that's pass 2's job.
for _pack_l_name in "${PACK_ORDER[@]}"; do
	[[ -n "${PACK_LOADED[$_pack_l_name]+set}" ]] && continue

	_pack_l_disabled="${PACK_REGISTRY[$_pack_l_name].disabled}"
	[[ "$_pack_l_disabled" == true ]] && continue

	_pack_l_path="${PACK_REGISTRY[$_pack_l_name].path}"
	_pack_l_source="${PACK_REGISTRY[$_pack_l_name].source}"
	_pack_l_load="${PACK_REGISTRY[$_pack_l_name].load}"

	[[ "$_pack_l_load" == manual ]] && continue

	if [[ ! -d "$_pack_l_path" ]] && _pack_git_is_url "$_pack_l_source"; then
		_pack_l_branch="${PACK_REGISTRY[$_pack_l_name].branch}"
		_pack_l_tag="${PACK_REGISTRY[$_pack_l_name].tag}"
		_pack_l_commit="${PACK_REGISTRY[$_pack_l_name].commit}"
		_pack_fire pre-install "$_pack_l_name"
		_pack_defer_clone "$_pack_l_name" "$_pack_l_source" "$_pack_l_path" \
			"$_pack_l_branch" "$_pack_l_tag" "$_pack_l_commit"
	fi
done

# ── Pass 2: Await clones + apply config in dependency order ────────────────
# Results consumed in PACK_ORDER so package A is fully loaded before
# dependent B is configured. await on an already-finished clone is O(1).
for _pack_l_name in "${PACK_ORDER[@]}"; do
	[[ -n "${PACK_LOADED[$_pack_l_name]+set}" ]] && continue

	_pack_l_disabled="${PACK_REGISTRY[$_pack_l_name].disabled}"
	[[ "$_pack_l_disabled" == true ]] && continue

	_pack_l_path="${PACK_REGISTRY[$_pack_l_name].path}"
	_pack_l_load="${PACK_REGISTRY[$_pack_l_name].load}"
	_pack_l_local="${PACK_REGISTRY[$_pack_l_name].local}"

	[[ "$_pack_l_load" == manual ]] && continue

	# Await deferred clone or handle missing package
	if [[ -n "${_PACK_CLONE_FUTURES[$_pack_l_name]:-}" ]]; then
		Result_t _pack_l_cr
		_pack_await_clone _pack_l_cr "$_pack_l_name"
		if _pack_l_cr.is_err; then
			print -u2 "pack: ${_pack_l_name}: ${_pack_l_cr.error}"
			(( _pack_l_fail++ ))
			continue
		fi
		_pack_fire post-install "$_pack_l_name"
	elif [[ ! -d "$_pack_l_path" && "$_pack_l_local" != true ]]; then
		print -u2 "pack: $_pack_l_name: package directory missing: $_pack_l_path"
		(( _pack_l_fail++ ))
		continue
	fi

	# ── Apply declarative fields ────────────────────────────────────
	pack_apply_env   "$_pack_l_name"
	pack_apply_path  "$_pack_l_name" "$_pack_l_path"
	pack_apply_alias "$_pack_l_name"
	pack_apply_fpath "$_pack_l_name" "$_pack_l_path"

	# ── Source entry point (load=now only) ──────────────────────────
	_pack_fire pre-load "$_pack_l_name"
	if [[ "$_pack_l_load" == now ]]; then
		_pack_l_entry=""
		_pack_l_sf="${PACK_REGISTRY[$_pack_l_name].source_file}"
		if [[ -n "$_pack_l_sf" ]]; then
			if [[ "$_pack_l_sf" == /* ]]; then
				_pack_l_entry="$_pack_l_sf"
			else
				_pack_l_entry="$_pack_l_path/$_pack_l_sf"
			fi
		elif [[ -f "$_pack_l_path/init.ksh" ]]; then
			_pack_l_entry="$_pack_l_path/init.ksh"
		elif [[ -f "$_pack_l_path/plugin.ksh" ]]; then
			_pack_l_entry="$_pack_l_path/plugin.ksh"
		elif [[ -f "$_pack_l_path/${_pack_l_name}.ksh" ]]; then
			_pack_l_entry="$_pack_l_path/${_pack_l_name}.ksh"
		fi

		if [[ -n "$_pack_l_entry" ]]; then
			. "$_pack_l_entry" || {
				print -u2 "pack: $_pack_l_name: failed to source $_pack_l_entry"
				(( _pack_l_fail++ ))
				continue
			}
		fi
	fi

	# ── Eval rc snippet ─────────────────────────────────────────────
	pack_apply_rc "$_pack_l_name" "$_pack_l_path"
	_pack_fire post-load "$_pack_l_name"

	PACK_LOADED[$_pack_l_name]=1
done

(( _pack_l_fail > 0 )) && print -u2 "pack: ${_pack_l_fail} package(s) failed to load (run 'pack list' to see status)"

# ── Cleanup ─────────────────────────────────────────────────────────────────
# Remove loop variables from the global namespace
unset _pack_l_name _pack_l_path _pack_l_source
unset _pack_l_branch _pack_l_tag _pack_l_commit
unset _pack_l_load _pack_l_disabled _pack_l_local _pack_l_entry _pack_l_sf _pack_l_fail
unset _pack_l_cr
