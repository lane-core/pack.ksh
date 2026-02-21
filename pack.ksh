#!/bin/ksh
# pack.ksh — Declarative package manager for ksh93u+m
# Source this from .kshrc. Declares packages, applies their configuration
# fields, and defers cloning/resolution/loading to lib/ helpers.

# ── Source Guard ──────────────────────────────────────────────────────────────
[[ -n "${_PACK_SOURCED:-}" ]] && return 0
typeset -r _PACK_SOURCED=1

# ── XDG Paths ────────────────────────────────────────────────────────────────
typeset -x PACK_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}/ksh/pack"
typeset -x PACK_PACKAGES="$PACK_ROOT/packages"
typeset -x PACK_STATE_DIR="$PACK_ROOT/state"
typeset -x PACK_CACHE="$PACK_ROOT/cache"
typeset -xi PACK_JOBS=${PACK_JOBS:-4}
typeset -x PACK_SELF="${.sh.file%/*}"
typeset -x PACK_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/ksh/pack.ksh"
typeset -x PACK_ORIGIN
PACK_ORIGIN=$(command git -C "$PACK_SELF" remote get-url origin 2>/dev/null) || PACK_ORIGIN="$PACK_SELF"

for _pack_dir in "$PACK_PACKAGES" "$PACK_STATE_DIR" "$PACK_CACHE"; do
	[[ -d "$_pack_dir" ]] || mkdir -p "$_pack_dir"
done
unset _pack_dir

# ── func.ksh — safe shell primitives ─────────────────────────────────────────
. "${PACK_SELF}/../func.ksh/init.ksh" || {
	print -u2 "pack: failed to source func.ksh"
	return 1
}

# ── Progress Tracking ───────────────────────────────────────────────────────
# Global instance shared by all commands — no namerefs needed.
Progress_t _pack_progress

# ── Data Structures ──────────────────────────────────────────────────────────
typeset -C -A PACK_REGISTRY  # name -> compound: path, source, branch, tag, commit, local, load, disabled, build, source_file, depends
typeset -C -A PACK_CONFIGS   # name -> compound: fpath[], path[], depends[], alias[], env[], rc
typeset -C -A PACK_STATE     # name -> compound: commit, timestamp
typeset -A PACK_LOADED       # name -> 1 (prevents double-load) -- stays flat
typeset -a PACK_ORDER        # resolved load order -- stays flat

# ── Pipeline / Functor ──────────────────────────────────────────────────────
# Iterate packages with optional filter. Uses PACK_ORDER if populated,
# otherwise falls back to PACK_REGISTRY keys.
# Usage: _pack_each <callback> [filter]
_pack_each() {
	typeset callback="$1" filter="${2:-}" name
	if (( ${#PACK_ORDER[@]} > 0 )); then
		for name in "${PACK_ORDER[@]}"; do
			[[ -n "$filter" ]] && { "$filter" "$name" || continue; }
			"$callback" "$name"
		done
	else
		for name in "${!PACK_REGISTRY[@]}"; do
			# Guard against phantom keys left by unset on compound-associative
			[[ -z "${PACK_REGISTRY[$name].path:-}" && -z "${PACK_REGISTRY[$name].disabled:-}" ]] && continue
			[[ -n "$filter" ]] && { "$filter" "$name" || continue; }
			"$callback" "$name"
		done
	fi
}

# Standard filter predicates for _pack_each
# POSIX-style so they don't create scope barriers for dynamic scoping
_pack_filter_enabled()   { [[ "${PACK_REGISTRY[$1].disabled:-}" != true ]]; }
_pack_filter_remote()    { _pack_filter_enabled "$1" && [[ "${PACK_REGISTRY[$1].local:-}" != true ]]; }
_pack_filter_installed() { _pack_filter_enabled "$1" && [[ -d "${PACK_REGISTRY[$1].path:-}" ]]; }

# ── Reactive Disable ────────────────────────────────────────────────────────
# Disable a package at runtime. Marks it disabled, removes from PACK_ORDER,
# and fires package-disabled hook. Use instead of discipline functions (which
# don't fire on compound-associative arrays in ksh93u+m).
function _pack_disable {
	typeset name="$1"
	[[ -z "${PACK_REGISTRY[$name]+set}" ]] && return 1
	PACK_REGISTRY[$name].disabled=true
	# Remove from PACK_ORDER
	typeset -a _new=()
	typeset _n
	for _n in "${PACK_ORDER[@]}"; do
		[[ "$_n" != "$name" ]] && _new+=("$_n")
	done
	PACK_ORDER=("${_new[@]}")
	_pack_fire "package-disabled" "$name"
}

# ── Source Lib Helpers ────────────────────────────────────────────────────────
# Git operations, dependency resolution, and lockfile management. Each is
# optional — pack.ksh works for declaration without them.
for _pack_lib in errors git async resolve lock config hooks; do
	if [[ -f "$PACK_SELF/lib/${_pack_lib}.ksh" ]]; then
		. "$PACK_SELF/lib/${_pack_lib}.ksh" || {
			print -u2 "pack: failed to source lib/${_pack_lib}.ksh"
			return 1
		}
	fi
done
unset _pack_lib

# ── URL Resolution ───────────────────────────────────────────────────────────
# Expand shorthand IDs to full git URLs. Sets REPLY.
#   user/repo -> github, gl:user/repo -> gitlab, bb:user/repo -> bitbucket
function _pack_resolve_url {
	typeset id="$1"
	case "$id" in
		https://*|http://*|git://*|ssh://*) REPLY="$id" ;;
		gl:*)  REPLY="https://gitlab.com/${id#gl:}.git" ;;
		bb:*)  REPLY="https://bitbucket.org/${id#bb:}.git" ;;
		/*)    REPLY="$id" ;;
		~/*)   REPLY="$HOME/${id#'~/'}" ;;
		~)     REPLY="$HOME" ;;
		~*)    print -u2 "pack: ~user paths not supported: $id"; REPLY="$id" ;;
		git@*) REPLY="$id" ;;
		*/*)   REPLY="https://github.com/$id.git" ;;
		*)     REPLY="$id" ;;
	esac
}

