#!/bin/sh
# gnomad-guard: a Claude Code PreToolUse hook that stops the gnomAD repos'
# riskiest commands before they run.
#
# What it is: Claude Code runs this script before every tool call that a
# repo's settings point it at (Bash, Read, Edit and Write). It gets the call as
# JSON on stdin and answers in one of three ways:
#   block  exit 2, with the reason on stderr. The call doesn't run, and Claude
#          sees the reason.
#   ask    exit 0, printing a JSON "ask" decision. You get a permission prompt
#          that shows the reason, and the call runs only if you say yes.
#   pass   exit 0 with no output. The normal permission rules decide.
# It never runs, edits or deletes anything itself: it only reads the call.
#
# How it reads a command: it splits the command at ; && || | & and drops
# quotes, so each part is checked on its own and wrappers like
# `bash -c 'gsutil rm ...'` or `git -C dir push` are still seen. It matches the
# command text, so it's a seatbelt, not a sandbox: a script that deletes data
# by itself isn't seen.
#
# The rules are in sections below, one per area. Each says what it catches and
# why, and every rule has cases in tests/test_gnomad_guard.sh, which pre-commit
# runs. Turning it on in a repo is described in README.md, "Hooks".
#
# Try it:
#   echo '{"tool_name":"Bash","tool_input":{"command":"git push origin main --force"}}' | sh hooks/gnomad-guard.sh; echo $?
#
# Settings (environment variables):
#   GNOMAD_SKIP_GUARD=1        turn the hook off.

[ -n "$GNOMAD_SKIP_GUARD" ] && exit 0

# ---------------------------------------------------------------------------
# Read the tool call
# ---------------------------------------------------------------------------
# The fields we need: the tool's name, a Bash command, and a file tool's path.
# jq reads them if it's installed, and python3 otherwise. If neither can read
# the JSON, exit 1: a hook error, which "onFailure": "block" turns into a
# blocked call rather than an unchecked one.
input=$(cat)
if command -v jq >/dev/null 2>&1; then
    field() { printf '%s' "$input" | jq -r "$1 // empty"; }
elif command -v python3 >/dev/null 2>&1; then
    field() {
        printf '%s' "$input" | python3 -c 'import json, sys
d = json.load(sys.stdin)
for k in sys.argv[1].lstrip(".").split("."):
    d = d.get(k) if isinstance(d, dict) else None
print("" if d is None else d)' "$1"
    }
else
    echo "gnomad-guard needs jq or python3 to read the tool call" >&2
    exit 1
fi
tool=$(field .tool_name) || exit 1
path=$(field .tool_input.file_path) || exit 1
cmd=$(field .tool_input.command) || exit 1


# Everything below is about Bash commands; any other call passes.
[ -n "$cmd" ] || exit 0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
# Reasons pile up in $blocks and $asks, each added once, and are reported at
# the end. Any block wins over any ask.
blocks=""
asks=""
add_block() {
    case "$blocks" in *"$1"*) ;; *) blocks="${blocks:+$blocks; }$1" ;; esac
}
add_ask() {
    case "$asks" in *"$1"*) ;; *) asks="${asks:+$asks; }$1" ;; esac
}

# Tests on the part of the command being checked, $s (padded with a space at
# each end, so every word has a space on both sides):
#   has PATTERN   the part matches an extended regex
#   tok WORDS     one of WORDS (a|b|c) appears as a whole word
#   gitcmd SUBS   it's `git SUB` with only options in between (git -C dir, git -c k=v)
has() { printf '%s' "$s" | grep -Eq -- "$1"; }
tok() { has "[[:space:]/]($1)[[:space:]]"; }
gitcmd() { has "[[:space:]/]git([[:space:]]+(-[cC][[:space:]]+[^[:space:]]+|--?[[:alnum:]][[:alnum:]-]*(=[^[:space:]]*)?))*[[:space:]]+($1)[[:space:]]"; }

# Added to the reason for a local delete.
lost="; Claude Code's rewind can't bring back what shell commands delete"

