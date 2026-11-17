# gnomad-skills

Shared [Claude Code skills](https://code.claude.com/docs/en/skills) for the
gnomAD repos. One checkout, linked into `~/.claude/skills`, so the same skills
are available in every repo and a `git pull` updates them. It also has one
shared hook, [gnomad-guard](#gnomad-guard), that stops risky commands before
they run.

The skills are written for, and used in, gnomad_qc, gnomad_methods,
gnomad-constraint, gnomad_mnv, regional_missense_constraint and gnomad_chets.
They work in any gnomAD repo; add a repo to this list, and to the skills'
descriptions, once the skills have been used there.

## Skills

Model-invoked skills can be started by Claude when a request matches their
description, or by typing their name. User-invoked skills only run when typed.

### User-invoked

- **[gnomad-pr-review](skills/gnomad-pr-review/SKILL.md)**: thorough
  multi-agent review of a large Hail pipeline PR, one reviewer agent per file,
  with local repros, end-to-end checks of High findings, and a ranked
  `REVIEW.md` of draft PR comments. Read-only: never posts, never submits to
  Dataproc or Batch. `/gnomad-pr-review <PR> [model=...] [second-opinion=...]`.

### Model-invoked

- **[gnomad-commit](skills/gnomad-commit/SKILL.md)**: commit staged changes:
  runs the repo's pre-commit hooks on them, reviews the diff, drafts a message
  in the repo's style, and confirms before committing.
- **[gnomad-pr-description](skills/gnomad-pr-description/SKILL.md)**: draft a
  PR description from the branch's diff, the repo's `CLAUDE.md`, and the AI
  reviews that ran.
- **[gnomad-clean-git-history](skills/gnomad-clean-git-history/SKILL.md)**:
  rewrite a messy branch into clean atomic commits, verified by an empty diff
  against a backup branch, keeping the original authors.
- **[gnomad-find-base-branch](skills/gnomad-find-base-branch/SKILL.md)**: work
  out which branch the current one is based on. Used by the two skills above.

## Hooks

### gnomad-guard

[`hooks/gnomad-guard.sh`](hooks/gnomad-guard.sh) is a PreToolUse hook that
checks each command before it runs. It never runs anything itself: it blocks
the call, asks you first with the reason in the permission prompt, or passes
it on to the normal permission rules. It holds all the shared rules, so a
repo's settings need only one entry to turn it on.

- **Git:** blocks a plain force-push (`--force`, `-f`, `+branch`) and any
  force-push to `main`. Asks before every other push, including
  `--force-with-lease` on your own branch, and before `gh pr merge`.
- **Local work:** asks before deletes that Claude's rewind can't bring back:
  `rm -r` or a wildcard `rm` outside scratch folders, `find -delete`,
  `git reset --hard`, `git clean -f`, `git checkout --`, `git restore`,
  `git stash drop` and `git branch -D`.

It matches the command text, so it also catches spellings that permission
rules miss, such as `git push origin main --force` or
`bash -c 'gsutil rm ...'`. It's a seatbelt, not a sandbox: a script that
deletes data by itself isn't seen.

Settings, as environment variables:

- `GNOMAD_SKIP_GUARD=1` turns it off.

Try it, and run its test cases:

```bash
echo '{"tool_name":"Bash","tool_input":{"command":"git push origin main --force"}}' | sh hooks/gnomad-guard.sh; echo "exit $?"
sh tests/test_gnomad_guard.sh
```

## Install

```bash
git clone https://github.com/broadinstitute/gnomad-skills.git ~/repos/gnomad-skills
~/repos/gnomad-skills/scripts/link-skills.sh
```

The script symlinks each `skills/<name>` into `~/.claude/skills/<name>`. It
only replaces symlinks it made, so a skill you installed by hand (for example
a clone of `/review`, or a link to your own copy) is left alone and reported.
Claude Code notices the new
skills in a running session; if `~/.claude/skills` did not exist before, run
`/reload-skills` once.

## Update

```bash
git -C ~/repos/gnomad-skills pull
```

The symlinks point into the checkout, so that is all. Re-run
`scripts/link-skills.sh` only after a skill is added, renamed or removed.

## Adding or changing a skill

- A skill is a directory `skills/<name>/` with a `SKILL.md`, plus any helper
  files it needs. Name it `gnomad-<something>`: these are personal skills,
  active in every repo on the machine, so the prefix keeps them out of the way
  elsewhere.
- Say in the description that the skill is for gnomAD repos, and make it work
  in all four. Check the repo's `CLAUDE.md`, or for the file in question,
  before relying on a `tests/` directory, a `.github/release.yml` or a public
  API; only gnomad_methods has all three.
- Reference another skill by telling Claude to call the Skill tool with its
  name, and this skill's own helper files as `${CLAUDE_SKILL_DIR}/<file>`.
  Never by a path into `.claude/skills`, which is not where they live here.
- Add it to the list above, and run `scripts/link-skills.sh` to try it.
- Install the pre-commit hooks once (`pip install pre-commit && pre-commit
  install`); they keep whitespace tidy, format `callmap.py` and run the
  gnomad-guard test cases.

## Changing gnomad-guard

- Add a case to `tests/test_gnomad_guard.sh` for the command it got wrong,
  see it fail, then change the rule in `hooks/gnomad-guard.sh`.
- Put a new rule in its area's section of the hook, with a comment saying
  what it catches and why, and add the area to the list above.
- Keep it POSIX `sh` with `awk`, `grep`, `sed`, `tr` and `git`; it reads the
  tool call with `jq`, or `python3` when `jq` is missing.