# Derive a short package name from a package ID. Sets REPLY.
function _pack_derive_name {
	typeset name="$1"
	name="${name#https://}"; name="${name#http://}"
	name="${name#git://}";   name="${name#ssh://}"
	name="${name#github.com/}"; name="${name#gitlab.com/}"
	name="${name#bitbucket.org/}"
	name="${name#gl:}"; name="${name#bb:}"
	name="${name%.git}"; name="${name##*/}"
	REPLY="$name"
}

# ── pack() — Declaration + CLI Entry Point ──────────────────────────────────
# User-facing API. CLI subcommands (install, update, ...) are dispatched first;
# anything else is treated as a package declaration.
#
# Usage:
#   pack install                    # CLI: install all declared packages
#   pack update my-plugin           # CLI: update a specific package
#   pack "user/repo" branch=main fpath=functions path=bin
#   pack "https://github.com/user/repo.git" as=repo tag=v1.0
#   pack "$HOME/dev/plugin" local=true fpath=functions
#   pack "my-prompt" depends=(my-hooks my-async) fpath=functions
function pack {
	# ── CLI subcommands ──────────────────────────────────────────────────
	case "${1:-}" in
		install|update|remove|list|freeze|restore|info|path|run|diff|doctor|self-update|version|help|-h|--help)
			# Lazy-load CLI handlers from functions/pack
			if ! typeset -f _pack_cmd_help >/dev/null 2>&1; then
				. "$PACK_SELF/functions/pack" || return 1
			fi
			typeset cmd="$1"; shift
			case "$cmd" in
				install)     _pack_cmd_install "$@" ;;
				update)      _pack_cmd_update "$@" ;;
				remove)      _pack_cmd_remove "$@" ;;
				list)        _pack_cmd_list ;;
				freeze)      pack_freeze ;;
				restore)     pack_restore ;;
				info)        _pack_cmd_info "$@" ;;
				path)        _pack_cmd_path "$@" ;;
				run)         _pack_cmd_run "$@" ;;
				diff)        _pack_cmd_diff ;;
				doctor)      _pack_cmd_doctor "$@" ;;
				self-update) _pack_cmd_self_update ;;
				version)     _pack_cmd_version ;;
				help|-h|--help) _pack_cmd_help ;;
			esac
			return
			;;
	esac

	# ── No arguments — show help ─────────────────────────────────────────
	(( $# < 1 )) && {
		if ! typeset -f _pack_cmd_help >/dev/null 2>&1; then
			. "$PACK_SELF/functions/pack" || return 1
		fi
		_pack_cmd_help
		return 0
	}

	# ── Package declaration ──────────────────────────────────────────────
	typeset id="$1"; shift

	typeset source name pkg_path
	typeset as="" branch="" tag="" commit="" url=""
	typeset local_pkg=false load=autoload build="" disabled=false
	typeset source_file="" rc=""
	typeset depends_str="" fpath_str="" path_str="" alias_str="" env_str=""

	_pack_resolve_url "$id"; source="$REPLY"
	_pack_derive_name "$id"; name="$REPLY"

	# -- Parse key=value and key=(...) arguments --
	typeset arg key val rest
	while (( $# > 0 )); do
		arg="$1"; shift
		case "$arg" in
		*=\(*)
			# Array field: key=(val1 val2 ...)
			key="${arg%%=*}"
			rest="${arg#*=\(}"
			if [[ "$rest" == *\) ]]; then
				rest="${rest%\)}"
			else
				while (( $# > 0 )); do
					if [[ "$1" == *\) ]]; then
						rest+=" ${1%\)}"
						shift; break
					else
						rest+=" $1"; shift
					fi
				done
			fi
			case "$key" in
				depends) depends_str="$rest" ;;
				fpath)   fpath_str="$rest" ;;
				path)    path_str="$rest" ;;
				alias)   alias_str="$rest" ;;
				env)     env_str="$rest" ;;
				*) print -u2 "pack: $name: unknown array field: $key" ;;
			esac
			;;
		*=*)
			key="${arg%%=*}"; val="${arg#*=}"
			case "$key" in
				as)       as="$val"; name="$val" ;;
				branch)   branch="$val" ;;
				tag)      tag="$val" ;;
				commit)   commit="$val" ;;
				local)    local_pkg="$val" ;;
				load)     load="$val" ;;
				build)    build="$val" ;;
				disabled) disabled="$val" ;;
				entry)    source_file="$val" ;;
				url)      url="$val" ;;
				rc)       rc="$val" ;;
				fpath)    fpath_str="$val" ;;
				path)     path_str="$val" ;;
				env)      env_str="$val" ;;
				depends)  depends_str="$val" ;;
				*) print -u2 "pack: $name: unknown field: $key" ;;
			esac
			;;
		*)
			print -u2 "pack: $name: invalid argument: $arg"
			;;
		esac
	done

	# Validate package name (must be safe for word splitting in resolve.ksh)
	if [[ "$name" == *[[:space:]]* || "$name" == *['*?[']*  ]]; then
		print -u2 "pack: invalid package name (contains whitespace or glob characters): $name"
		return 1
	fi

	# -- Disabled packages get registered but nothing else --
	[[ "$disabled" == true ]] && {
		PACK_REGISTRY[$name]=(disabled=true)
		return 0
	}

	# -- Infer local from source protocol (filesystem paths are local) --
	if [[ "$source" == /* ]]; then
		local_pkg=true
	fi

	# -- Determine package path on disk --
	if [[ "$local_pkg" == true ]]; then
		pkg_path="$source"
		# url= provides the remote git source for updates
		if [[ -n "$url" ]]; then
			_pack_resolve_url "$url"; source="$REPLY"
		fi
	else
		pkg_path="$PACK_PACKAGES/$name"
	fi

	# -- Store metadata in registry --
	PACK_REGISTRY[$name]=(
		path="$pkg_path"
		source="$source"
		branch="$branch"
		tag="$tag"
		commit="$commit"
		local="$local_pkg"
		load="$load"
		disabled=false
		build="$build"
		source_file="$source_file"
		depends="$depends_str"
	)

	# -- Store declarative fields into PACK_CONFIGS --
	typeset -a _fpath_a=() _path_a=() _depends_a=() _alias_a=() _env_a=()
	[[ -n "$fpath_str" ]]   && _fpath_a=($fpath_str)
	[[ -n "$path_str" ]]    && _path_a=($path_str)
	[[ -n "$depends_str" ]] && _depends_a=($depends_str)
	[[ -n "$alias_str" ]]   && _alias_a=($alias_str)
	[[ -n "$env_str" ]]     && _env_a=($env_str)

	PACK_CONFIGS[$name]=(
		typeset -a fpath=("${_fpath_a[@]}")
		typeset -a path=("${_path_a[@]}")
		typeset -a depends=("${_depends_a[@]}")
		typeset -a alias=("${_alias_a[@]}")
		typeset -a env=("${_env_a[@]}")
		rc="$rc"
	)

	return 0
}

# ── pack_apply_env ────────────────────────────────────────────────────────────
function pack_apply_env {
	typeset id="$1"
	[[ -z "${PACK_CONFIGS[$id]+set}" ]] && return 0
	typeset -i i n
	n=${#PACK_CONFIGS[$id].env[@]}
	(( n == 0 )) && return 0
	# SECURITY: env= exports variables into the current shell session.
	# A package could override PATH, IFS, or other critical variables.
	# Only install packages you trust.
	typeset var
	for (( i = 0; i < n; i++ )); do
		var="${PACK_CONFIGS[$id].env[i]}"
		[[ "$var" == *=* ]] && export "$var"
	done
}

# ── pack_apply_path ──────────────────────────────────────────────────────────
# Prepend directories to PATH. Relative dirs resolve against pkg_path.
function pack_apply_path {
	typeset id="$1" pkg_path="$2"
	[[ -z "${PACK_CONFIGS[$id]+set}" ]] && return 0
	typeset -i i n
	n=${#PACK_CONFIGS[$id].path[@]}
	(( n == 0 )) && return 0
	typeset dir full
	for (( i = 0; i < n; i++ )); do
		dir="${PACK_CONFIGS[$id].path[i]}"
		if [[ "$dir" == /* ]]; then full="$dir"; else full="$pkg_path/$dir"; fi
		[[ -d "$full" ]] && PATH="$full:$PATH"
	done
}

# ── pack_apply_alias ─────────────────────────────────────────────────────────
function pack_apply_alias {
	typeset id="$1"
	[[ -z "${PACK_CONFIGS[$id]+set}" ]] && return 0
	typeset -i i n
	n=${#PACK_CONFIGS[$id].alias[@]}
	(( n == 0 )) && return 0
	typeset def
	for (( i = 0; i < n; i++ )); do
		def="${PACK_CONFIGS[$id].alias[i]}"
		[[ "$def" == *=* ]] && alias "$def"
	done
}

# ── pack_apply_fpath ─────────────────────────────────────────────────────────
# Prepend directories to FPATH and autoload their function files.
function pack_apply_fpath {
	typeset id="$1" pkg_path="$2"
	[[ -z "${PACK_CONFIGS[$id]+set}" ]] && return 0
	typeset -i i n
	n=${#PACK_CONFIGS[$id].fpath[@]}
	(( n == 0 )) && return 0
	typeset entry full fname
	for (( i = 0; i < n; i++ )); do
		entry="${PACK_CONFIGS[$id].fpath[i]}"
		if [[ "$entry" == /* ]]; then full="$entry"; else full="$pkg_path/$entry"; fi
		if [[ -d "$full" ]]; then
			FPATH="$full:${FPATH:-}"
			for fname in "$full"/*; do
				[[ -f "$fname" ]] || continue
				typeset base="${fname##*/}"
				[[ "$base" == .* ]] && continue
				autoload "${base%.ksh}"
			done
		fi
	done
}

