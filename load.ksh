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
typeset _pack_l_name _pack_l_meta _pack_l_path _pack_l_source
typeset _pack_l_branch _pack_l_tag _pack_l_commit
typeset _pack_l_load _pack_l_disabled _pack_l_local _pack_l_entry

for _pack_l_name in "${PACK_ORDER[@]}"; do
	# Skip already-loaded packages
	[[ -n "${PACK_LOADED[$_pack_l_name]+set}" ]] && continue

	_pack_l_meta=";${PACK_REGISTRY[$_pack_l_name]}"

	# Skip disabled (belt-and-suspenders; _pack_resolve already filters these)
	_pack_l_disabled="${_pack_l_meta#*";disabled="}"; _pack_l_disabled="${_pack_l_disabled%%;*}"
	[[ "$_pack_l_disabled" == true ]] && continue

	# Extract metadata fields (;-anchored to prevent substring matches like path/fpath)
	_pack_l_path="${_pack_l_meta#*";path="}";         _pack_l_path="${_pack_l_path%%;*}"
	_pack_l_source="${_pack_l_meta#*";source="}";     _pack_l_source="${_pack_l_source%%;*}"
	_pack_l_branch="${_pack_l_meta#*";branch="}";     _pack_l_branch="${_pack_l_branch%%;*}"
	_pack_l_tag="${_pack_l_meta#*";tag="}";           _pack_l_tag="${_pack_l_tag%%;*}"
	_pack_l_commit="${_pack_l_meta#*";commit="}";     _pack_l_commit="${_pack_l_commit%%;*}"
	_pack_l_load="${_pack_l_meta#*";load="}";         _pack_l_load="${_pack_l_load%%;*}"
	_pack_l_local="${_pack_l_meta#*";local="}";       _pack_l_local="${_pack_l_local%%;*}"

	# manual: skip entirely — user loads via pack_load later
	[[ "$_pack_l_load" == manual ]] && continue

	# Install if not present on disk (remote packages only)
	_pack_fire pre-install "$_pack_l_name"
	if [[ ! -d "$_pack_l_path" ]]; then
		if _pack_git_is_url "$_pack_l_source"; then
			_pack_git_clone "$_pack_l_source" "$_pack_l_path" \
				"$_pack_l_branch" "$_pack_l_tag" "$_pack_l_commit" || {
				print -u2 "pack: failed to install $_pack_l_name"
				continue
			}
		elif [[ "$_pack_l_local" != true ]]; then
			print -u2 "pack: $_pack_l_name: package directory missing: $_pack_l_path"
			continue
		fi
	fi
	_pack_fire post-install "$_pack_l_name"

	# ── Apply declarative fields ────────────────────────────────────
	pack_apply_env   "$_pack_l_name"
	pack_apply_path  "$_pack_l_name" "$_pack_l_path"
	pack_apply_alias "$_pack_l_name"
	pack_apply_fpath "$_pack_l_name" "$_pack_l_path"

	# ── Source entry point (load=now only) ──────────────────────────
	_pack_fire pre-load "$_pack_l_name"
	if [[ "$_pack_l_load" == now ]]; then
		_pack_l_entry=""
		if [[ -f "$_pack_l_path/init.ksh" ]]; then
			_pack_l_entry="$_pack_l_path/init.ksh"
		elif [[ -f "$_pack_l_path/plugin.ksh" ]]; then
			_pack_l_entry="$_pack_l_path/plugin.ksh"
		elif [[ -f "$_pack_l_path/${_pack_l_name}.ksh" ]]; then
			_pack_l_entry="$_pack_l_path/${_pack_l_name}.ksh"
		fi

		if [[ -n "$_pack_l_entry" ]]; then
			. "$_pack_l_entry" || {
				print -u2 "pack: $_pack_l_name: failed to source $_pack_l_entry"
				continue
			}
		fi
	fi

	# ── Eval rc snippet ─────────────────────────────────────────────
	pack_apply_rc "$_pack_l_name" "$_pack_l_path"
	_pack_fire post-load "$_pack_l_name"

	PACK_LOADED[$_pack_l_name]=1
done

# ── Cleanup ─────────────────────────────────────────────────────────────────
# Remove loop variables from the global namespace
unset _pack_l_name _pack_l_meta _pack_l_path _pack_l_source
unset _pack_l_branch _pack_l_tag _pack_l_commit
unset _pack_l_load _pack_l_disabled _pack_l_local _pack_l_entry
