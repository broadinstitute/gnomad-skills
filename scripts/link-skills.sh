#!/bin/sh
# Link every skill in this repo into ~/.claude/skills, so Claude Code sees
# them in every project, and every hook (hooks/gnomad-*.sh) into
# ~/.claude/hooks, where a repo's .claude/settings.json can turn it on. Each
# entry is a symlink into this checkout, so a `git pull` is all it takes to
# update them. Re-run after adding, removing or renaming a skill or hook.
# Linking a hook doesn't turn it on; see README.md, "Turn on gnomad-guard in a
# repo".
#
# The script only replaces symlinks it made (or dangling ones): a skill or
# hook you installed by hand, cloned (such as /review) or linked from your own
# copy is left alone and reported.

set -eu

repo=$(cd "$(dirname "$0")/.." && pwd -P)
dest="$HOME/.claude/skills"
hooks_dest="$HOME/.claude/hooks"
status=0

mkdir -p "$dest" "$hooks_dest"

# Link $1 (a skill or hook in this repo) to $2, unless $2 is something this
# script didn't make.
link_one() {
    src=$1
    link=$2
    name=$(basename "$link")
    if [ -e "$link" ] && [ ! -L "$link" ]; then
        echo "skipped $name: $link is not a symlink; move it aside to use this repo's copy" >&2
        status=1
        return
    fi
    if [ -L "$link" ] && [ -e "$link" ]; then
        case $(readlink "$link") in
            "$repo"/skills/* | "$repo"/hooks/*) ;;
            *)
                echo "skipped $name: $link points to $(readlink "$link"), not this repo; remove it to use this repo's copy" >&2
                status=1
                return
                ;;
        esac
    fi
    ln -sfn "$src" "$link"
    echo "linked $name -> $src"
}

# Remove links left behind by a skill or hook that was renamed or removed.
for link in "$dest"/* "$hooks_dest"/gnomad-*.sh; do
    [ -L "$link" ] || continue
    target=$(readlink "$link")
    case "$target" in
        "$repo"/skills/*) [ -e "$target/SKILL.md" ] || { rm "$link"; echo "removed stale $(basename "$link")"; } ;;
        "$repo"/hooks/*) [ -e "$target" ] || { rm "$link"; echo "removed stale $(basename "$link")"; } ;;
    esac
done

for skill_md in "$repo"/skills/*/SKILL.md; do
    src=$(dirname "$skill_md")
    link_one "$src" "$dest/$(basename "$src")"
done

for src in "$repo"/hooks/gnomad-*.sh; do
    [ -f "$src" ] || continue
    link_one "$src" "$hooks_dest/$(basename "$src")"
done

exit $status
