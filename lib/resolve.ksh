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
        [[ "${PACK_REGISTRY[$name]}" == *"disabled=true"* ]] && continue
        in_degree[$name]=0
        adj_list[$name]=""
    done

    # Build edges from depends fields in PACK_CONFIGS.
    # If A depends on B, edge B->A (B must load before A).
    for name in "${!in_degree[@]}"; do
        typeset config="${PACK_CONFIGS[$name]:-}"
        [[ "$config" == *"depends=("* ]] || continue

        typeset deps="${config#*'depends=('}"
        deps="${deps%%')'*}"
        [[ -z "$deps" ]] && continue

        typeset dep
        for dep in $deps; do
            # Version constraint: depends=(foo@v1.0) → bare=foo, want=v1.0
            typeset bare="$dep" want=""
            if [[ "$dep" == *'@'* ]]; then
                bare="${dep%%'@'*}"
                want="${dep#*'@'}"
                typeset meta="${PACK_REGISTRY[$bare]:-}"
                if [[ -n "$meta" && -n "$want" ]]; then
                    typeset actual="${meta#*tag=}"; actual="${actual%%;*}"
                    if [[ "$actual" != "$want" ]]; then
                        print -u2 "pack: ${name} depends on ${dep} but ${bare} is declared with tag=${actual}"
                    fi
                fi
                dep="$bare"
            fi

            # Silently skip deps that aren't in the graph
            [[ -n "${in_degree[$dep]+set}" ]] || continue

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
    while (( ${#queue[@]} > 0 )); do
        typeset current="${queue[0]}"
        queue=("${queue[@]:1}")
        result+=("$current")

        typeset neighbor
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
        _PACK_ERROR="dependency cycle detected in package graph"
        return 1
    fi

    PACK_ORDER=("${result[@]}")
}
