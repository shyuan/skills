---
name: opencode-review
description: Run a local multi-model code review through the user's OpenCode setup BEFORE a pull request is opened. Use this right after finishing an implementation or bug fix in Claude Code, while the changes are still local — uncommitted, or committed on a branch but not yet turned into a PR — and the user wants an independent review pass before pushing. Trigger whenever the user says things like "review my changes", "review before I open the PR", "run the opencode review", "multi-model review", "review this diff", "second opinion on this", or asks for a pre-PR review of work that was just completed, even if they don't name OpenCode explicitly. Returns a consolidated review report on stdout for Claude Code to act on. Do NOT use this for reviewing an already-open GitHub PR — that path is handled interactively in the OpenCode TUI and uses gh.
---

# OpenCode pre-PR review

Drives a headless multi-model **reviewer committee** against the **local** diff and returns
the chair's consolidated report so you can fix issues before a PR is opened.

**Self-contained:** the skill ships everything. It drives opencode **by model**
(`opencode run --pure --model <id>`), embedding each reviewer's persona from `prompts/*.md`
into the message — it does **not** rely on any agent being defined in the user's
`opencode.jsonc`. (This also sidesteps an opencode footgun: a `mode:subagent` agent invoked
as a top-level `--agent` run self-replicates and fork-bombs; driving by `--model` avoids
agents entirely.)

**You (Claude Code) are the lead/orchestrator.** The script fans out to two members in
parallel, then hands both reports to the chair, then runs an optional fact-check pass:
- SWE — correctness/bugs/security (`prompts/swe.md`, default model Kimi)
- Architect — design/architecture (`prompts/architect.md`, default model GLM)
- Chair — dedupe + verify + fill gaps → final report (`prompts/chair.md`, default model Qwen)
- Fact-check (optional, phase 3) — prunes only findings the diff can directly falsify
  (`prompts/factcheck.md`, default model DeepSeek V4 Pro)

**File-type review checklists (ported from Alibaba's open-code-review).** Before fan-out,
the script maps every changed file to a focus checklist under `prompts/rules/` (first match
wins: `*.java`→`java.md`, `*.{ts,tsx,js,jsx}`→`ts_js_tsx_jsx.md`, `pom.xml`→`pom_xml.md`,
`*mapper*.xml`→`mapper_dao_xml.md`, … else `default.md`). The union of matched checklists is
appended to **both** members' personas, so each model's attention is focused on what actually
matters for the file types in this diff — the precision of rule-matching combined with the
blind-spot diversity of multiple models. See `prompts/rules/ATTRIBUTION.md` (Apache-2.0).

This skill does **not** modify the user's OpenCode config, and runs **no `gh` commands** —
there is no PR yet.

## When to run it

After code is written and before opening a pull request. The changes may be:

- uncommitted (working tree and/or staged), or
- committed on a feature branch that has no PR yet.

## How to run it

Invoke the bundled script with `bash`, **from the repository root** (so it can read the git
diff). The script lives in this skill's directory under `scripts/`:

```bash
bash scripts/run-review.sh
```

With no argument it auto-detects the scope:

- if `git status` shows uncommitted/untracked changes → reviews the working tree;
- otherwise, if the current branch is ahead of its base (`origin/HEAD`, else `main`/`master`)
  → reviews `base...HEAD`.

To target something specific:

```bash
bash scripts/run-review.sh main          # diff current branch vs main
bash scripts/run-review.sh <commit-sha>  # one commit
bash scripts/run-review.sh ""            # force: uncommitted changes
```

Optional environment overrides:

- `OPENCODE_REVIEW_SWE_MODEL` / `OPENCODE_REVIEW_ARCH_MODEL` / `OPENCODE_REVIEW_CHAIR_MODEL`
  — override the committee's models (defaults: `opencode-go/kimi-k2.7-code`, `opencode-go/glm-5.2`,
  `opencode-go/qwen3.7-max`).
- `OPENCODE_REVIEW_MODEL=<id>` — skip the committee and run a single model (with the SWE persona).
- `OPENCODE_REVIEW_AGENT=<name>` — escape hatch: run a single **pre-configured** opencode
  agent via `--agent` (must be `mode:primary`).
- `OPENCODE_REVIEW_RULES=0` — disable the file-type checklist injection (default on).
- `OPENCODE_REVIEW_FACTCHECK=0` — disable the phase-3 fact-check pass (default on).
- `OPENCODE_REVIEW_FACTCHECK_MODEL=<id>` — model for the fact-check pass (default
  `opencode-go/deepseek-v4-pro`; reasoning-strong and independent of the chair model).
- `OPENCODE_REVIEW_TIMEOUT=<seconds>` — per-model hard timeout (default `900`).
- `OPENCODE_REVIEW_STAGGER=<seconds>` — delay between the two parallel member launches
  (default `3`), to avoid opencode's session-init "database is locked" startup race.

