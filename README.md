# skills

A curated collection of [Agent Skills](https://docs.claude.com/en/docs/claude-code/skills) for
Claude Code (and other agents that follow the same `SKILL.md` convention).

Each subfolder under [`skills/`](./skills) is one self-contained skill: a `SKILL.md` with YAML
frontmatter (`name` + `description`) plus any supporting references, scripts, or assets the skill
needs at runtime.

## Skills

| Skill | What it does |
| --- | --- |
| [`complete-test-code`](./skills/complete-test-code) | Writes, audits, and hardens test code with SQLite-grade rigor — fuzzing, property/differential/metamorphic testing, fault injection, mutation testing, coverage — right-sized to each component's blast radius. |
| [`opencode-review`](./skills/opencode-review) | Runs a local, headless multi-model "reviewer committee" over your **local** diff *before* a PR is opened, and returns a consolidated report to act on. |

## Layout

```
skills/
  <skill-name>/
    SKILL.md          # required: frontmatter (name, description) + instructions
    references/       # optional: deep-dive docs the skill loads on demand
    scripts/          # optional: executable helpers
    assets/           # optional: checklists, templates, etc.
```

## Using a skill

**Claude Code** — drop a skill folder into your skills directory so the agent can discover it:

```bash
# personal (all projects)
cp -R skills/complete-test-code ~/.claude/skills/

# or per-project
cp -R skills/complete-test-code .claude/skills/
```

Then the skill is invoked automatically when its `description` matches what you ask for, or
explicitly via its `name`.

Other agents that support the `SKILL.md` standard (OpenCode, Cursor, Cline, …) can consume these
folders directly or via tooling such as [`npx skills add`](https://github.com/vercel-labs/skills).

## License

[MIT](./LICENSE).

The file-type review checklists under
[`skills/opencode-review/prompts/rules/`](./skills/opencode-review/prompts/rules) — except `go.md`,
which is original — are **unmodified, verbatim copies** from Alibaba's
[open-code-review](https://github.com/alibaba/open-code-review) (Copyright 2026 Alibaba, Apache-2.0).
A copy of the Apache-2.0 license travels with them as
[`rules/LICENSE`](./skills/opencode-review/prompts/rules/LICENSE); see
[`ATTRIBUTION.md`](./skills/opencode-review/prompts/rules/ATTRIBUTION.md) in that directory for details.
