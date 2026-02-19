# pack.ksh — Git operations for package management
# Sourced by pack.ksh at startup; not intended for standalone execution.

# ── Clone ──────────────────────────────────────────────────────────────
# Usage: _pack_git_clone url dest [branch] [tag] [commit]
function _pack_git_clone {
    typeset url="$1" dest="$2" branch="$3" tag="$4" commit="$5"
    typeset out rc

    [[ -d "$dest" ]] && return 0

    # Commit checkouts require full history (can't shallow-clone to arbitrary SHA)
    if [[ -n "$commit" ]]; then
        out=$(command git clone -- "$url" "$dest" 2>&1)
        rc=$?
        if (( rc != 0 )); then
            _pack_err $rc cmd "clone failed: ${out}" git-clone
            return 1
        fi
        out=$(command git -C "$dest" checkout "$commit" 2>&1)
        rc=$?
        if (( rc != 0 )); then
            _pack_err $rc cmd "checkout ${commit} failed: ${out}" git-checkout
            return 1
        fi
        return 0
    fi

    # Determine ref for --branch (tag takes precedence over branch)
    typeset ref="${tag:-$branch}"

    if [[ -n "$ref" ]]; then
        out=$(command git clone --depth 1 --branch "$ref" --single-branch \
            -- "$url" "$dest" 2>&1)
        rc=$?
        if (( rc == 0 )); then
            return 0
        fi
        # Ref may not exist — clean up partial clone and fall through to retry
        [[ -n "$PACK_PACKAGES" && "$dest" == "${PACK_PACKAGES}/"* ]] && command rm -rf "$dest" 2>/dev/null
    fi

    # Shallow clone using remote's default branch
    out=$(command git clone --depth 1 --single-branch -- "$url" "$dest" 2>&1)
    rc=$?
    if (( rc != 0 )); then
        _pack_err $rc cmd "clone failed: ${out}" git-clone
        return 1
    fi
    return 0
}

# ── Update ─────────────────────────────────────────────────────────────
# Usage: _pack_git_update dest [ref]
function _pack_git_update {
    typeset dest="$1" ref="$2"
    typeset out rc

    if [[ ! -d "${dest}/.git" ]]; then
        _pack_err 1 io "not a git repository: ${dest}" git-update
        return 1
    fi

    # Fall back to current branch when no ref given
    if [[ -z "$ref" ]]; then
        ref=$(command git -C "$dest" branch --show-current 2>/dev/null)
        [[ -z "$ref" ]] && ref="HEAD"
    fi

    out=$(command git -C "$dest" fetch --depth 1 origin "$ref" 2>&1)
    rc=$?
    if (( rc != 0 )); then
        _pack_err $rc cmd "fetch failed: ${out}" git-fetch
        return 1
    fi

    out=$(command git -C "$dest" reset --hard FETCH_HEAD 2>&1)
    rc=$?
    if (( rc != 0 )); then
        _pack_err $rc cmd "reset failed: ${out}" git-reset
        return 1
    fi

    return 0
}

# ── Commit Hashes ──────────────────────────────────────────────────────
# Sets REPLY — no subshell needed by callers.

function _pack_git_head {
    REPLY=$(command git -C "$1" rev-parse --short HEAD 2>/dev/null) || { REPLY=""; return 1; }
}

function _pack_git_full_head {
    REPLY=$(command git -C "$1" rev-parse HEAD 2>/dev/null) || { REPLY=""; return 1; }
}

# ── Remote HEAD ────────────────────────────────────────────────────────
# Check remote commit without cloning.
# Usage: _pack_git_remote_head url [ref]
function _pack_git_remote_head {
    typeset url="$1" ref="${2:-HEAD}"
    typeset line

    line=$(command git ls-remote -- "$url" "$ref" 2>/dev/null) || {
        REPLY=""
        return 1
    }

    # ls-remote output: <hash>\t<refname>
    REPLY="${line%%[$'\t ']*}"
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
