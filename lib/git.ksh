# pack.ksh — Git operations for package management
# Sourced by pack.ksh at startup; not intended for standalone execution.
#
# Fallible functions follow a Result_t calling convention:
# Result_t name as $1, always return 0 (errors go in the Result_t).
# Each function keeps a local Result_t for try_cmd calls (try_cmd needs
# the nameref target within 1 scope level for compound types in ksh93u+m).
# Results transfer to the caller's Result_t via a 1-level nameref.

# ── Clone ──────────────────────────────────────────────────────────────
# Usage: _pack_git_clone result url dest [branch] [tag] [commit]
# On success: .ok holds dest path. On error: .err holds context message.
function _pack_git_clone {
    typeset -n _pgc_r=$1; shift
    typeset _pgc_url="$1" _pgc_dest="$2" _pgc_branch="${3:-}" _pgc_tag="${4:-}" _pgc_commit="${5:-}"

    [[ -d "$_pgc_dest" ]] && { _pgc_r.ok "$_pgc_dest"; return 0; }

    Result_t _pgc_tmp

    # Commit checkouts require full history (can't shallow-clone to arbitrary SHA)
    if [[ -n "$_pgc_commit" ]]; then
        try_cmd _pgc_tmp command git clone -- "$_pgc_url" "$_pgc_dest"
        if _pgc_tmp.is_err; then
            _pgc_r.err "clone failed: ${_pgc_tmp.error}" ${_pgc_tmp.code}
            return 0
        fi
        _pgc_tmp.reset
        try_cmd _pgc_tmp command git -C "$_pgc_dest" checkout "$_pgc_commit"
        if _pgc_tmp.is_err; then
            _pgc_r.err "checkout ${_pgc_commit} failed: ${_pgc_tmp.error}" ${_pgc_tmp.code}
            return 0
        fi
        _pgc_r.ok "$_pgc_dest"
        return 0
    fi

    # Determine ref for --branch (tag takes precedence over branch)
    typeset _pgc_ref="${_pgc_tag:-$_pgc_branch}"

    if [[ -n "$_pgc_ref" ]]; then
        try_cmd _pgc_tmp command git clone --depth 1 --branch "$_pgc_ref" --single-branch \
            -- "$_pgc_url" "$_pgc_dest"
        if _pgc_tmp.is_ok; then
            _pgc_r.ok "$_pgc_dest"
            return 0
        fi
        # Ref may not exist — clean up partial clone and fall through to default branch
        _pgc_tmp.reset
        if [[ -d "$_pgc_dest" ]]; then
            if [[ -n "${PACK_PACKAGES:-}" && "$_pgc_dest" == "${PACK_PACKAGES}/"* ]]; then
                command rm -rf "$_pgc_dest" || {
                    _pgc_r.err "clone failed: could not clean up partial clone at $_pgc_dest"
                    return 0
                }
            else
                _pgc_r.err "clone failed: partial clone at $_pgc_dest (not under PACK_PACKAGES, refusing to remove)"
                return 0
            fi
        fi
    fi

    # Shallow clone using remote's default branch
    try_cmd _pgc_tmp command git clone --depth 1 --single-branch -- "$_pgc_url" "$_pgc_dest"
    if _pgc_tmp.is_ok; then
        _pgc_r.ok "$_pgc_dest"
    else
        _pgc_r.err "clone failed: ${_pgc_tmp.error}" ${_pgc_tmp.code}
    fi
    return 0
}

# ── Update ─────────────────────────────────────────────────────────────
# Usage: _pack_git_update result dest [ref]
function _pack_git_update {
    typeset -n _pgu_r=$1; shift
    typeset _pgu_dest="$1" _pgu_ref="${2:-}"

    if [[ ! -d "${_pgu_dest}/.git" ]]; then
        _pgu_r.err "not a git repository: ${_pgu_dest}"
        return 0
    fi

    # Fall back to current branch when no ref given
    if [[ -z "$_pgu_ref" ]]; then
        _pgu_ref=$(command git -C "$_pgu_dest" branch --show-current 2>/dev/null)
        [[ -z "$_pgu_ref" ]] && _pgu_ref="HEAD"
    fi

    Result_t _pgu_tmp

    try_cmd _pgu_tmp command git -C "$_pgu_dest" fetch --depth 1 origin "$_pgu_ref"
    if _pgu_tmp.is_err; then
        _pgu_r.err "fetch failed: ${_pgu_tmp.error}" ${_pgu_tmp.code}
        return 0
    fi

    _pgu_tmp.reset
    try_cmd _pgu_tmp command git -C "$_pgu_dest" reset --hard FETCH_HEAD
    if _pgu_tmp.is_err; then
        _pgu_r.err "reset failed: ${_pgu_tmp.error}" ${_pgu_tmp.code}
        return 0
    fi

    _pgu_r.ok ""
    return 0
}

# ── Commit Hashes ──────────────────────────────────────────────────────
# Sets REPLY — no subshell needed by callers.

function _pack_git_head {
    Result_t _pgh_r
    try_cmd _pgh_r command git -C "$1" rev-parse --short HEAD
    _pgh_r.value_into REPLY ""
    _pgh_r.is_ok
}

function _pack_git_full_head {
    Result_t _pgfh_r
    try_cmd _pgfh_r command git -C "$1" rev-parse HEAD
    _pgfh_r.value_into REPLY ""
    _pgfh_r.is_ok
}

# ── Remote HEAD ────────────────────────────────────────────────────────
# Check remote commit without cloning.
# Usage: _pack_git_remote_head url [ref]
function _pack_git_remote_head {
    typeset _pgrh_url="$1" _pgrh_ref="${2:-HEAD}"
    typeset _pgrh_line

    _pgrh_line=$(command git ls-remote -- "$_pgrh_url" "$_pgrh_ref" 2>/dev/null) || {
        REPLY=""
        return 1
    }

    # ls-remote output: <hash>\t<refname>
    REPLY="${_pgrh_line%%[$'\t ']*}"
    [[ -n "$REPLY" ]]
}

# ── URL Detection ──────────────────────────────────────────────────────
# Returns 0 if the string looks like a git-cloneable source.
function _pack_git_is_url {
    typeset str="$1"

    # Explicit protocol schemes
    [[ "$str" == https://* || "$str" == http://* || \
       "$str" == git://*   || "$str" == git@*    ]] && return 0

    # GitHub-style shorthand: user/repo (contains slash, doesn't start with / or ~)
    [[ "$str" == */* && "$str" != /* && "$str" != '~'* && "$str" != './'* && "$str" != '../'* ]] && return 0

    return 1
}
