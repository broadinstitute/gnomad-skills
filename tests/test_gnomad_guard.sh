#!/bin/sh
# Pipe sample tool calls into hooks/gnomad-guard.sh and check each outcome
# (pass, ask or block), the way the hooks guide suggests testing a hook by
# hand. Nothing here runs the commands themselves. Pre-commit runs this when
# hooks/ or tests/ change. Usage: sh tests/test_gnomad_guard.sh [path/to/hook]
#
#   check EXPECT COMMAND [TEXT]   a Bash call; TEXT, if given, must appear in
#                                 the reason
#   check_file EXPECT TOOL PATH   a Read, Edit or Write call on PATH

guard=${1:-"$(dirname "$0")/../hooks/gnomad-guard.sh"}
fails=0
total=0

# JSON in and out with the standard library, so the tests don't need jq.
to_json() {
    python3 -c 'import json, sys; print(json.dumps({"tool_name": sys.argv[1], "tool_input": {sys.argv[2]: sys.argv[3]}}))' "$1" "$2" "$3"
}
decision() {
    python3 -c 'import json, sys; print(json.load(sys.stdin)["hookSpecificOutput"][sys.argv[1]])' "$1"
}

# Run the hook on JSON $2 and compare with $1; $3 labels the line, $4 is text
# the reason must contain.
run() {
    expect=$1
    json=$2
    label=$3
    want=$4
    total=$((total + 1))
    out=$(printf '%s' "$json" | sh "$guard" 2>"${TMPDIR:-/tmp}/guard_err.$$")
    code=$?
    err=$(cat "${TMPDIR:-/tmp}/guard_err.$$")
    rm -f "${TMPDIR:-/tmp}/guard_err.$$"
    if [ "$code" -eq 2 ]; then
        got=block; msg=$err
    elif [ "$code" -eq 0 ] && [ -n "$out" ]; then
        got=$(printf '%s' "$out" | decision permissionDecision)
        msg=$(printf '%s' "$out" | decision permissionDecisionReason)
    elif [ "$code" -eq 0 ]; then
        got=pass; msg=""
    else
        got="error($code)"; msg=$err
    fi
    mark=ok
    [ "$got" = "$expect" ] || mark=FAIL
    if [ -n "$want" ]; then
        case "$msg" in *"$want"*) ;; *) mark=FAIL ;; esac
    fi
    [ "$mark" = ok ] || fails=$((fails + 1))
    printf '%-4s exit=%s %-5s | %s\n' "$mark" "$code" "$got" "$label"
    [ -n "$msg" ] && printf '                     -> %s\n' "$msg"
    [ "$mark" = ok ] || [ -z "$want" ] || printf '                     (wanted the reason to contain: %s)\n' "$want"
}
check() { run "$1" "$(to_json Bash command "$2")" "$2" "$3"; }
check_file() { run "$1" "$(to_json "$2" file_path "$3")" "$2 $3"; }

echo "== pass: reads, test runs and ordinary commands"
check pass 'gsutil ls gs://gnomad/release/4.1/ht/exomes/'
check pass 'gsutil cp gs://gnomad/release/4.1/ht/exomes/x.ht/metadata.json.gz /tmp/'
check pass 'hailctl dataproc submit my-cluster script.py --overwrite --test'
check pass 'git commit -m "push the fix to main"'
check pass 'rm -rf gcs_inventory/tmp'
check pass 'python -m pytest tests/'
check_file pass Read README.md

echo "== git: every push asks; plain force-pushes and force-pushes to main block"
check ask 'git push origin my-branch' 'pushes my-branch to the remote'
check ask 'git push' 'pushes the current branch to the remote'
check ask 'git -C . push origin main' 'pushes to main'
check ask 'git push origin --delete old-branch' 'deletes a remote branch'
check ask 'git push --force-with-lease --force-if-includes origin my-branch' 'force-pushes my-branch'
check ask 'git -C . push --force-with-lease origin my-branch' 'add --force-if-includes'
check block 'git push --force origin main'
check block 'git push -f origin my-branch'
check block 'git push origin my-branch --force'
check block 'git push origin +my-branch'
check block 'git push --force-with-lease origin main'
check block 'git -C ~/gnomad_qc push --force-with-lease origin HEAD:main'
check ask 'gh pr merge 12 --squash' 'merges a pull request'

echo "== git: --force-with-lease with no branch named, so the current branch decides"
repos=$(mktemp -d "${TMPDIR:-/tmp}/guard_repos.XXXXXX")
git init -q "$repos/on_main" && git -C "$repos/on_main" symbolic-ref HEAD refs/heads/main
git init -q "$repos/on_feature" && git -C "$repos/on_feature" symbolic-ref HEAD refs/heads/my-feature
check block "git -C $repos/on_main push --force-with-lease"
check ask "git -C $repos/on_feature push --force-with-lease --force-if-includes" 'force-pushes my-feature'
rm -rf "$repos"
check pass 'hailctl dataproc start my-cluster --requester-pays-allow-buckets gnomad-public-requester-pays --max-idle 30m'

echo "== bad input"
total=$((total + 1))
printf 'not json' | sh "$guard" 2>/dev/null; code=$?
if [ "$code" -ne 0 ] && [ "$code" -ne 2 ]; then echo "ok   exit=$code fail  | invalid JSON is a hook failure (blocks with onFailure: block)"; else echo "FAIL exit=$code | invalid JSON"; fails=$((fails + 1)); fi

echo
echo "$((total - fails)) of $total cases as expected"
[ "$fails" -eq 0 ]
