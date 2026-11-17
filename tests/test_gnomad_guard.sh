#!/bin/sh
# Pipe sample tool calls into hooks/gnomad-guard.sh and check each outcome
# (pass, ask or block), the way the hooks guide suggests testing a hook by
# hand. Nothing here runs the commands themselves. Pre-commit runs this when
# hooks/ or tests/ change. Usage: sh tests/test_gnomad_guard.sh [path/to/hook]

guard=${1:-"$(dirname "$0")/../hooks/gnomad-guard.sh"}
fails=0
total=0

# JSON in and out with the standard library, so the tests don't need jq.
to_json() {
    python3 -c 'import json, sys; print(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}}))' "$1"
}
decision() {
    python3 -c 'import json, sys; print(json.load(sys.stdin)["hookSpecificOutput"][sys.argv[1]])' "$1"
}

check() {
    expect=$1
    cmd=$2
    total=$((total + 1))
    json=$(to_json "$cmd")
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
    if [ "$got" = "$expect" ]; then mark=ok; else mark=FAIL; fails=$((fails + 1)); fi
    printf '%-4s exit=%s %-5s | %s\n' "$mark" "$code" "$got" "$cmd"
    [ -n "$msg" ] && printf '                     -> %s\n' "$msg"
}

echo "== pass: read-only, test runs, ordinary pushes"
check pass 'gsutil ls gs://gnomad/release/4.1/ht/exomes/'
check pass 'gsutil cp gs://gnomad/release/4.1/ht/exomes/x.ht/metadata.json.gz /tmp/'
check pass 'hailctl dataproc submit my-cluster script.py --overwrite --test'
check pass 'git push origin my-branch'
check pass 'git commit -m "push the fix to main"'
check pass 'rm -rf gcs_inventory/tmp'
check pass 'python -m pytest tests/'
check pass 'hailctl dataproc start my-cluster --num-secondary-workers 20 --max-idle 540m'
check pass 'hailctl dataproc start my-cluster --num-secondary-workers 20 --max-age 12h'

echo "== ask: deleting GCS data"
check ask 'gsutil rm -r gs://gnomad/release/x'
check ask 'gsutil -m rm -r gs://gnomad-tmp-4day/my-dir/old/'
check ask 'gsutil -q rm gs://some-bucket/x'
check ask "bash -c 'gsutil rm gs://some-bucket/x'"
check ask 'gcloud storage rm --recursive gs://my-bucket/tmp/'
check ask 'gsutil -m rsync -d -r out/ gs://my-bucket/out/'
check ask 'hadoop fs -rm -r gs://gnomad-tmp/x'
check ask 'rm -rf ~/gcs/my-bucket/tmp'
check ask "python -c \"from hailtop import fs; fs.rmtree('gs://my-bucket/tmp')\""

echo "== ask: clusters and jobs"
check ask 'gcloud dataproc clusters delete my-cluster --region us-central1'
check ask 'hailctl dataproc stop my-cluster'
check ask 'cd ~/gnomad_qc && hailctl dataproc stop my-cluster'
check ask 'gcloud dataproc jobs kill abc123 --region us-central1'
check ask 'hailctl dataproc start big --num-secondary-workers 400'

echo "== ask: release paths, overwrites, cost, credentials"
check ask 'gsutil cp local.json gs://gnomad/release/4.1/json/'
check ask "python -c \"ht.write('gs://gnomad/release/4.1/ht/x.ht', overwrite=True)\""
check ask 'hailctl dataproc submit my-cluster gnomad_qc/v4/create_release/create_release_sites_ht.py --overwrite'
check ask 'gsutil cp gs://gnomad-public-requester-pays/release/4.1/ht/exomes/x /tmp/'
check ask 'git -C . push origin main'
check ask 'gcloud auth print-access-token'

echo "== ask: --force-with-lease on your own branch"
check ask 'git push --force-with-lease --force-if-includes origin my-branch'
check ask 'git -C . push --force-with-lease origin my-branch'

echo "== block: plain force-pushes, and any force-push to main"
check block 'git push --force origin main'
check block 'git push -f origin my-branch'
check block 'git push origin my-branch --force'
check block 'git push origin +my-branch'
check block 'git push --force-with-lease origin main'
check block 'git -C ~/gnomad_qc push --force-with-lease origin HEAD:main'

