# pack.ksh

A declarative package manager for ksh93u+m. Nix-inspired, self-bootstrapping — pack.ksh is the kernel, everything else is a package.

## Agent Delegation

**All shell scripting tasks MUST be delegated to the `ksh93-script-engineer` agent.** This includes:

- Writing new ksh93 library files or plugins
- Reviewing or debugging existing shell code
- Designing plugin architecture or interfaces
- Answering questions about ksh93 features, POSIX portability, or shell dialect differences
- Any code that will live in a `.ksh` file

Non-shell tasks (documentation, git operations, CI configuration) do not need delegation.

## Project Structure

```
pack.ksh              # Core: declaration parser, registry, field appliers
load.ksh              # Global-scope loader (sourced, not called)
install.ksh           # Self-bootstrap script
lib/                  # Internal helpers
  git.ksh             # Git operations (clone, update, shallow)
  resolve.ksh         # Dependency resolution (Kahn's algorithm)
  lock.ksh            # Lockfile read/write (freeze/restore)
  config.ksh          # djb-style filesystem config reader
  hooks.ksh           # Event hook system (pre/post install, load, resolve)
functions/            # Helper libraries sourced on demand
  pack                # CLI helpers (sourced by pack() on first CLI invocation)
test/
  verify.ksh          # End-to-end verification tests
```

## Architecture

- **Plugin registry**: `PACK_REGISTRY` associative array maps names to `;`-delimited key=value specs
- **Config store**: `PACK_CONFIGS` stores declarative fields (fpath, path, alias, env, rc, depends, build)
- **Dependency resolution**: Kahn's algorithm topological sort on `depends` fields with cycle detection
- **Loading**: `load.ksh` is sourced at global scope (critical ksh93 constraint — `typeset` inside functions creates local scope)
- **XDG compliance**: Data in `$XDG_DATA_HOME/ksh/pack`, config in `$XDG_CONFIG_HOME/ksh`

### Data Structures

```ksh
typeset -A PACK_REGISTRY    # name -> ";"-delimited key=value metadata
typeset -A PACK_CONFIGS     # name -> serialized declarative fields
typeset -A PACK_STATE       # name -> "commit:timestamp"
typeset -A PACK_LOADED      # name -> 1
typeset -a PACK_ORDER       # resolved load order (topological sort result)
```

### Registry Format

Fields are `;`-delimited, extracted via `;`-anchored pattern matching to prevent substring false-matches (e.g., `path` inside `fpath`):

```ksh
# Extraction pattern (prepend ; to anchor):
typeset meta=";${PACK_REGISTRY[$name]}"
typeset v="${meta#*";field="}"; v="${v%%;*}"
```

### Package Lifecycle

```
declare  ->  resolve  ->  install  ->  load  ->  [update/pin/remove]
  pack()   _pack_resolve  pack install  load.ksh  pack update/remove
```

### Directory Layout (XDG-compliant)

```
$XDG_DATA_HOME/ksh/pack/          # PACK_ROOT
  pack.ksh                         # The package manager itself
  lib/                             # Internal helpers
  functions/                       # Autoloaded functions
  packages/                        # Installed packages
  state/
    pack.lock                      # Lockfile (pinned versions)
  cache/                           # Git clone cache

$XDG_CONFIG_HOME/ksh/
  pack.ksh                         # User's package declarations
  packages/                        # djb-style filesystem config
  pkgs.d/*.ksh                     # Aggregation scripts
```

## Code Conventions

- **ksh93 idioms**: `print` over `echo`, `typeset` over `local`/`declare`, `nameref` over `eval`-based indirection
- **Function naming**: Public API `pack_verb`, Internal `_pack_verb` (underscore prefix = private)
- **Variable naming**: Globals `PACK_UPPER_SNAKE`, locals `typeset lowercase`
- **Performance**: Minimize forks, set `REPLY` instead of printing, `command git` to avoid aliases
- **Error handling**: Check return codes, `print -u2` for errors
- **Quoting**: Quote all variable expansions, `[[ ]]` for conditionals, `(( ))` for arithmetic
- **Comments**: Section headers `# -- Section Name ------` banner style. Inline comments explain *why*, not *what*
- **No external dependencies**: ksh93 builtins only (except `git`)

## Package Authoring

A package lives in a directory with at minimum an entry point file:

```
my-package/
  init.ksh             # Entry point (preferred)
  plugin.ksh           # Alternative entry point (micro.ksh compat)
  functions/           # Optional: autoloaded functions (added to FPATH)
```

Entry point search order: `init.ksh` -> `plugin.ksh` -> `${name}.ksh`
