# toposort — topological sort on a dependency graph
#
# Input: an associative array variable name where keys are node names
# and values are space-separated dependency lists (duplicates tolerated).
# Output: ordered node list in Result_t .value (space-separated),
# or error if a cycle is detected.
#
# Uses Kahn's algorithm (BFS). Cycle detection is inherent: if the
# sorted output has fewer nodes than the input, a cycle exists.
#
# Usage:
#   typeset -A deps=(
#       [app]="lib utils"
#       [lib]="core"
#       [utils]="core"
#       [core]=""
#   )
#   Result_t r
#   toposort r deps
#   # r.value == "core lib utils app" (or "core utils lib app")

function toposort {
    typeset -n _ts_r=$1
    typeset -n _ts_graph=$2

    typeset -A _ts_indegree
    typeset -A _ts_seen
    # Reverse adjacency: _ts_rdeps[dep] = "node1 node2 ..." (who depends on dep)
    typeset -A _ts_rdeps
    typeset _ts_node _ts_dep

    # First pass: deduplicate deps, compute in-degrees, build reverse map
    for _ts_node in "${!_ts_graph[@]}"; do
        _ts_seen[$_ts_node]=1
        [[ -n ${_ts_indegree[$_ts_node]:-} ]] || _ts_indegree[$_ts_node]=0
        typeset -A _ts_dedup=()
        for _ts_dep in ${_ts_graph[$_ts_node]}; do
            [[ -n ${_ts_dedup[$_ts_dep]:-} ]] && continue
            _ts_dedup[$_ts_dep]=1
            _ts_seen[$_ts_dep]=1
            [[ -n ${_ts_indegree[$_ts_dep]:-} ]] || _ts_indegree[$_ts_dep]=0
            _ts_indegree[$_ts_node]=$(( ${_ts_indegree[$_ts_node]} + 1 ))
            # Build reverse edge: dep is needed by node
            _ts_rdeps[$_ts_dep]="${_ts_rdeps[$_ts_dep]:-} $_ts_node"
        done
        unset _ts_dedup
    done

    # Ensure dependency-only nodes have an in-degree entry
    for _ts_node in "${!_ts_seen[@]}"; do
        [[ -n ${_ts_indegree[$_ts_node]:-} ]] || _ts_indegree[$_ts_node]=0
    done

    # Collect and sort all nodes for deterministic output
    typeset -a _ts_queue=()
    typeset -a _ts_all_nodes=()
    for _ts_node in "${!_ts_seen[@]}"; do
        _ts_all_nodes+=("$_ts_node")
    done

    typeset -i _ts_i _ts_j _ts_n=${#_ts_all_nodes[@]}
    typeset _ts_tmp
    for (( _ts_i=0; _ts_i < _ts_n - 1; _ts_i++ )); do
        for (( _ts_j=_ts_i+1; _ts_j < _ts_n; _ts_j++ )); do
            if [[ ${_ts_all_nodes[_ts_j]} < ${_ts_all_nodes[_ts_i]} ]]; then
                _ts_tmp=${_ts_all_nodes[_ts_i]}
                _ts_all_nodes[_ts_i]=${_ts_all_nodes[_ts_j]}
                _ts_all_nodes[_ts_j]=$_ts_tmp
            fi
        done
    done

    for _ts_node in "${_ts_all_nodes[@]}"; do
        (( ${_ts_indegree[$_ts_node]} == 0 )) && _ts_queue+=("$_ts_node")
    done

    # BFS using reverse adjacency map — O(V + E) instead of O(V²E)
    typeset -a _ts_order=()
    typeset -i _ts_front=0

    while (( _ts_front < ${#_ts_queue[@]} )); do
        _ts_node=${_ts_queue[_ts_front]}
        (( _ts_front++ ))
        _ts_order+=("$_ts_node")

        # Decrement in-degree of every node that depends on _ts_node
        for _ts_dep in ${_ts_rdeps[$_ts_node]:-}; do
            _ts_indegree[$_ts_dep]=$(( ${_ts_indegree[$_ts_dep]} - 1 ))
            if (( ${_ts_indegree[$_ts_dep]} == 0 )); then
                _ts_queue+=("$_ts_dep")
            fi
        done
    done

    # Cycle detection
    if (( ${#_ts_order[@]} < _ts_n )); then
        typeset _ts_cycle_nodes=''
        for _ts_node in "${_ts_all_nodes[@]}"; do
            if (( ${_ts_indegree[$_ts_node]} > 0 )); then
                _ts_cycle_nodes+="${_ts_cycle_nodes:+ }$_ts_node"
            fi
        done
        _ts_r.err "toposort: cycle detected involving: $_ts_cycle_nodes" 1
        return 0
    fi

    _ts_r.ok "${_ts_order[*]}"
    return 0
}