# ── pack_apply_rc ────────────────────────────────────────────────────────────
# Evaluate rc snippet with PKG_DIR and PKG_NAME set in the environment.
function pack_apply_rc {
	typeset id="$1" pkg_path="$2"
	[[ -z "${PACK_CONFIGS[$id]+set}" ]] && return 0
	typeset rc_snippet
	rc_snippet="${PACK_CONFIGS[$id].rc}"
	[[ -z "$rc_snippet" ]] && return 0
	# SECURITY: rc snippets execute in the current shell. Only source packages you trust.
	PKG_DIR="$pkg_path" PKG_NAME="$id" eval "$rc_snippet" || print -u2 "pack: $id: rc snippet failed"
}

# ── Self-Registration ──────────────────────────────────────────────────────
# pack manages itself as a package so `pack update pack` works
PACK_REGISTRY[pack]=(
	path="$PACK_SELF"
	source="${PACK_ORIGIN:-$PACK_SELF}"
	branch=main
	tag=""
	commit=""
	local=true
	load=manual
	disabled=false
	build=""
	source_file=""
	depends=""
)
PACK_LOADED[pack]=1

# ── Read Configuration ────────────────────────────────────────────────────
# Three config layers, last writer wins (same as multiple pack() calls):
#   1. $PACK_CONFIG         — main ksh script (traditional)
#   2. packages/            — djb filesystem hierarchy
#   3. pkgs.d/*.ksh         — aggregation scripts (split configs)
typeset _pack_config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/ksh"

[[ -f "$PACK_CONFIG" ]] && . "$PACK_CONFIG"

_pack_config_read_dir "$_pack_config_dir/packages"

if [[ -d "$_pack_config_dir/pkgs.d" ]]; then
	for _pack_pkgsd in "$_pack_config_dir"/pkgs.d/*.ksh; do
		[[ -f "$_pack_pkgsd" ]] && . "$_pack_pkgsd"
	done
	unset _pack_pkgsd
fi
unset _pack_config_dir

# ── Resolve + Load ────────────────────────────────────────────────────────
_pack_fire pre-resolve
_pack_resolve || return 1
_pack_fire post-resolve
. "$PACK_SELF/load.ksh"
_pack_fire ready
