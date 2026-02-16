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
typeset -x PACK_SELF="${.sh.file%/*}"
typeset -x PACK_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/ksh/pack.ksh"
typeset -x PACK_ORIGIN
PACK_ORIGIN=$(command git -C "$PACK_SELF" remote get-url origin 2>/dev/null) || PACK_ORIGIN="$PACK_SELF"

for _pack_dir in "$PACK_PACKAGES" "$PACK_STATE_DIR" "$PACK_CACHE"; do
	[[ -d "$_pack_dir" ]] || mkdir -p "$_pack_dir"
done
unset _pack_dir

# ── Data Structures ──────────────────────────────────────────────────────────
typeset -A PACK_REGISTRY     # name -> semicolon-delimited key=value metadata
typeset -A PACK_CONFIGS      # name -> serialized declarative fields
typeset -A PACK_STATE        # name -> "commit:timestamp"
typeset -A PACK_LOADED       # name -> 1 (prevents double-load)
typeset -a PACK_ORDER        # resolved load order (filled by lib/resolve.ksh)

# ── Source Lib Helpers ────────────────────────────────────────────────────────
# Git operations, dependency resolution, and lockfile management. Each is
# optional — pack.ksh works for declaration without them.
for _pack_lib in git resolve lock config hooks; do
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
		~*)    REPLY="${id/#\~/$HOME}" ;;
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
		install|update|remove|list|freeze|restore|info|run|diff|self-update|help|-h|--help)
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
				run)         _pack_cmd_run "$@" ;;
				diff)        _pack_cmd_diff ;;
				self-update) _pack_cmd_self_update ;;
				help|-h|--help) _pack_cmd_help ;;
			esac
			return
			;;
	esac

	# ── Package declaration ──────────────────────────────────────────────
	(( $# < 1 )) && {
		print -u2 "pack: usage: pack <id> [key=value ...]"
		return 1
	}
	typeset id="$1"; shift

	typeset source name pkg_path
	typeset as="" branch="" tag="" commit="" url=""
	typeset local_pkg=false load=lazy build="" disabled=false
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
				source)   source_file="$val" ;;
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

	# -- Disabled packages get registered but nothing else --
	[[ "$disabled" == true ]] && {
		PACK_REGISTRY[$name]="disabled=true"
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
	PACK_REGISTRY[$name]="path=$pkg_path;source=$source;branch=$branch;tag=$tag;commit=$commit;local=$local_pkg;load=$load;disabled=false"
	[[ -n "$build" ]]       && PACK_REGISTRY[$name]+=";build=$build"
	[[ -n "$source_file" ]] && PACK_REGISTRY[$name]+=";source_file=$source_file"
	[[ -n "$depends_str" ]] && PACK_REGISTRY[$name]+=";depends=$depends_str"

	# -- Serialize declarative fields into PACK_CONFIGS --
	typeset config=""
	[[ -n "$fpath_str" ]] && config+="fpath=($fpath_str);"
	[[ -n "$path_str" ]]  && config+="path=($path_str);"
	[[ -n "$alias_str" ]] && config+="alias=($alias_str);"
	[[ -n "$env_str" ]]     && config+="env=($env_str);"
	[[ -n "$depends_str" ]] && config+="depends=($depends_str);"
	[[ -n "$rc" ]]          && config+="rc=($rc);"
	[[ -n "$config" ]] && PACK_CONFIGS[$name]="$config"

	return 0
}

# ── Field Extraction ─────────────────────────────────────────────────────────
# Extract the contents of a parenthesized field from a PACK_CONFIGS entry.
# Prepends a semicolon to anchor the match, preventing "path" from matching
# inside "fpath". Sets REPLY to the field contents, empty if absent.
function _pack_extract_field {
	typeset config=";$1" field="$2"
	if [[ "$config" == *";${field}=("* ]]; then
		typeset data="${config#*";${field}=("}"
		REPLY="${data%%\)*}"
	else
		REPLY=""
	fi
}

# ── pack_apply_env ────────────────────────────────────────────────────────────
function pack_apply_env {
	typeset id="$1"
	typeset config="${PACK_CONFIGS[$id]:-}"
	[[ -z "$config" ]] && return 0
	_pack_extract_field "$config" "env"
	[[ -z "$REPLY" ]] && return 0
	typeset var
	for var in $REPLY; do
		[[ "$var" == *=* ]] && export "$var"
	done
}

# ── pack_apply_path ──────────────────────────────────────────────────────────
# Prepend directories to PATH. Relative dirs resolve against pkg_path.
function pack_apply_path {
	typeset id="$1" pkg_path="$2"
	typeset config="${PACK_CONFIGS[$id]:-}"
	[[ -z "$config" ]] && return 0
	_pack_extract_field "$config" "path"
	[[ -z "$REPLY" ]] && return 0
	typeset dir full
	for dir in $REPLY; do
		if [[ "$dir" == /* ]]; then full="$dir"; else full="$pkg_path/$dir"; fi
		[[ -d "$full" ]] && PATH="$full:$PATH"
	done
}

# ── pack_apply_alias ─────────────────────────────────────────────────────────
function pack_apply_alias {
	typeset id="$1"
	typeset config="${PACK_CONFIGS[$id]:-}"
	[[ -z "$config" ]] && return 0
	_pack_extract_field "$config" "alias"
	[[ -z "$REPLY" ]] && return 0
	typeset def
	for def in $REPLY; do
		[[ "$def" == *=* ]] && alias "$def"
	done
}

# ── pack_apply_fpath ─────────────────────────────────────────────────────────
# Prepend directories to FPATH and autoload their function files.
function pack_apply_fpath {
	typeset id="$1" pkg_path="$2"
	typeset config="${PACK_CONFIGS[$id]:-}"
	[[ -z "$config" ]] && return 0
	_pack_extract_field "$config" "fpath"
	[[ -z "$REPLY" ]] && return 0
	typeset entry full fname
	for entry in $REPLY; do
		if [[ "$entry" == /* ]]; then full="$entry"; else full="$pkg_path/$entry"; fi
		if [[ -d "$full" ]]; then
			FPATH="$full:${FPATH:-}"
			for fname in "$full"/*; do
				[[ -f "$fname" ]] || continue
				typeset base="${fname##*/}"
				autoload "${base%.ksh}"
			done
		fi
	done
}

# ── pack_apply_rc ────────────────────────────────────────────────────────────
# Evaluate rc snippet with PKG_DIR and PKG_NAME set in the environment.
function pack_apply_rc {
	typeset id="$1" pkg_path="$2"
	typeset config="${PACK_CONFIGS[$id]:-}"
	[[ -z "$config" ]] && return 0
	_pack_extract_field "$config" "rc"
	[[ -z "$REPLY" ]] && return 0
	PKG_DIR="$pkg_path" PKG_NAME="$id" eval "$REPLY"
}

# ── Self-Registration ──────────────────────────────────────────────────────
# pack manages itself as a package so `pack update pack` works
PACK_REGISTRY[pack]="path=$PACK_SELF;source=${PACK_ORIGIN:-$PACK_SELF};branch=main;local=true;load=manual;disabled=false"
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
