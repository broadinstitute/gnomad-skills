#!/bin/sh
# gnomad-guard: a Claude Code PreToolUse hook that stops the gnomAD repos'
# riskiest shell commands before they run. It does nothing until a repo (or a
# user) registers it as a PreToolUse hook on Bash; see README.md, "Hooks".
#
# Claude Code sends the tool call as JSON on stdin; this reads
# .tool_input.command and decides:
#   block  exit 2, reason on stderr (Claude Code shows it to Claude):
#          plain force-pushes (--force, -f, +branch, --mirror) in any spelling,
#          and any force-push to main or master; a billing project on a bucket
#          that isn't requester-pays (gsutil -u, --billing-project), and
#          settings that bill a project for every bucket (hailctl
#          --requester-pays-allow-all, Hail's gcs_requester_pays_configuration
#          given a project alone, fs.gs.requester.pays.mode=ENABLED); locking a
#          bucket's retention policy, which can't be undone.
#   ask    exit 0 with a JSON "ask" decision (the reason is shown to you in the
#          permission prompt): --force-with-lease on any other branch, for
#          fixing up your own branch; deleting GCS data, stopping or deleting Dataproc
#          clusters or cancelling jobs, writing to a gnomAD release path,
#          --overwrite without --test, pushing to main or deleting a remote
#          branch, reading the requester-pays bucket, very large or unbounded
#          clusters, printing or reading cloud credentials; and local work
#          that rewind can't bring back: rm -r or rm with a wildcard outside
#          scratch folders, find -delete, git reset --hard, git clean -f,
#          git checkout -- / git restore, git stash drop, git branch -D; and
#          bucket-owner settings: lifecycle rules, versioning or soft delete
#          off, requester-pays on or off, ACL / IAM / public-access changes,
#          encryption keys, and signed URLs.
#   pass   exit 0 with no output: the normal permission rules decide.
#
# Matching is on the command text, after splitting it at ; && || | & and
# dropping quotes, so `bash -c 'gsutil rm ...'` and `git -C . push` are caught.
# It is a seatbelt, not a sandbox: a script that deletes data itself is not seen.
#
# Try it:
#   echo '{"tool_name":"Bash","tool_input":{"command":"gsutil rm -r gs://gnomad/release/x"}}' | sh hooks/gnomad-guard.sh; echo $?
# Every rule has cases in tests/test_gnomad_guard.sh, which pre-commit runs.
#
# Settings: GNOMAD_SKIP_GUARD=1 turns it off; GNOMAD_GUARD_MAX_WORKERS (default
# 100) is the cluster size that asks first; GNOMAD_GUARD_RP_BUCKETS names more
# requester-pays buckets.

[ -n "$GNOMAD_SKIP_GUARD" ] && exit 0
max_workers=${GNOMAD_GUARD_MAX_WORKERS:-100}

input=$(cat)
if command -v jq >/dev/null 2>&1; then
    cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty') || exit 1
elif command -v python3 >/dev/null 2>&1; then
    cmd=$(printf '%s' "$input" | python3 -c 'import json, sys
print(json.load(sys.stdin).get("tool_input", {}).get("command", "") or "")') || exit 1
else
    echo "gnomad-guard needs jq or python3 to read the tool call" >&2
    exit 1
fi
[ -n "$cmd" ] || exit 0

release='gs://(gnomad|gnomad-public-requester-pays|gcp-public-data--gnomad)/release'
# Requester-pays buckets: reading them needs a billing project. Passing one for
# any other bucket bills us for requests we would not otherwise pay for.
# GNOMAD_GUARD_RP_BUCKETS adds more names, as a regex alternation (a|b).
rp_names="gnomad-public-requester-pays${GNOMAD_GUARD_RP_BUCKETS:+|$GNOMAD_GUARD_RP_BUCKETS}"
rp_bucket="gs://($rp_names)"
bill_other="passes a billing project for a bucket that isn't requester-pays, which bills our project for requests we would not otherwise pay for. Drop -u / --billing-project"
bill_all="bills a project for every bucket, not just requester-pays ones, so ordinary reads and writes start costing us. Name the requester-pays buckets instead"

blocks=""
asks=""
add_block() {
    case "$blocks" in *"$1"*) ;; *) blocks="${blocks:+$blocks; }$1" ;; esac
}
add_ask() {
    case "$asks" in *"$1"*) ;; *) asks="${asks:+$asks; }$1" ;; esac
}
# Tests on the current subcommand $s: has matches a pattern, tok a whole word,
# gitcmd a git subcommand with only options before it (git -C dir, git -c k=v).
has() { printf '%s' "$s" | grep -Eq -- "$1"; }
tok() { has "[[:space:]/]($1)[[:space:]]"; }
gitcmd() { has "[[:space:]/]git([[:space:]]+(-[cC][[:space:]]+[^[:space:]]+|--?[[:alnum:]][[:alnum:]-]*(=[^[:space:]]*)?))*[[:space:]]+($1)[[:space:]]"; }
lost="; Claude Code's rewind can't bring back what shell commands delete"
bucket_update() { tok 'gcloud' && tok 'storage' && tok 'buckets' && tok 'update'; }
# gsutil's own -u (billing project) comes before the subcommand; a later -u,
# as in `gsutil acl ch -u user:R`, belongs to the subcommand.
gsutil_billing() {
    printf '%s' "$s" | awk '{
        for (i = 1; i <= NF; i++) if ($i ~ /(^|\/)gsutil$/) break
        for (i++; i <= NF; i++) {
            if ($i == "-u") { found = 1; exit }
            if ($i == "-o" || $i == "-h") { i++; continue }
            if ($i !~ /^-/) exit
        }
    } END { exit !found }'
}
# The first gs:// path in a string, for the message.
gs_path() {
    printf '%s' "$1" | grep -Eo "gs://[^[:space:]\"'(),]+" | head -n 1
}

