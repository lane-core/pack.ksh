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
    typeset h
    for h in "${_PACK_HOOKS[$hook].handlers[@]}"; do
        [[ "$h" == "$func" ]] && return 0
    done

    _PACK_HOOKS[$hook].handlers+=("$func")
}

# ── Unregister ───────────────────────────────────────────────────────
# Usage: pack_unhook <hook> <func>
function pack_unhook {
    typeset hook="$1" func="$2"

    [[ -z "${_PACK_HOOKS[$hook]+set}" ]] && return 0

    typeset -a new=()
    typeset h
    for h in "${_PACK_HOOKS[$hook].handlers[@]}"; do
        [[ "$h" != "$func" ]] && new+=("$h")
    done

    _PACK_HOOKS[$hook]=(typeset -a handlers=("${new[@]}"))
}

# ── Fire ─────────────────────────────────────────────────────────────
# Usage: pack_fire <hook> [args...]
# Errors from handlers go to stderr but don't halt iteration.
function pack_fire {
    (( $# )) || return 0
    [[ -z "${_PACK_HOOKS[$1]+set}" ]] && return 0

    # for-in iterates directly — no index or count needed
    typeset _pf_h
    for _pf_h in "${_PACK_HOOKS[$1].handlers[@]}"; do
        [[ -n "$_pf_h" ]] && "$_pf_h" "${@:2}" || true
    done
}
