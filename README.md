# gnomad-skills

Shared [Claude Code skills](https://code.claude.com/docs/en/skills) for the
gnomAD repos. One checkout, linked into `~/.claude/skills`, so the same skills
are available in every repo and a `git pull` updates them.

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
  install`); they keep whitespace tidy and format `callmap.py`.
