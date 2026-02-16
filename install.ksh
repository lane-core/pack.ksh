#!/bin/ksh
# install.ksh — Bootstrap installer for pack.ksh
#
# Generates a starter config and wires a lazy-bootstrap snippet into
# .kshrc that clones pack.ksh on first launch if missing. Idempotent.

set -o nounset

# ── ksh93 Detection ──────────────────────────────────────────────────────────
typeset version="${.sh.version:-}"
if [[ -z "$version" || "$version" != *93* ]]; then
	print -u2 "pack.ksh requires ksh93 (found: ${version:-not ksh93})"
	print -u2 "Install ksh93u+m: https://github.com/ksh93/ksh93"
	exit 1
fi

# ── Source Directory ─────────────────────────────────────────────────────────
typeset src_dir="${.sh.file%/*}"
[[ -f "$src_dir/pack.ksh" ]] || {
	print -u2 "install: cannot find pack.ksh in $src_dir"
	exit 1
}

typeset origin_url
origin_url=$(command git -C "$src_dir" remote get-url origin 2>/dev/null)
[[ -z "$origin_url" ]] && origin_url="https://github.com/USER/REPO"

# ── Parse Flags ──────────────────────────────────────────────────────────────
typeset auto_confirm=false
for arg in "$@"; do
	case "$arg" in
		-y|--yes) auto_confirm=true ;;
		-h|--help)
			print "Usage: ksh install.ksh [-y|--yes]"
			print "  -y  Auto-confirm .kshrc modification"
			exit 0
			;;
		*) print -u2 "install: unknown option: $arg"; exit 1 ;;
	esac
done

# ── XDG Paths ────────────────────────────────────────────────────────────────
typeset config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/ksh"
command mkdir -p "$config_dir"

# ── Generate Default Config ──────────────────────────────────────────────────
typeset config_file="$config_dir/pack.ksh"
if [[ ! -f "$config_file" ]]; then
	print "Creating starter config at $config_file ..."
	print '# pack.ksh — Package declarations
# Add your packages here. Run `pack install` after editing.
#
# Examples:
#   pack "user/repo" fpath=functions
#   pack "user/repo" branch=dev tag=v1.0 build="make"
#   pack "$HOME/dev/plugin" local=true
#   pack "tool" depends=(dep1 dep2)' > "$config_file"
else
	print "Config already exists: $config_file (not overwritten)"
fi

# ── Bootstrap Snippet ────────────────────────────────────────────────────────
typeset snippet="# ── pack.ksh ──────────────────────────────────────────────────────────
typeset PACK_ROOT=\"\${XDG_DATA_HOME:-\$HOME/.local/share}/ksh/pack\"
if [[ ! -f \"\$PACK_ROOT/pack.ksh\" ]]; then
    command git clone --depth 1 ${origin_url} \"\$PACK_ROOT\"
fi
. \"\$PACK_ROOT/pack.ksh\""

typeset kshrc="$HOME/.kshrc"
typeset do_write=false

if [[ -f "$kshrc" ]] && [[ "$(< "$kshrc")" == *"pack.ksh"* ]]; then
	print "Bootstrap snippet already present in $kshrc"
elif [[ "$auto_confirm" == true ]]; then
	do_write=true
elif [[ -f "$kshrc" ]]; then
	print ""; print "Add this to your .kshrc:"; print ""
	print "$snippet"; print ""
	print -n "Append to $kshrc now? [y/N] "
	typeset answer; read -r answer
	[[ "$answer" == [yY]* ]] && do_write=true \
		|| print "Skipped — add the snippet manually when ready."
else
	do_write=true
fi

if [[ "$do_write" == true ]]; then
	if [[ -f "$kshrc" ]]; then
		print "" >> "$kshrc"
		print "$snippet" >> "$kshrc"
		print "Appended bootstrap snippet to $kshrc"
	else
		print "$snippet" > "$kshrc"
		print "Created $kshrc with bootstrap snippet"
	fi
fi

print ""
print "pack.ksh installed successfully!"
print "Open a new shell or run: . ~/.kshrc"
