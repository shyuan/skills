# AGENTS.md

Guidance for coding agents working in this repository. Human contributors: see
[CONTRIBUTING.md](./CONTRIBUTING.md).

## What this repo is

A curated catalog of [Agent Skills](https://docs.claude.com/en/docs/claude-code/skills). It is
**not** an application — there is no build, no test suite, no package to publish. Each skill is a
self-contained folder that another agent consumes; the repo's job is to keep those folders correct
and discoverable.

## Layout

```
skills/
  <skill-name>/
    SKILL.md          # required: frontmatter (name, description) + instructions
    references/       # optional: deep-dive docs loaded on demand
    scripts/          # optional: executable helpers
    assets/           # optional: checklists, templates
```

Flat structure — one level of skill folders under `skills/`, no category buckets.

## Invariants (keep these true)

- Every skill folder contains a `SKILL.md` with YAML frontmatter that has at least `name` and
  `description`.
- The folder name **equals** the `name` in frontmatter, in lowercase-kebab-case.
- Every skill is listed in the **Skills** table in [README.md](./README.md), with its name linked
  to its folder. Adding or removing a skill means updating that table in the same change.
- Scripts are committed with the executable bit set (`git ls-files -s` shows `100755`), so they run
  after a clone.
- Machine-local agent config (e.g. `.claude/settings.local.json`) is never committed; it is
  gitignored. Don't add it back.

## Editing skills

- Treat each `SKILL.md`'s `description` as load-bearing: it is what an agent reads to decide whether
  to invoke the skill. When you change behavior, keep the description's *triggers* and *not-for*
  notes accurate.
- Keep `SKILL.md` focused; put long material in `references/` so it loads only when needed.
- Don't rename a skill folder without updating the frontmatter `name` and the README table together.

## Third-party content

Some skills bundle material from other projects. Preserve the upstream license and attribution
exactly:

- `skills/opencode-review/prompts/rules/` ships **unmodified, verbatim** Apache-2.0 files from
  [alibaba/open-code-review](https://github.com/alibaba/open-code-review) (Copyright 2026 Alibaba),
  alongside a copy of their `LICENSE` and an `ATTRIBUTION.md`. Do not edit those copied files; if
  upstream changes, re-copy and note it. `go.md` is the one original file in that directory.

When adding bundled content, follow the same pattern: include the upstream license text, and state
in `ATTRIBUTION.md` which files are copied and whether they were modified.

## License

The repository is [MIT](./LICENSE). Bundled third-party content keeps its own license (see above).
