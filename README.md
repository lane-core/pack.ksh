# pack.ksh

A declarative package manager for [ksh93u+m](https://github.com/ksh93/ksh). Nix-inspired, self-bootstrapping, XDG-compliant.

Declare packages in your config, and pack handles cloning, dependency resolution (topological sort), loading, and version pinning.

## Requirements

- [ksh93u+m](https://github.com/ksh93/ksh)
- git

## Install

```ksh
git clone https://github.com/USER/pack.ksh ~/.local/share/ksh/pack
ksh ~/.local/share/ksh/pack/install.ksh
```

Or bootstrap from `.kshrc`:

```ksh
typeset PACK_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}/ksh/pack"
if [[ ! -f "$PACK_ROOT/pack.ksh" ]]; then
    command git clone --depth 1 https://github.com/USER/pack.ksh "$PACK_ROOT"
fi
. "$PACK_ROOT/pack.ksh"
```

## Quick Start

Declare packages in `~/.config/ksh/pack.ksh`:

```ksh
pack "lkrms/readlinkf" fpath=functions
pack "user/some-tool" branch=main path=bin build="make"
pack "$HOME/dev/my-plugin" fpath=functions
pack "$HOME/dev/my-plugin" url=user/my-plugin fpath=functions  # local + remote updates
```

Then install:

```
$ pack install
```

## Commands

| Command | Description |
|---------------------|-----------------------------------------------|
| `pack install [name]` | Install declared packages (all if no name) |
| `pack update [name]` | Pull latest from git |
| `pack remove <name>` | Remove a package |
| `pack list` | Show all packages and their status |
| `pack freeze` | Write lockfile (pin current commits) |
| `pack restore` | Install from lockfile |
| `pack info <name>` | Show package details |
| `pack run [--pkg name] <cmd>` | Run command with package's PATH |
| `pack diff` | Show changes since last freeze |
| `pack self-update` | Update pack.ksh itself |

## Package Declaration

```ksh
pack "<source>" [field=value ...]
```

| Field | Type | Description |
|-----------|---------|----------------------------------------------|
| as | string | Override derived package name |
| branch | string | Git branch to track |
| tag | string | Git tag to pin |
| commit | string | Git commit to pin |
| url | string | Remote URL for a local package (enables update) |
| local | bool | Treat source as a local path (auto-inferred from `/` paths) |
| load | string | `now` (source on startup), `lazy` (default), `manual` |
| build | string | Shell command to run after install/update |
| disabled | bool | Register but don't install or load |
| source | string | Override entry point filename |
| fpath | array | Directories to add to FPATH and autoload |
| path | array | Directories to prepend to PATH |
| alias | array | Aliases to define (`name=value`) |
| env | array | Environment variables to export (`KEY=value`) |
| depends | array | Package names that must load first |
| rc | string | Shell code evaluated after loading |

Source shorthand: `user/repo` expands to GitHub, `gl:user/repo` to GitLab, `bb:user/repo` to Bitbucket. Full URLs and local paths work as-is.

## Configuration Formats

**Script** (`~/.config/ksh/pack.ksh`): Standard ksh with `pack()` calls. This is the default.

**Filesystem** (`~/.config/ksh/packages/<name>/`): One directory per package, one file per field. Inspired by djb's daemontools.

```
~/.config/ksh/packages/readlinkf/
  source        # contains "lkrms/readlinkf"
  fpath/
    functions   # empty file — dirname is the value
```

Both formats produce identical internal state and can be mixed freely.

## Package Authoring

A package lives in a directory with an entry point:

```
my-package/
  init.ksh             # Entry point (preferred)
  plugin.ksh           # Alternative entry point
  functions/           # Optional: autoloaded functions (added to FPATH)
```

Entry point search order: `init.ksh` -> `plugin.ksh` -> `${name}.ksh`

## Security

The `rc=` and `build=` fields execute arbitrary shell code. `rc=` runs every time a package loads; `build=` runs after install and update. Only install packages you trust. Same trust model as every other shell plugin manager.

## License

MIT
