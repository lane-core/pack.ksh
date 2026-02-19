# pack.ksh — Error accumulation for batch operations
# Sourced by pack.ksh at startup; not intended for standalone execution.

typeset -C -A _PACK_ERRORS
typeset -i _PACK_ERROR_COUNT=0

# Record an error from RESULT into the keyed store.
# Usage: _pack_error <name>   (reads RESULT for detail)
function _pack_error {
	typeset name="$1"
	_PACK_ERRORS[$name]=(
		code=${RESULT.code}
		type="${RESULT.type}"
		msg="${RESULT.msg}"
		op="${RESULT.op}"
	)
	(( _PACK_ERROR_COUNT++ ))
}

# Clear all accumulated errors.
function _pack_errors_clear {
	_PACK_ERRORS=()
	_PACK_ERROR_COUNT=0
}

# Print a summary of accumulated errors. Returns 1 if any errors exist.
# This is a presentation layer — stderr output happens here, not in library code.
function _pack_errors_report {
	(( _PACK_ERROR_COUNT == 0 )) && return 0
	print -u2 ""
	print -u2 "pack: ${_PACK_ERROR_COUNT} error(s):"
	typeset name eop emsg
	for name in "${!_PACK_ERRORS[@]}"; do
		eop="${_PACK_ERRORS[$name].op}"
		emsg="${_PACK_ERRORS[$name].msg}"
		print -u2 "  [${eop}] ${name}: ${emsg}"
	done
	return 1
}