# Checks on the raw command: Python one-liners and credential files, where the
# parentheses and quotes matter.
raw=$(printf '%s' "$cmd" | tr '\n\t' '  ')
if printf '%s' "$raw" | grep -Eq 'gs://' \
    && printf '%s' "$raw" | grep -Eq 'rmtree\(|\.rm\(|hadoop_rm|delete_blob|\.remove\('; then
    add_ask "deletes GCS data from Python ($(gs_path "$raw"))"
fi
if printf '%s' "$raw" | grep -Eq "$release" \
    && printf '%s' "$raw" | grep -Eq 'overwrite[[:space:]]*=[[:space:]]*True|\.write\(|\.checkpoint\(|export_vcf\(|write_expression\('; then
    add_ask "writes to a gnomAD release path from Python ($(gs_path "$raw"))"
fi
if printf '%s' "$raw" | grep -Eq "$rp_bucket" \
    && printf '%s' "$raw" | grep -Eq 'read_table\(|read_matrix_table\(|read_vds\(|import_vcf\('; then
    add_ask "reads the requester-pays bucket, which bills your project; read gs://gcp-public-data--gnomad instead"
fi
# Hail and Spark settings that bill a project for every bucket: Hail's
# gcs_requester_pays_configuration given a project alone (a tuple with a bucket
# list is fine), the connector's ENABLED mode (AUTO and CUSTOM are fine), and
# hailctl's --requester-pays-allow-all.
if printf '%s' "$raw" | grep -Eq "gcs_requester_pays_configuration[[:space:]]*=[[:space:]]*['\"]|fs\.gs\.requester\.pays\.mode=ENABLED|--requester-pays-allow-all"; then
    add_block "$bill_all"
fi
if printf '%s' "$raw" | grep -Eq 'application_default_credentials\.json|legacy_credentials|credentials\.db|access_tokens\.db|\.boto([[:space:]]|$)'; then
    add_ask "reads cloud credential files"
fi

