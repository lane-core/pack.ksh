# pack.ksh — Internal lifecycle hooks (pub/sub)
# Sourced by pack.ksh at startup; not intended for standalone execution.
#
# Hook points: pre-resolve post-resolve pre-install post-install
#              pre-load post-load ready package-disabled

typeset -C -A _PACK_HOOKS

# ── Register ─────────────────────────────────────────────────────────
# Usage: _pack_hook <hook> <func>
function _pack_hook {
    typeset hook="$1" func="$2"

    # Initialize handler array if first registration for this hook
    if [[ -z "${_PACK_HOOKS[$hook]+set}" ]]; then
        _PACK_HOOKS[$hook]=(typeset -a handlers=())
    fi

    # Deduplicate: skip if already registered
    typeset -i i n
    n=${#_PACK_HOOKS[$hook].handlers[@]}
    for (( i = 0; i < n; i++ )); do
        [[ "${_PACK_HOOKS[$hook].handlers[i]}" == "$func" ]] && return 0
    done

    _PACK_HOOKS[$hook].handlers+=("$func")
}

# ── Unregister ───────────────────────────────────────────────────────
# Usage: _pack_unhook <hook> <func>
function _pack_unhook {
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
# Usage: _pack_fire <hook> [args...]
# Errors from handlers go to stderr but don't halt iteration.
function _pack_fire {
    typeset hook="$1"; shift

    [[ -z "${_PACK_HOOKS[$hook]+set}" ]] && return 0
    typeset -i n
    n=${#_PACK_HOOKS[$hook].handlers[@]}
    (( n == 0 )) && return 0

    typeset -i i
    for (( i = 0; i < n; i++ )); do
        "${_PACK_HOOKS[$hook].handlers[i]}" "$@" || true
    done
}
