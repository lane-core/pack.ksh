# pack.ksh — Error accumulation and reporting for batch operations
# Sourced by pack.ksh at startup; not intended for standalone execution.
#
# Subshell pool workers can't use gather/collect across process boundaries,
# so callers accumulate errors via _pack_accum_err and format them with
# _pack_report_errors. Both operate on a Result_t accumulator where .error
# holds newline-separated messages and .code counts failures.

# Fold a single error message into a Result_t accumulator.
# Usage: _pack_accum_err acc_varname "message"
function _pack_accum_err {
	typeset -n _pae_acc=$1
	typeset _pae_msg=$2
	if [[ ${_pae_acc.status} == ok ]]; then
		_pae_acc.err "$_pae_msg" 1
	else
		_pae_acc.error="${_pae_acc.error}"$'\n'"$_pae_msg"
		_pae_acc.code=$(( ${_pae_acc.code} + 1 ))
	fi
}

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