# Per-subcommand checks, on tokens with quotes, $( and backticks dropped.
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
    p=$(gs_path "$s")
    what="GCS data"
    has "$release" && what="gnomAD release data"

    # git push, with only options between git and push (git -C dir, git -c k=v).
    if gitcmd 'push'; then
        if has '[[:space:]](--force|--mirror|-[[:alnum:]]*f[[:alnum:]]*)[[:space:]]|[[:space:]]\+[^[:space:]]+'; then
            add_block "a plain force-push overwrites the remote without checking what is there. On your own branch use --force-with-lease --force-if-includes, or ask the user to run it"
        elif has '[[:space:]]--force-with-lease(=[^[:space:]]*)?[[:space:]]'; then
            # The branch: the refspecs after the remote, or, with none, the current branch.
            refs=$(printf '%s' "$s" | awk '{
                for (i = 1; i <= NF; i++) if ($i == "push") break
                n = 0
                for (i++; i <= NF; i++) if ($i !~ /^-/ && ++n > 1) printf "%s%s", (n > 2 ? " " : ""), $i
            }')
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
    fi

    # Deleting GCS data.
    if { tok 'gsutil' && tok 'rm|rb'; } || { tok 'gcloud' && tok 'storage' && tok 'rm|delete'; } \
        || { tok 'hadoop|hdfs' && tok '-rm|-rmr|-rmdir'; }; then
        add_ask "deletes $what ($p)"
    fi
    if { tok 'gsutil' && tok 'rsync' && has '[[:space:]]-[[:alnum:]]*d[[:alnum:]]*[[:space:]]'; } \
        || { tok 'gcloud' && tok 'storage' && tok 'rsync' && has '--delete-unmatched-destination-objects'; }; then
        add_ask "syncs with delete, removing $what missing from the source ($p)"
    fi
    if tok 'rm' && has '[[:space:]](-[[:alnum:]]*[rR][[:alnum:]]*|--recursive)[[:space:]]' \
        && has '[[:space:]]([^[:space:]]*/)?(gcs|gcsfuse|gcs-fuse)(/[^[:space:]]*)?[[:space:]]'; then
        add_ask "runs a recursive rm on a mounted bucket"
    fi

    # Bucket-owner settings. A retention lock is permanent, so it blocks; the
    # rest ask, with what the change can cost.
    b=$(printf '%s' "$s" | grep -Eo 'gs://[^[:space:]/]+' | head -n 1)
    if { tok 'gsutil' && tok 'retention' && tok 'lock'; } \
        || { bucket_update && has '[[:space:]]--lock-retention-period([[:space:]=])'; }; then
        add_block "locks the retention policy on ${b:-a bucket}, which can't be undone: no object can be deleted before it expires, and the bucket can't be deleted. Ask the user to run it"
    fi
    if { tok 'gsutil' && tok 'lifecycle' && tok 'set'; } \
        || { bucket_update && has '[[:space:]]--lifecycle-file([[:space:]=])'; }; then
        add_ask "sets lifecycle rules on ${b:-a bucket}, which can delete objects in the background"
    fi
    if { tok 'gsutil' && tok 'versioning' && tok 'set' && tok 'off|suspended'; } \
        || { bucket_update && has '[[:space:]](--no-versioning|--clear-soft-delete|--soft-delete-duration)([[:space:]=])'; }; then
        add_ask "turns off versioning or changes soft delete on ${b:-a bucket}, the only way back for deleted objects"
    fi
    if { tok 'gsutil' && tok 'requesterpays' && tok 'set'; } \
        || { bucket_update && has '[[:space:]]--(no-)?requester-pays([[:space:]=])'; }; then
        add_ask "changes requester-pays on ${b:-a bucket}: off means we pay for everyone's downloads, on breaks free readers"
    fi
    if { tok 'gsutil' && tok 'acl|defacl|iam' && tok 'set|ch'; } \
        || { tok 'gcloud' && tok 'storage' && has '[[:space:]](--predefined-acl|--predefined-default-object-acl|--add-acl-grant|--acl-file|--default-object-acl-file)([[:space:]=])'; } \
        || { tok 'gcloud' && tok 'storage' && tok 'buckets' && tok 'add-iam-policy-binding|set-iam-policy'; } \
        || { bucket_update && has '[[:space:]](--no-public-access-prevention|--no-uniform-bucket-level-access)([[:space:]=])'; }; then
        if has '[Aa]ll[Uu]sers|[Aa]ll[Aa]uthenticated[Uu]sers|public-?[Rr]ead|--no-public-access-prevention'; then
            add_ask "can make ${b:-objects} readable by anyone; internal gnomAD data must never be public"
        else
            add_ask "changes who can access ${b:-a bucket}"
        fi
    fi
    if { tok 'gsutil' && tok 'kms' && tok 'encryption' && has '[[:space:]]-[kd][[:space:]]'; } \
        || { bucket_update && has '[[:space:]](--default-encryption-key|--clear-default-encryption-key)([[:space:]=])'; } \
        || { tok 'gcloud' && tok 'kms' && tok 'versions' && tok 'disable|destroy'; }; then
        add_ask "changes or disables an encryption key; data under a lost key can never be read"
    fi
    if { tok 'gsutil' && tok 'signurl'; } || { tok 'gcloud' && tok 'storage' && tok 'sign-url'; }; then
        dur=$(printf '%s' "$s" | awk '{
            for (i = 1; i < NF; i++) {
                if ($i == "-d" || $i == "--duration") { print $(i + 1); exit }
                if ($i ~ /^--duration=/) { sub(/^--duration=/, "", $i); print $i; exit }
            }
        }')
        add_ask "creates a signed URL${dur:+ valid for $dur}; anyone with the link can read ${p:-the object} until it expires"
    fi

    # Local work. rm -r, or rm with a wildcard, on anything but scratch folders
    # (tmp, temp, caches, build, dist); rm as the command, not gsutil rm.
    if has '^[[:space:]]*((sudo|xargs|bash[[:space:]]+-c|sh[[:space:]]+-c)[[:space:]]+(-[^[:space:]]+[[:space:]]+)*)?rm[[:space:]]' \
        && { has '[[:space:]](-[[:alnum:]]*[rR][[:alnum:]]*|--recursive)[[:space:]]' || has '[[:space:]]rm[[:space:]].*[*?]'; }; then
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

    # Stopping or deleting clusters, cancelling jobs.
    if { tok 'gcloud' && tok 'dataproc' && tok 'clusters' && tok 'delete|stop'; } \
        || { tok 'hailctl' && tok 'dataproc' && tok 'stop'; } \
        || { tok 'deployctl' && tok 'dataproc-cluster' && tok 'stop'; }; then
        name=$(printf '%s' "$s" | awk '{ for (i = 1; i < NF; i++) if ($i == "stop" || $i == "delete") { print $(i + 1); exit } }')
        add_ask "stops or deletes Dataproc cluster ${name:-?}; someone else's job may be running on it"
    fi
    if tok 'gcloud' && tok 'dataproc' && tok 'jobs' && tok 'kill|delete'; then
        add_ask "cancels a Dataproc job"
    fi
    if tok 'hailctl' && tok 'batch' && tok 'cancel|delete'; then
        add_ask "cancels a Hail Batch"
    fi

    # Writing to a release path with gsutil or gcloud storage.
    if has "$release" && tok 'gsutil|gcloud'; then
        last=$(printf '%s' "$s" | awk '{ print $NF }')
        if tok 'mv|setmeta|rewrite|compose|acl|iam' \
            || { tok 'cp|rsync' && printf '%s' "$last" | grep -Eq "$release"; }; then
            add_ask "writes to a gnomAD release path ($p)"
        fi
    fi

    # --overwrite with no test flag, as in our pipeline CLIs.
    if tok '--overwrite' && ! has '[[:space:]]--(test|use-test-dataset|test-[[:alnum:]-]+)([[:space:]=])'; then
        add_ask "passes --overwrite with no --test, which can replace production Tables"
    fi

    # Billing projects: only for requester-pays buckets. With one named, a
    # billing project is how you read it, so ask and point to the free copy;
    # with none named, a billing project only costs us, so block.
    if gsutil_billing || has '[[:space:]]--billing-project([[:space:]=])'; then
        if has "$rp_bucket"; then
            add_ask "reads the requester-pays bucket, which bills your project; read gs://gcp-public-data--gnomad instead"
        else
            add_block "$bill_other"
        fi
    elif has "$rp_bucket" && tok 'cp|rsync|cat|du'; then
        add_ask "reads the requester-pays bucket, which bills your project; read gs://gcp-public-data--gnomad instead"
    fi
    # hailctl --requester-pays-allow-buckets: fine for requester-pays buckets.
    if has '[[:space:]]--requester-pays-allow-buckets([[:space:]=])'; then
        other=$(printf '%s' "$s" | awk -v rp="^($rp_names)$" '{
            for (i = 1; i <= NF; i++) {
                v = ""
                if ($i == "--requester-pays-allow-buckets") v = $(i + 1)
                else if ($i ~ /^--requester-pays-allow-buckets=/) v = substr($i, 32)
                n = split(v, b, ",")
                for (j = 1; j <= n; j++) if (b[j] !~ rp) { printf "%s%s", sep, b[j]; sep = ", " }
            }
        }')
        [ -n "$other" ] && add_ask "bills a project for buckets gnomad-guard doesn't know are requester-pays ($other); on any other bucket that only costs us"
    fi

    # Big or unbounded clusters: the worker counts on a start or a resize.
    # An autoscaling policy's maximum lives in the policy, so it isn't seen here.
    starting=""
    resizing=""
    { tok 'hailctl' && tok 'dataproc' && tok 'start'; } \
        || { tok 'gcloud' && tok 'dataproc' && tok 'clusters' && tok 'create'; } && starting=1
    { tok 'hailctl' && tok 'dataproc' && tok 'modify'; } \
        || { tok 'gcloud' && tok 'dataproc' && tok 'clusters' && tok 'update'; } && resizing=1
    if [ -n "$starting$resizing" ]; then
        workers=$(printf '%s' "$s" | awk '{
            for (i = 1; i <= NF; i++) {
                n = split($i, kv, "=")
                if (kv[1] ~ /^--num-(secondary-|preemptible-)?workers$/) t += (n > 1 ? kv[2] : $(i + 1))
            }
            print t + 0 }')
        if [ "$workers" -ge "$max_workers" ]; then
            if [ -n "$starting" ]; then add_ask "starts a cluster with $workers workers"
            else add_ask "resizes a cluster to $workers workers"; fi
        fi
        if has 'non-preemptible'; then
            add_ask "adds non-preemptible secondary workers"
        fi
    fi
    if [ -n "$starting" ] && ! has '[[:space:]]--max-(idle|age)([[:space:]=])'; then
        add_ask "starts a cluster with no --max-idle or --max-age, which bills until someone stops it"
    fi

    # Access tokens printed into the transcript.
    if tok 'gcloud' && has 'print-(access|identity)-token'; then
        add_ask "prints a live access token into the transcript"
    fi
    IFS=$nl
done
set +f
IFS=$old_ifs

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
