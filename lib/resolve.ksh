#!/bin/ksh
# pack.ksh — Dependency resolution
# Builds adjacency map from PACK_REGISTRY + PACK_CONFIGS, delegates
# topological sort to func.ksh's toposort. Writes PACK_ORDER.

function _pack_resolve {
    PACK_ORDER=()

    # Build adjacency map: _pr_deps[name] = space-separated dependencies
    typeset -A _pr_deps

    # Register every non-disabled package as a graph node
    typeset _pr_name
    for _pr_name in "${!PACK_REGISTRY[@]}"; do
        [[ "${PACK_REGISTRY[$_pr_name].disabled}" == true ]] && continue
        _pr_deps[$_pr_name]=""
    done

    # Build edges from depends fields in PACK_CONFIGS.
    # Version constraint warnings are pack-specific (handled here before toposort).
    typeset _pr_dep _pr_bare _pr_want _pr_actual _pr_dep_list
    typeset -i _pr_ndeps _pr_di
    for _pr_name in "${!_pr_deps[@]}"; do
        [[ -z "${PACK_CONFIGS[$_pr_name]+set}" ]] && continue
        _pr_ndeps=${#PACK_CONFIGS[$_pr_name].depends[@]}
        (( _pr_ndeps == 0 )) && continue

        _pr_dep_list=""
        for (( _pr_di = 0; _pr_di < _pr_ndeps; _pr_di++ )); do
            _pr_dep="${PACK_CONFIGS[$_pr_name].depends[_pr_di]}"

            # Version constraint: depends=(foo@v1.0) → bare=foo, want=v1.0
            _pr_bare="$_pr_dep"
            _pr_want=""
            if [[ "$_pr_dep" == *'@'* ]]; then
                _pr_bare="${_pr_dep%%'@'*}"
                _pr_want="${_pr_dep#*'@'}"
                if [[ -n "${PACK_REGISTRY[$_pr_bare]+set}" && -n "$_pr_want" ]]; then
                    _pr_actual="${PACK_REGISTRY[$_pr_bare].tag:-}"
                    if [[ "$_pr_actual" != "$_pr_want" ]]; then
                        print -u2 "pack: ${_pr_name} depends on ${_pr_dep} but ${_pr_bare} is declared with tag=${_pr_actual}"
                    fi
                fi
                _pr_dep="$_pr_bare"
            fi

            # Only include deps that are declared, non-disabled packages
            if [[ -z "${_pr_deps[$_pr_dep]+set}" ]]; then
                print -u2 "pack: warning: ${_pr_name} depends on '${_pr_dep}' which is not declared"
                continue
            fi

            _pr_dep_list+="${_pr_dep_list:+ }$_pr_dep"
        done
        _pr_deps[$_pr_name]="$_pr_dep_list"
    done

    # Delegate to func.ksh toposort
    Result_t _pr_result
    toposort _pr_result _pr_deps
    if _pr_result.is_err; then
        print -u2 "pack: ${_pr_result.error}"
        return 1
    fi

    # Convert space-separated result to array
    # Glob-safe: pack() rejects names with glob chars at declaration time
    PACK_ORDER=( ${_pr_result.value} )
}
