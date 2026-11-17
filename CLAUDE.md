# CLAUDE.md

Shared Claude Code skills for the gnomAD repos, installed as personal skills by symlinking
`skills/<name>` into `~/.claude/skills` (`scripts/link-skills.sh`), and a
shared PreToolUse hook, `hooks/gnomad-guard.sh`, that a repo turns on in its
own settings. Nothing here is published or packaged; `git pull` is the update
mechanism.

## Rules for editing

- Every skill under `skills/` is listed in `README.md`, under **User-invoked**
  if its frontmatter has `disable-model-invocation: true`, otherwise under
  **Model-invoked**. A model-invoked description says what the skill is for
  and when to use it, and names gnomAD repos so it is not picked up elsewhere.
- Skill names carry the `gnomad-` prefix; the frontmatter `name` matches the
  directory name.
- A skill refers to another skill by telling Claude to call the Skill tool
  with its name, for example "call the Skill tool with `gnomad-find-base-branch`",
  not by a file path. It refers to its own helper files as
  `${CLAUDE_SKILL_DIR}/<file>`.
- A skill must work in every gnomAD repo. Anything repo-specific (a `tests/`
  directory, `.github/release.yml`, a public API, a `CLAUDE.md` section) is
  checked for, not assumed. Attribution on commits follows the target repo's
  `CLAUDE.md`, never a trailer written into the skill.
- Skills are read-only with respect to the user's branches unless they say
  otherwise: no pushing, no posting to GitHub, no Dataproc or Batch
  submissions, and never individual-level data read locally.
- Hooks under `hooks/` are POSIX `sh` using only `awk`, `grep`, `sed`, `tr`,
  `git`, and `jq` or `python3` to read the tool call, and must work in every
  gnomAD repo. A hook only advises (block, ask or pass): it never runs, edits
  or deletes anything itself.
- `hooks/gnomad-guard.sh` holds all the shared rules, in one commented section
  per area. A new rule goes in its area's section with a comment saying what
  it catches and why, and the area is listed in `README.md`, under **Hooks**.
- Every rule has cases in `tests/test_gnomad_guard.sh`, including one that
  must pass; add a case for each miss or false alarm before fixing it. Use
  placeholder names in them (`gs://my-bucket`, `my-cluster`, `my-branch`),
  never a person's own buckets, clusters or paths.
- Don't add CI, packaging or docs tooling; the repo is Markdown, a few shell
  and standard-library scripts, and a pre-commit config, which also runs the
  hook's tests.

## Commits and attribution

- One short imperative subject line; a body only when the subject can't carry
  the context.
- No agent trailers or agent co-author lines on commits. Mention the
  assistance in the PR body instead: `Assisted by Claude Code.`
  (`.claude/settings.json` sets `attribution.pr` to that line and
  `attribution.commit` to nothing, so Claude Code does this by itself.)
