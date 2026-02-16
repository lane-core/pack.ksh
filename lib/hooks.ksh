# pack.ksh — Internal lifecycle hooks (pub/sub)
# Sourced by pack.ksh at startup; not intended for standalone execution.
#
# Hook points: pre-resolve post-resolve pre-install post-install
#              pre-load post-load ready

typeset -A _PACK_HOOKS

# ── Register ─────────────────────────────────────────────────────────
# Usage: _pack_hook <hook> <func>
function _pack_hook {
    typeset hook="$1" func="$2"
    typeset -i count=${_PACK_HOOKS[${hook}:count]:-0}
    typeset -i i
    for (( i = 0; i < count; i++ )); do
        [[ "${_PACK_HOOKS[${hook}:${i}]}" == "$func" ]] && return 0
    done
    _PACK_HOOKS[${hook}:${count}]="$func"
    (( count++ ))
    _PACK_HOOKS[${hook}:count]=$count
}

# ── Unregister ───────────────────────────────────────────────────────
# Usage: _pack_unhook <hook> <func>
function _pack_unhook {
    typeset hook="$1" func="$2"
    typeset -i count=${_PACK_HOOKS[${hook}:count]:-0}
    (( count == 0 )) && return 0
    typeset -i i j=0 found=0
    for (( i = 0; i < count; i++ )); do
        if [[ "${_PACK_HOOKS[${hook}:${i}]}" == "$func" ]]; then
            unset "_PACK_HOOKS[${hook}:${i}]"
            found=1
        else
            if (( found )); then
                _PACK_HOOKS[${hook}:${j}]="${_PACK_HOOKS[${hook}:${i}]}"
                unset "_PACK_HOOKS[${hook}:${i}]"
            fi
            (( j++ ))
        fi
    done
    (( found )) && _PACK_HOOKS[${hook}:count]=$j
}

# ── Fire ─────────────────────────────────────────────────────────────
# Usage: _pack_fire <hook> [args...]
# Errors from handlers go to stderr but don't halt iteration.
function _pack_fire {
    typeset hook="$1"; shift
    typeset -i count=${_PACK_HOOKS[${hook}:count]:-0}
    (( count == 0 )) && return 0
    typeset -i i
    for (( i = 0; i < count; i++ )); do
        "${_PACK_HOOKS[${hook}:${i}]}" "$@" || true
    done
}
