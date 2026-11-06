#!/bin/sh
# Link every skill in this repo into ~/.claude/skills, so Claude Code sees
# them in every project. Each entry is a symlink into this checkout, so a
# `git pull` is all it takes to update them. Re-run after adding, removing or
# renaming a skill.
#
# The script only replaces symlinks it made (or dangling ones): a skill you
# installed by hand, cloned (such as /review) or linked from your own copy is
# left alone and reported.

set -eu

repo=$(cd "$(dirname "$0")/.." && pwd -P)
dest="$HOME/.claude/skills"
status=0

mkdir -p "$dest"

# Remove links left behind by a skill that was renamed or removed.
for link in "$dest"/*; do
    [ -L "$link" ] || continue
    target=$(readlink "$link")
    case "$target" in
        "$repo"/skills/*) [ -e "$target/SKILL.md" ] || { rm "$link"; echo "removed stale $(basename "$link")"; } ;;
    esac
done

for skill_md in "$repo"/skills/*/SKILL.md; do
    src=$(dirname "$skill_md")
    name=$(basename "$src")
    link="$dest/$name"
    if [ -e "$link" ] && [ ! -L "$link" ]; then
        echo "skipped $name: $link is a real directory, not a symlink; move it aside to use this repo's copy" >&2
        status=1
        continue
    fi
    if [ -L "$link" ] && [ -e "$link" ]; then
        case $(readlink "$link") in
            "$repo"/skills/*) ;;
            *)
                echo "skipped $name: $link points to $(readlink "$link"), not this repo; remove it to use this repo's copy" >&2
                status=1
                continue
                ;;
        esac
    fi
    ln -sfn "$src" "$link"
    echo "linked $name -> $src"
done

exit $status
