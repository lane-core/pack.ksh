# pack.ksh — Error reporting for batch operations
# Sourced by pack.ksh at startup; not intended for standalone execution.
#
# Error accumulation is done manually in callers (see functions/pack) —
# subshell pool workers can't use gather/collect across process boundaries.
# This file provides pack-specific formatting for the accumulated Result_t.

# Print a summary of accumulated errors from a Result_t accumulator.
# Returns 1 if the accumulator has errors, 0 if ok.
# Usage: _pack_report_errors acc_varname
function _pack_report_errors {
	typeset -n _pre_r=$1
	[[ ${_pre_r.status} == ok ]] && return 0
	print -u2 ""
	print -u2 "pack: ${_pre_r.code} error(s):"
	typeset _pre_line
	typeset _pre_IFS=$IFS
	IFS=$'\n'
	set -o noglob
	for _pre_line in ${_pre_r.error}; do
		print -u2 "  $_pre_line"
	done
	set +o noglob
	IFS=$_pre_IFS
	return 1
}
