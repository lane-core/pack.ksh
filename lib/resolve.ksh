#!/bin/ksh
# pack.ksh — Dependency resolution
# Topological sort via Kahn's algorithm.
# Reads PACK_REGISTRY + PACK_CONFIGS, writes PACK_ORDER.

# ── Topological Sort ──────────────────────────────────────────────────
# Resolve package load order from dependency declarations.
# Skips disabled packages. Detects cycles.
function _pack_resolve {
    PACK_ORDER=()

    typeset -A in_degree
    typeset -A adj_list

    # Seed every registered, non-disabled package as a graph node
    typeset name
    for name in "${!PACK_REGISTRY[@]}"; do
        [[ "${PACK_REGISTRY[$name].disabled}" == true ]] && continue
        in_degree[$name]=0
        adj_list[$name]=""
    done

    # Build edges from depends fields in PACK_CONFIGS.
    # If A depends on B, edge B->A (B must load before A).
    typeset dep bare want actual
    typeset -i _ndeps _di
    for name in "${!in_degree[@]}"; do
        [[ -z "${PACK_CONFIGS[$name]+set}" ]] && continue
        _ndeps=${#PACK_CONFIGS[$name].depends[@]}
        (( _ndeps == 0 )) && continue

        for (( _di = 0; _di < _ndeps; _di++ )); do
            dep="${PACK_CONFIGS[$name].depends[_di]}"
            # Version constraint: depends=(foo@v1.0) → bare=foo, want=v1.0
            bare="$dep" want=""
            if [[ "$dep" == *'@'* ]]; then
                bare="${dep%%'@'*}"
                want="${dep#*'@'}"
                if [[ -n "${PACK_REGISTRY[$bare]+set}" && -n "$want" ]]; then
                    actual="${PACK_REGISTRY[$bare].tag:-}"
                    if [[ "$actual" != "$want" ]]; then
                        print -u2 "pack: ${name} depends on ${dep} but ${bare} is declared with tag=${actual}"
                    fi
                fi
                dep="$bare"
            fi

            if [[ -z "${in_degree[$dep]+set}" ]]; then
                print -u2 "pack: warning: ${name} depends on '${dep}' which is not declared"
                continue
            fi

            adj_list[$dep]="${adj_list[$dep]:+${adj_list[$dep]} }${name}"
            (( in_degree[$name]++ ))
        done
    done

    # ── Kahn's algorithm ──────────────────────────────────────────────
    # Collect zero-degree nodes as the initial queue
    typeset -a queue
    typeset node
    for node in "${!in_degree[@]}"; do
        (( in_degree[$node] == 0 )) && queue+=("$node")
    done

    typeset -a result
    typeset current neighbor
    while (( ${#queue[@]} > 0 )); do
        current="${queue[0]}"
        queue=("${queue[@]:1}")
        result+=("$current")

        for neighbor in ${adj_list[$current]}; do
            (( in_degree[$neighbor]-- ))
            (( in_degree[$neighbor] == 0 )) && queue+=("$neighbor")
        done
    done

    # ── Cycle detection ───────────────────────────────────────────────
    if (( ${#result[@]} != ${#in_degree[@]} )); then
        print -u2 "pack: cycle detected among:"
        for node in "${!in_degree[@]}"; do
            (( in_degree[$node] > 0 )) && print -u2 "  ${node}"
        done
        _pack_err 1 resolve "dependency cycle detected in package graph" resolve
        return 1
    fi

    PACK_ORDER=("${result[@]}")
}
