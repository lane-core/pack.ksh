# pack.ksh — Internal lifecycle hooks (pub/sub)
# Sourced by pack.ksh at startup; not intended for standalone execution.
#
# Hook points: pre-resolve post-resolve pre-install post-install
#              pre-load post-load ready package-disabled

typeset -C -A _PACK_HOOKS

# ── Register ─────────────────────────────────────────────────────────
# Usage: pack_hook <hook> <func>
function pack_hook {
    typeset hook="$1" func="$2"

    # Initialize handler array if first registration for this hook
    if [[ -z "${_PACK_HOOKS[$hook]+set}" ]]; then
        _PACK_HOOKS[$hook]=(typeset -a handlers=())
    fi

    # Deduplicate
    typeset -i i n
    n=${#_PACK_HOOKS[$hook].handlers[@]}
    for (( i = 0; i < n; i++ )); do
        [[ "${_PACK_HOOKS[$hook].handlers[i]}" == "$func" ]] && return 0
    done

    # Full reassignment (not +=) for compound-array sub-field safety
    typeset -a _cur=()
    for (( i = 0; i < n; i++ )); do
        _cur+=("${_PACK_HOOKS[$hook].handlers[i]}")
    done
    _cur+=("$func")
    _PACK_HOOKS[$hook]=(typeset -a handlers=("${_cur[@]}"))
}

# ── Unregister ───────────────────────────────────────────────────────
# Usage: pack_unhook <hook> <func>
function pack_unhook {
    typeset hook="$1" func="$2"

    [[ -z "${_PACK_HOOKS[$hook]+set}" ]] && return 0
    typeset -i n
    n=${#_PACK_HOOKS[$hook].handlers[@]}
    (( n == 0 )) && return 0

    # Rebuild handlers array without the target
    typeset -a new=()
    typeset -i i
    for (( i = 0; i < n; i++ )); do
        [[ "${_PACK_HOOKS[$hook].handlers[i]}" != "$func" ]] && \
            new+=("${_PACK_HOOKS[$hook].handlers[i]}")
    done

    _PACK_HOOKS[$hook]=(typeset -a handlers=("${new[@]}"))
}

# ── Fire ─────────────────────────────────────────────────────────────
# Usage: pack_fire <hook> [args...]
# Errors from handlers go to stderr but don't halt iteration.
function pack_fire {
    (( $# )) || return 0
    [[ -z "${_PACK_HOOKS[$1]+set}" ]] && return 0

    # Avoid typeset -i and ${#...[@]} — both trigger ksh93u+m bugs when
    # called from a DEBUG trap during compound variable assignment context.
    # The for-in pattern iterates the array directly (empty → no iterations).
    typeset _pf_h
    for _pf_h in "${_PACK_HOOKS[$1].handlers[@]}"; do
        [[ -n "$_pf_h" ]] && "$_pf_h" "${@:2}" || true
    done
}