# ---------------------------------------------------------------------------
# Split the command and check each part
# ---------------------------------------------------------------------------
# One part per line: $( and backticks become spaces, quotes and brackets are
# dropped, and the command is cut at && || ; | &.
segs=$(printf '%s\n' "$cmd" | tr '\t' ' ' | sed 's/\$(/ /g' | tr "\`\"'(){}" '       ' \
    | awk '{ gsub(/&&|\|\||;|\||&/, "\n"); print }')
# A command that splits into nothing means a tool is missing: fail, so that
# "onFailure": "block" stops the call instead of letting it through.
[ -n "$segs" ] || { echo "gnomad-guard could not split the command" >&2; exit 1; }

nl='
'
old_ifs=$IFS
IFS=$nl
set -f
for seg in $segs; do
    IFS=$old_ifs
    s=" $seg "

    # -----------------------------------------------------------------------
    # Git: pushes and merges
    # -----------------------------------------------------------------------
    # Every push asks, because it publishes commits; the reason says which
    # kind of push it is.
    #   - A plain force-push (--force, -f, --mirror, or a +branch refspec)
    #     overwrites the remote without checking what's there: block.
    #   - --force-with-lease refuses if the remote has commits you haven't
    #     fetched, so it's the safe way to fix up your own branch: ask, and
    #     suggest --force-if-includes, which stops a background fetch from
    #     letting the lease through. Any force-push to main is blocked.
    #   - Pushing to main, or deleting a remote branch: ask, saying so.
    if gitcmd 'push'; then
        asks_before=$asks
        # The refspecs after the remote name; none means the current branch.
        refs=$(printf '%s' "$s" | awk '{
            for (i = 1; i <= NF; i++) if ($i == "push") break
            n = 0
            for (i++; i <= NF; i++) if ($i !~ /^-/ && ++n > 1) printf "%s%s", (n > 2 ? " " : ""), $i
        }')
        pushed=""
        if has '[[:space:]](--force|--mirror|-[[:alnum:]]*f[[:alnum:]]*)[[:space:]]|[[:space:]]\+[^[:space:]]+'; then
            add_block "a plain force-push overwrites the remote without checking what is there. On your own branch use --force-with-lease --force-if-includes, or ask the user to run it"
            pushed=1
        elif has '[[:space:]]--force-with-lease(=[^[:space:]]*)?[[:space:]]'; then
            pushed=1
            # With no refspec, the branch is the current one in the repo
            # being pushed (git -C dir, or the working directory).
            if [ -z "$refs" ]; then
                dir=$(printf '%s' "$s" | awk '{ for (i = 1; i < NF; i++) if ($i == "-C") { print $(i + 1); exit } }')
                case $dir in "~"*) dir="$HOME${dir#\~}" ;; esac
                refs=$(git ${dir:+-C "$dir"} symbolic-ref --short -q HEAD 2>/dev/null)
            fi
            if printf ' %s ' "$refs" | grep -Eq '[[:space:]:/](main|master)[[:space:]]'; then
                add_block "force-push to main rewrites shared history. Ask the user to run it"
            else
                [ -n "$refs" ] || refs="a branch gnomad-guard could not identify"
                why="force-pushes $refs with --force-with-lease, rewriting its history on the remote"
                has '[[:space:]]--force-if-includes[[:space:]]' \
                    || why="$why; add --force-if-includes so a background fetch can't let the lease through"
                add_ask "$why"
            fi
        fi
        if has '[[:space:]:/](main|master)[[:space:]]'; then
            add_ask "pushes to main"
        fi
        if has '[[:space:]](--delete|-d)[[:space:]]|[[:space:]]:[^[:space:]]+'; then
            add_ask "deletes a remote branch"
        fi
        # An ordinary push, with no reason above: still ask.
        if [ -z "$pushed" ] && [ "$asks" = "$asks_before" ]; then
            [ -n "$refs" ] || refs="the current branch"
            add_ask "pushes $refs to the remote, which publishes the commits"
        fi
    fi

    # Merging a pull request is the step a reviewer should take.
    if tok 'gh' && tok 'pr' && tok 'merge'; then
        add_ask "merges a pull request"
    fi

    # -----------------------------------------------------------------------
    # Local work that rewind can't bring back
    # -----------------------------------------------------------------------
    # Claude Code's rewind restores Claude's own file edits, but not files a
    # shell command deleted or reset. So these ask first:
    #   - rm -r, or rm with a wildcard, on anything but scratch folders (tmp,
    #     temp, caches, build, dist). rm has to be the command itself, not
    #     part of gsutil rm. A plain rm of named files passes.
    #   - find -delete, or find -exec rm
    #   - git reset --hard, git clean -f (not -n, a dry run), git checkout --
    #     or checkout ., git restore (not just --staged), git switch
    #     --discard-changes, git stash drop or clear, git branch -D
    if has '^[[:space:]]*((sudo|xargs|bash[[:space:]]+-c|sh[[:space:]]+-c)[[:space:]]+(-[^[:space:]]+[[:space:]]+)*)?rm[[:space:]]' \
        && { has '[[:space:]](-[[:alnum:]]*[rR][[:alnum:]]*|--recursive)[[:space:]]' || has '[[:space:]]rm[[:space:]].*[*?]'; }; then
        # The rm targets that aren't scratch folders.
        kept=$(printf '%s' "$s" | awk -v tmpd="${TMPDIR:-/tmp}" '{
            for (i = 1; i <= NF; i++) if ($i == "rm") break
            for (i++; i <= NF; i++) {
                if ($i ~ /^-/) continue
                ok = (index($i, tmpd) == 1 || $i ~ /^\/(private\/)?tmp(\/|$)/)
                n = split($i, c, "/")
                for (j = 1; j <= n; j++)
                    if (c[j] ~ /^(tmp|temp|__pycache__|\.pytest_cache|\.mypy_cache|\.ruff_cache|build|dist|node_modules|.*\.egg-info)$/) ok = 1
                if (!ok) { printf "%s%s", sep, $i; sep = " " }
            }
        }')
        [ -n "$kept" ] && add_ask "deletes local files ($kept)$lost"
    fi
    if tok 'find' && has '[[:space:]](-delete|-exec[[:space:]]+rm|-execdir[[:space:]]+rm)[[:space:]]'; then
        add_ask "deletes the local files find matches$lost"
    fi
    if gitcmd 'reset' && tok '--hard'; then
        add_ask "throws away uncommitted changes (git reset --hard)$lost"
    fi
    if gitcmd 'clean' && has '[[:space:]]-[[:alnum:]]*f[[:alnum:]]*[[:space:]]|[[:space:]]--force[[:space:]]' \
        && ! has '[[:space:]](-[[:alnum:]]*n[[:alnum:]]*|--dry-run)[[:space:]]'; then
        add_ask "deletes untracked files (git clean)$lost"
    fi
    if { gitcmd 'checkout' && has '[[:space:]](--|\.|-f|--force)[[:space:]]'; } \
        || { gitcmd 'restore' && { ! tok '--staged|-S' || tok '--worktree|-W'; }; } \
        || { gitcmd 'switch' && has '[[:space:]](-f|--force|--discard-changes)[[:space:]]'; }; then
        add_ask "throws away uncommitted changes to files$lost"
    fi
    if gitcmd 'stash' && tok 'drop|clear'; then
        add_ask "deletes stashed changes"
    fi
    if gitcmd 'branch' && has '[[:space:]](-D|--delete[[:space:]]+--force|-df|-fd)[[:space:]]'; then
        add_ask "force-deletes a local branch, even with commits that aren't merged anywhere"
    fi
    IFS=$nl
done
set +f
IFS=$old_ifs

# ---------------------------------------------------------------------------
# Answer
# ---------------------------------------------------------------------------
# Block: exit 2, reasons on stderr for Claude. Ask: a JSON decision whose
# reason the user sees in the permission prompt. Otherwise pass, silently.
if [ -n "$blocks" ]; then
    echo "Blocked by gnomad-guard: $blocks." >&2
    exit 2
fi
if [ -n "$asks" ]; then
    reason="gnomad-guard: this command $asks."
    if command -v jq >/dev/null 2>&1; then
        jq -cn --arg r "$reason" \
            '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "ask", permissionDecisionReason: $r}}'
    else
        esc=$(printf '%s' "$reason" | sed 's/\\/\\\\/g; s/"/\\"/g')
        printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s"}}\n' "$esc"
    fi
fi
exit 0
