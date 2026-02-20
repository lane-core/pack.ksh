# pack.ksh — Git operations for package management
# Sourced by pack.ksh at startup; not intended for standalone execution.
#
# Each fallible function creates its own internal Result_t and uses
# try_cmd at 1-level depth (required for ksh93u+m nameref scoping).
# Returns 0 on success, 1 on failure with REPLY holding the error message.

# ── Clone ──────────────────────────────────────────────────────────────
# Usage: _pack_git_clone url dest [branch] [tag] [commit]
# Sets REPLY to error message on failure.
function _pack_git_clone {
    typeset _pgc_url="$1" _pgc_dest="$2" _pgc_branch="${3:-}" _pgc_tag="${4:-}" _pgc_commit="${5:-}"

    [[ -d "$_pgc_dest" ]] && return 0

    Result_t _pgc_r

    # Commit checkouts require full history (can't shallow-clone to arbitrary SHA)
    if [[ -n "$_pgc_commit" ]]; then
        try_cmd _pgc_r command git clone -- "$_pgc_url" "$_pgc_dest"
        if _pgc_r.is_err; then
            REPLY="clone failed: ${_pgc_r.error}"
            return 1
        fi
        try_cmd _pgc_r command git -C "$_pgc_dest" checkout "$_pgc_commit"
        if _pgc_r.is_err; then
            REPLY="checkout ${_pgc_commit} failed: ${_pgc_r.error}"
            return 1
        fi
        return 0
    fi

    # Determine ref for --branch (tag takes precedence over branch)
    typeset _pgc_ref="${_pgc_tag:-$_pgc_branch}"

    if [[ -n "$_pgc_ref" ]]; then
        try_cmd _pgc_r command git clone --depth 1 --branch "$_pgc_ref" --single-branch \
            -- "$_pgc_url" "$_pgc_dest"
        if _pgc_r.is_ok; then
            return 0
        fi
        # Ref may not exist — clean up partial clone and fall through to retry
        if [[ -d "$_pgc_dest" ]]; then
            if [[ -n "${PACK_PACKAGES:-}" && "$_pgc_dest" == "${PACK_PACKAGES}/"* ]]; then
                command rm -rf "$_pgc_dest" || {
                    REPLY="clone failed: could not clean up partial clone at $_pgc_dest"
                    return 1
                }
            else
                REPLY="clone failed: partial clone at $_pgc_dest (not under PACK_PACKAGES, refusing to remove)"
                return 1
            fi
        fi
    fi

    # Shallow clone using remote's default branch
    try_cmd _pgc_r command git clone --depth 1 --single-branch -- "$_pgc_url" "$_pgc_dest"
    if _pgc_r.is_err; then
        REPLY="clone failed: ${_pgc_r.error}"
        return 1
    fi
    return 0
}

# ── Update ─────────────────────────────────────────────────────────────
# Usage: _pack_git_update dest [ref]
# Sets REPLY to error message on failure.
function _pack_git_update {
    typeset _pgu_dest="$1" _pgu_ref="${2:-}"

    if [[ ! -d "${_pgu_dest}/.git" ]]; then
        REPLY="not a git repository: ${_pgu_dest}"
        return 1
    fi

    # Fall back to current branch when no ref given
    if [[ -z "$_pgu_ref" ]]; then
        _pgu_ref=$(command git -C "$_pgu_dest" branch --show-current 2>/dev/null)
        [[ -z "$_pgu_ref" ]] && _pgu_ref="HEAD"
    fi

    Result_t _pgu_r

    try_cmd _pgu_r command git -C "$_pgu_dest" fetch --depth 1 origin "$_pgu_ref"
    if _pgu_r.is_err; then
        REPLY="fetch failed: ${_pgu_r.error}"
        return 1
    fi

    try_cmd _pgu_r command git -C "$_pgu_dest" reset --hard FETCH_HEAD
    if _pgu_r.is_err; then
        REPLY="reset failed: ${_pgu_r.error}"
        return 1
    fi

    return 0
}

# ── Commit Hashes ──────────────────────────────────────────────────────
# Sets REPLY — no subshell needed by callers.

function _pack_git_head {
    Result_t _pgh_r
    try_cmd _pgh_r command git -C "$1" rev-parse --short HEAD
    REPLY="${_pgh_r.value}"
    _pgh_r.is_ok
}

function _pack_git_full_head {
    Result_t _pgfh_r
    try_cmd _pgfh_r command git -C "$1" rev-parse HEAD
    REPLY="${_pgfh_r.value}"
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
