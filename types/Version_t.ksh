# Version_t — semantic version with comparison
#
# Parses and validates semver strings (MAJOR.MINOR.PATCH with optional
# pre-release suffix). Provides ordering via the cmp method.

typeset -T Version_t=(
    typeset raw=''
    typeset -i major=0
    typeset -i minor=0
    typeset -i patch=0
    typeset pre=''

    function create {
        [[ -n ${1:-} ]] || return 0
        _.raw=$1
    }

    # Parse and validate on assignment to .raw
    function raw.set {
        typeset v=${.sh.value}

        if [[ -z $v ]]; then
            _.major=0 _.minor=0 _.patch=0 _.pre=''
            return 0
        fi

        # Match MAJOR.MINOR.PATCH[-prerelease]
        typeset base=${v%%-*}
        if [[ $v == *-* ]]; then
            _.pre=${v#*-}
        else
            _.pre=''
        fi

        # Validate numeric components
        typeset IFS=.
        set -- $base
        if (( $# < 2 || $# > 3 )); then
            print -u2 "Version_t: invalid version '$v' (need MAJOR.MINOR[.PATCH])"
            .sh.value=${_.raw}
            return 1
        fi

        typeset part
        for part; do
            if [[ $part != +([0-9]) ]]; then
                print -u2 "Version_t: non-numeric component '$part' in '$v'"
                .sh.value=${_.raw}
                return 1
            fi
        done

        _.major=$1
        _.minor=$2
        _.patch=${3:-0}
    }

    # Compare to another Version_t variable name
    # Returns via print: -1, 0, or 1
    function cmp {
        typeset -n _other=$1
        if (( _.major != _other.major )); then
            (( _.major > _other.major )) && print 1 || print -- -1
        elif (( _.minor != _other.minor )); then
            (( _.minor > _other.minor )) && print 1 || print -- -1
        elif (( _.patch != _other.patch )); then
            (( _.patch > _other.patch )) && print 1 || print -- -1
        else
            # Pre-release sorts before release (1.0.0-alpha < 1.0.0)
            if [[ -n ${_.pre} && -z ${_other.pre} ]]; then
                print -- -1
            elif [[ -z ${_.pre} && -n ${_other.pre} ]]; then
                print 1
            else
                # Per semver: split pre-release on '.', compare each
                # identifier. Numeric ids sort numerically; alphanumeric
                # ids sort lexicographically; numeric < alphanumeric.
                typeset _IFS=$IFS
                IFS=.
                set -A _pre_a -- ${_.pre}
                set -A _pre_b -- ${_other.pre}
                IFS=$_IFS
                typeset -i _pi _pn
                (( _pn = ${#_pre_a[@]} < ${#_pre_b[@]} ? ${#_pre_a[@]} : ${#_pre_b[@]} ))
                typeset _pa _pb _result=0
                for (( _pi=0; _pi < _pn; _pi++ )); do
                    _pa=${_pre_a[_pi]}
                    _pb=${_pre_b[_pi]}
                    if [[ $_pa == +([0-9]) && $_pb == +([0-9]) ]]; then
                        # Both numeric: compare as integers
                        if (( _pa < _pb )); then _result=-1; break; fi
                        if (( _pa > _pb )); then _result=1; break; fi
                    elif [[ $_pa == +([0-9]) ]]; then
                        _result=-1; break  # numeric < alphanumeric
                    elif [[ $_pb == +([0-9]) ]]; then
                        _result=1; break
                    else
                        # Both alphanumeric: lexicographic
                        if [[ $_pa < $_pb ]]; then _result=-1; break; fi
                        if [[ $_pa > $_pb ]]; then _result=1; break; fi
                    fi
                done
                if (( _result == 0 )); then
                    # Shorter pre-release sorts before longer
                    if (( ${#_pre_a[@]} < ${#_pre_b[@]} )); then _result=-1
                    elif (( ${#_pre_a[@]} > ${#_pre_b[@]} )); then _result=1
                    fi
                fi
                print -- $_result
            fi
        fi
    }

    # Predicate: is this version less than $1?
    # Fast-path for major/minor/patch; subshell only for pre-release tiebreaker
    function lt {
        typeset -n _other=$1
        if (( _.major != _other.major )); then
            (( _.major < _other.major )); return
        fi
        if (( _.minor != _other.minor )); then
            (( _.minor < _other.minor )); return
        fi
        if (( _.patch != _other.patch )); then
            (( _.patch < _other.patch )); return
        fi
        # Same major.minor.patch — need pre-release comparison
        [[ $(_.cmp "$1") == -1 ]]
    }

    # Predicate: is this version greater than $1?
    function gt {
        typeset -n _other=$1
        if (( _.major != _other.major )); then
            (( _.major > _other.major )); return
        fi
        if (( _.minor != _other.minor )); then
            (( _.minor > _other.minor )); return
        fi
        if (( _.patch != _other.patch )); then
            (( _.patch > _other.patch )); return
        fi
        [[ $(_.cmp "$1") == 1 ]]
    }

    # Predicate: is this version equal to $1? (no subshell needed)
    function eq {
        typeset -n _other=$1
        (( _.major == _other.major && _.minor == _other.minor && _.patch == _other.patch )) &&
        [[ ${_.pre} == "${_other.pre}" ]]
    }

    function get {
        if [[ -n ${_.pre} ]]; then
            .sh.value="${_.major}.${_.minor}.${_.patch}-${_.pre}"
        else
            .sh.value="${_.major}.${_.minor}.${_.patch}"
        fi
    }
)