echo "== billing projects: fine for requester-pays buckets, blocked for the rest"
check pass 'hailctl dataproc start my-cluster --requester-pays-allow-buckets gnomad-public-requester-pays --max-idle 30m'
check pass "python -c \"import hail as hl; hl.init(gcs_requester_pays_configuration=('my-project', ['gnomad-public-requester-pays']))\""
check ask 'gsutil -u my-project cp gs://gnomad-public-requester-pays/release/4.1/ht/exomes/x /tmp/'
check ask 'hailctl dataproc start my-cluster --requester-pays-allow-buckets gnomad-public-requester-pays,other-lab-bucket --max-idle 30m'
check block 'gsutil -u my-project ls gs://gnomad/release/4.1/'
check block 'gcloud storage cp --billing-project=my-project gs://gcp-public-data--gnomad/release/4.1/vcf/x.vcf.bgz .'
check block 'hailctl dataproc start my-cluster --requester-pays-allow-all --max-idle 30m'
check block "python -c \"import hail as hl; hl.init(gcs_requester_pays_configuration='my-project')\""
check block 'gcloud dataproc clusters create my-cluster --max-idle 30m --properties core:fs.gs.requester.pays.mode=ENABLED'

echo "== local work that rewind can't bring back"
check pass 'rm notes.txt'
check pass 'rm -rf build/ dist/ .pytest_cache'
check pass 'git restore --staged README.md'
check pass 'git clean -n'
check pass 'git checkout -b new-branch'
check ask 'rm -rf src/old_module'
check ask 'cd ~/gnomad_qc && rm -f *.ht'
check ask "find . -name '*.log' -delete"
check ask 'git reset --hard HEAD~1'
check ask 'git clean -fdx'
check ask 'git checkout -- gnomad/utils/constraint.py'
check ask 'git restore .'
check ask 'git stash drop'
check ask 'git branch -D old-branch'

echo "== bucket-owner settings"
check pass 'gsutil versioning get gs://my-bucket'
check pass 'gsutil lifecycle get gs://my-bucket'
check pass 'gsutil retention get gs://my-bucket'
check block 'gsutil retention lock gs://my-bucket'
check block 'gcloud storage buckets update gs://my-bucket --lock-retention-period'
check ask 'gsutil lifecycle set lifecycle.json gs://my-bucket'
check ask 'gcloud storage buckets update gs://my-bucket --lifecycle-file=rules.json'
check ask 'gsutil versioning set off gs://my-bucket'
check ask 'gcloud storage buckets update gs://my-bucket --clear-soft-delete'
check ask 'gsutil requesterpays set off gs://gnomad-public-requester-pays'
check ask 'gsutil -m acl ch -r -u AllUsers:R gs://my-bucket/out/'
check ask 'gsutil defacl set public-read gs://my-bucket'
check ask 'gcloud storage buckets update gs://my-bucket --no-public-access-prevention'
check ask 'gsutil -m iam ch allUsers:objectViewer gs://my-bucket'
check ask 'gcloud storage buckets update gs://my-bucket --clear-default-encryption-key'
check ask 'gcloud kms keys versions destroy 1 --key k --keyring r --location us'
check ask 'gsutil signurl -d 7d key.json gs://my-bucket/x.vcf.gz'
check ask 'gcloud storage sign-url gs://my-bucket/x.vcf.gz --duration=7d --private-key-file=key.json'

echo "== cluster size on a resize"
check pass 'hailctl dataproc modify my-cluster --num-secondary-workers 50'
check ask 'hailctl dataproc modify my-cluster --num-secondary-workers 200'
check ask 'gcloud dataproc clusters update my-cluster --num-secondary-workers=150 --region us-central1'

echo "== --force-with-lease with no branch named: the current branch decides"
repos=$(mktemp -d "${TMPDIR:-/tmp}/guard_repos.XXXXXX")
git init -q "$repos/on_main" && git -C "$repos/on_main" symbolic-ref HEAD refs/heads/main
git init -q "$repos/on_feature" && git -C "$repos/on_feature" symbolic-ref HEAD refs/heads/my-feature
check block "git -C $repos/on_main push --force-with-lease"
check ask "git -C $repos/on_feature push --force-with-lease --force-if-includes"
rm -rf "$repos"

echo "== other tools and bad input"
total=$((total + 1))
out=$(printf '%s' '{"tool_name":"Read","tool_input":{"file_path":"README.md"}}' | sh "$guard"); code=$?
if [ "$code" -eq 0 ] && [ -z "$out" ]; then echo "ok   exit=0 pass  | Read tool call"; else echo "FAIL exit=$code | Read tool call"; fails=$((fails + 1)); fi
total=$((total + 1))
printf 'not json' | sh "$guard" 2>/dev/null; code=$?
if [ "$code" -ne 0 ] && [ "$code" -ne 2 ]; then echo "ok   exit=$code fail  | invalid JSON is a hook failure (blocks with onFailure: block)"; else echo "FAIL exit=$code | invalid JSON"; fails=$((fails + 1)); fi

echo
echo "$((total - fails)) of $total cases as expected"
[ "$fails" -eq 0 ]
