# pack.ksh — djb-style filesystem config reader
# Translates a directory hierarchy into pack() calls so that filesystem
# config and ksh-script config produce identical data structures.
#
# Sourced by pack.ksh at startup; not intended for standalone execution.

# ── Scalar Reader ────────────────────────────────────────────────────
# Read a single plaintext file into REPLY, trimming trailing whitespace.
# Returns 1 if the file does not exist.
function _pack_config_read_scalar {
	typeset file="$1"
	[[ -f "$file" ]] || return 1
	REPLY=""
	typeset line
	while IFS= read -r line || [[ -n "$line" ]]; do
		REPLY+="${REPLY:+$'\n'}${line}"
	done < "$file"
}

# ── Array Reader ─────────────────────────────────────────────────────
# Read directory entry names as space-separated array elements into REPLY.
# File contents are ignored — only the filenames matter.
# Returns 1 if the directory does not exist.
function _pack_config_read_array {
	typeset dir="$1"
	[[ -d "$dir" ]] || return 1
	REPLY=""
	typeset entry
	for entry in "$dir"/*; do
		# Glob expands to literal */\* when dir is empty
		[[ -e "$entry" ]] || continue
		REPLY+="${REPLY:+ }${entry##*/}"
	done
}

# ── Depends Reader ───────────────────────────────────────────────────
# Filenames are dependency names. Non-empty file content becomes a
# version constraint appended as @content (e.g. "hooks@v1.0").
function _pack_config_read_depends {
	typeset dir="$1"
	[[ -d "$dir" ]] || return 1
	REPLY=""
	typeset entry name constraint
	for entry in "$dir"/*; do
		[[ -e "$entry" ]] || continue
		name="${entry##*/}"
		constraint=""
		if [[ -f "$entry" ]]; then
			{ read -r constraint || true; } < "$entry"
		fi
		if [[ -n "$constraint" ]]; then
			REPLY+="${REPLY:+ }${name}@${constraint}"
		else
			REPLY+="${REPLY:+ }${name}"
		fi
	done
}

# ── Key=Value Directory Reader ───────────────────────────────────────
# Reads a directory where each filename is a key and file content is the
# value. Sets REPLY to space-separated "key=value" entries.
# Used for alias/ and env/ directories.
function _pack_config_read_kvdir {
	typeset dir="$1"
	[[ -d "$dir" ]] || return 1
	REPLY=""
	typeset entry name value
	for entry in "$dir"/*; do
		[[ -e "$entry" ]] || continue
		name="${entry##*/}"
		value=""
		if [[ -f "$entry" ]]; then
			{ read -r value || true; } < "$entry"
		fi
		REPLY+="${REPLY:+ }${name}=${value}"
	done
}

# ── Package Reader ───────────────────────────────────────────────────
# Assemble and execute a pack() call from a single package directory.
# source is the only required field — skip with a warning if missing.
function _pack_config_read_pkg {
	typeset dir="$1"
	typeset -a args

	# source is mandatory
	_pack_config_read_scalar "$dir/source" || {
		print -u2 "pack: config: ${dir##*/}: missing source file, skipping"
		return 1
	}
	args=("$REPLY")

	# Scalar fields — each maps directly to a key=value argument
	typeset field
	for field in branch tag commit as local load build disabled source_file rc url; do
		_pack_config_read_scalar "$dir/$field" || continue
		case "$field" in
			source_file) args+=("source=$REPLY") ;;
			*)           args+=("$field=$REPLY") ;;
		esac
	done

	# Array fields — directory entries become (val1 val2 ...) syntax
	typeset afield
	for afield in fpath path; do
		_pack_config_read_array "$dir/$afield" || continue
		[[ -n "$REPLY" ]] && args+=("$afield=($REPLY)")
	done

	# Depends — like array but with optional @constraint
	if _pack_config_read_depends "$dir/depends"; then
		[[ -n "$REPLY" ]] && args+=("depends=($REPLY)")
	fi

	# Key=value dirs — alias and env
	typeset kvfield
	for kvfield in alias env; do
		_pack_config_read_kvdir "$dir/$kvfield" || continue
		[[ -n "$REPLY" ]] && args+=("$kvfield=($REPLY)")
	done

	pack "${args[@]}"
}

# ── Directory Scanner ────────────────────────────────────────────────
# Iterate all subdirectories in the packages config dir and read each
# as a package declaration. Silent no-op if the directory doesn't exist.
function _pack_config_read_dir {
	typeset dir="$1"
	[[ -d "$dir" ]] || return 0
	typeset pkg_dir
	for pkg_dir in "$dir"/*/; do
		# Glob expands to literal */ when dir is empty
		[[ -d "$pkg_dir" ]] || continue
		_pack_config_read_pkg "${pkg_dir%/}"
	done
}