The script captures each model's full output (both streams — the report is emitted on
OpenCode's render stream, not its final stdout message) and prints the chair's consolidated
report to **stdout** between the `===== … REVIEW … =====` and `===== END OF REVIEW =====`
markers. Only the script's own progress/error lines (prefixed `[opencode-review]`) go to
**stderr**. If the chair fails or times out, the two raw member reports are printed as a
fallback so you still have something actionable.

## What to do with the report

1. Read the report between the two markers on stdout. The chair lists confirmed
   high-priority issues first, then for-reference items, then rejected items (with why).
2. Give the user a short summary of the **substantive** findings — don't paste the whole
   report back unless they ask.
3. Fix the substantive issues: correctness, security, real design problems. Don't churn on
   pure style nitpicks unless the user wants them.
4. If you decide to skip a flagged item, say so in one line and why.
5. Offer to re-run this skill after fixing, to confirm it's clean before the PR is opened.

## Prerequisites

These are already true in the user's environment; only check them if the run fails:

- `opencode` is on `PATH`, with the chosen models authenticated (same providers as the TUI).
  Only **model access** is required — no committee agents need to exist in `opencode.jsonc`.
- The persona files exist in this skill directory (shipped with the skill):
  `prompts/swe.md`, `prompts/architect.md`, `prompts/chair.md`, `prompts/factcheck.md`, and
  the file-type checklists under `prompts/rules/`.
- The current working directory is inside a git repository.

## Why the run is configured the way it is

- Driven by `--model` (not `--agent`): self-contained (no config dependency) and avoids the
  `mode:subagent`-as-top-level self-replication fork bomb.
- `--pure` skips external plugins, so startup is lean and there's no port to collide on.
- `OPENCODE_PERMISSION` is set **for this run only** (the saved config is untouched):
  `edit` is denied, and bash is **default-deny with a read-only allow-list** (git reads plus
  `cat`/`head`/`tail`/`wc`/`ls`/`grep`/`rg`). Trailing deny patterns for shell metacharacters
  (`;`, `|`, `&`, `>`, backticks, `$(`, `<(`, newline) override the allows, so an allowed
  prefix can't smuggle chained commands, pipes into a shell, or redirection writes. The diff
  under review is untrusted input to the reviewer models, so this hardens against prompt
  injection as well as keeping the (possibly uncommitted) work tree read-only — though glob
  matching makes it defense-in-depth, not a hard sandbox. `question` and `doom_loop` are
  denied so the run can't stall waiting for input that will never come headless.
- `GIT_PAGER=cat` / `PAGER=cat` stop git from opening a pager that would hang in a non-TTY.
- The two members run in parallel, then the chair runs once, then the optional fact-check runs
  once — so a large diff can take a few minutes. Each model run has its own timeout; a hung
  member can't block the others, the chair, or the fact-check.
- The fact-check pass can only ever *remove* false positives: on any failure/timeout/empty
  output the chair's report is emitted unchanged, and removed items are listed transparently
  (not silently dropped) so you can override the call.

## What the fact-check pass does and does not catch

The fact-check pass (phase 3) is a deliberately **narrow, safe** precision filter, not a
general noise reducer. Its coverage boundary, confirmed empirically across controlled and
real-commit A/B runs:

- **It fires only on diff-*internal* falsifiable claims** — findings the supplied diff itself
  directly contradicts (e.g. "no nil check" when the diff shows one; "variable unused" when the
  diff shows it returned). On a planted-false-positive fixture it lifted surfaced-finding
  precision from ~60% to 100% with zero recall loss.
- **It deliberately does not touch claims about code outside the diff.** A reviewer member may
  have read other files via tools; fact-check sees only the diff, so by its "falsify, not
  verify" rule it keeps anything it cannot directly disprove. In a real A/B where a weak chair
  over-reached into other files (`agent.go`, `llm_cmd.go`), every such item was kept — and those
  items turned out to be *true* adjacent findings, so keeping them was correct.
- **Consequence — its real-world hit rate is low, by design.** Two upstream effects usually
  leave it nothing to remove: (1) a capable chair already rejects shaky items during synthesis,
  and (2) most committee noise on real diffs is out-of-diff over-reach, which is outside this
  pass's scope. Treat fact-check as a cheap last-resort safety net for the case where the chair
  lets a diff-contradicted claim slip through — not as the main precision lever. The main lever
  is a strong chair model.
- If you specifically want to catch out-of-diff over-reach too, that requires giving the
  fact-checker repo read access — which trades away the "diff-only ⇒ can never over-prune"
  safety guarantee, and costs more time/tokens. The current design intentionally keeps the
  safety guarantee instead.
