# Contributing

Thanks for your interest in adding to this collection. Each skill is a self-contained folder
under [`skills/`](./skills) that follows the [Agent Skills](https://docs.claude.com/en/docs/claude-code/skills)
`SKILL.md` convention.

## Adding a skill

1. Create a folder: `skills/<skill-name>/` (lowercase, hyphenated, matching the `name` in
   frontmatter).
2. Add a `SKILL.md` with YAML frontmatter:

   ```yaml
   ---
   name: my-skill-name
   description: >-
     What the skill does and, crucially, WHEN to use it. Write the description so an agent
     can decide from it alone whether to trigger — include the situations and trigger phrases
     that should activate it, and note what it is NOT for.
   ---

   # My Skill Name

   Instructions the agent follows when the skill is active.
   ```

3. Put supporting material in conventional subfolders (all optional):

   ```
   skills/<skill-name>/
     SKILL.md          # required
     references/       # deep-dive docs the skill loads on demand
     scripts/          # executable helpers (chmod +x; commit the bit)
     assets/           # checklists, templates, etc.
   ```

## Conventions

- **`name`** is lowercase-kebab-case and matches the folder name.
- **`description`** is the most important field — it is what an agent reads to decide whether
  to invoke the skill. Cover the *when* (triggers) and the *when not*.
- Keep `SKILL.md` focused; push long material into `references/` so it loads only when needed.
- Make scripts executable (`chmod +x`) and commit the executable bit so they run after a clone.
- Don't commit machine-local config (e.g. `.claude/settings.local.json`) — it's gitignored.

## Third-party content

If a skill bundles material from another project, preserve its license and attribution. For
example, `opencode-review/prompts/rules/` ships verbatim Apache-2.0 files from
[alibaba/open-code-review](https://github.com/alibaba/open-code-review) together with their
`LICENSE` and an `ATTRIBUTION.md`. Follow the same pattern: include the upstream license text
and state clearly which files are copied (and whether modified).

## Before opening a PR

- Verify the skill loads and behaves as described.
- Keep one skill per PR where practical, and explain what it does and when it triggers.

This repository is licensed under [MIT](./LICENSE); contributions are accepted under the same
license (third-party bundled content keeps its own license, as above).
