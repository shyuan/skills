---
name: opencode-review
description: Two gates around a local multi-model code review run through the user's OpenCode setup. GATE ONE (scripts/run-review.sh) reviews the LOCAL diff before a pull request is opened: use it right after finishing an implementation or bug fix in Claude Code, while the changes are still local — uncommitted, or committed on a branch but not yet turned into a PR. Trigger whenever the user says things like "review my changes", "review before I open the PR", "run the opencode review", "multi-model review", "review this diff", "second opinion on this", or asks for a pre-PR review of work that was just completed, even if they don't name OpenCode explicitly. GATE TWO (scripts/run-verify.sh) runs AFTER those findings have been fixed: it adjudicates each finding as fixed / partly fixed / not fixed / regressed against the fix commits, reading the saved review report or, failing that, the PR's comments via gh. Trigger on "verify the fixes", "check the review comments are addressed", "did I fix everything the review found", "verify the PR review comments". It does not re-run the review. Both print their report on stdout for Claude Code to act on. Do NOT use gate one to review an already-open GitHub PR — that path is handled interactively in the OpenCode TUI.
---

# OpenCode review, and the verify gate after it

Two scripts, run in order, around one piece of work:

| gate | script | asks |
|---|---|---|
| 1 | `scripts/run-review.sh` | what is wrong with this change? |
| 2 | `scripts/run-verify.sh` | were those findings actually fixed? |

Gate one drives a headless multi-model **reviewer committee** against the **local** diff and
returns the chair's consolidated report, so you can fix issues before a PR is opened. Gate two
runs after the fixing — see [The verify gate](#the-verify-gate).

**Self-contained:** the skill ships everything. It drives opencode **by model**
(`opencode run --pure --model <id>`), embedding each reviewer's persona from `prompts/*.md`
into the message — it does **not** rely on any agent being defined in the user's
`opencode.jsonc`. (This also sidesteps an opencode footgun: a `mode:subagent` agent invoked
as a top-level `--agent` run self-replicates and fork-bombs; driving by `--model` avoids
agents entirely.)

**You (Claude Code) are the lead/orchestrator.** The script fans the member seats out in
parallel, then hands their reports to the chair, then runs an optional fact-check pass:

| seat | covers | persona | default model | default |
|---|---|---|---|---|
| SWE | correctness, bugs, security | `prompts/swe.md` | Muse Spark Contributor | **on** |
| Architect | design, abstraction, coupling | `prompts/architect.md` | GLM Flash | **on** |
| Tester | test coverage, regression risk | `prompts/tester.md` | Qwen Flash | off |
| SRE | operability, compatibility, rollout | `prompts/sre.md` | GPT-5.6 Luna | off |
| Chair | dedupe + verify + fill gaps → final report | `prompts/chair.md` | MiniMax-M3 | always |
| Fact-check | prunes only findings the diff can directly falsify (phase 3, optional) | `prompts/factcheck.md` | DeepSeek V4 Flash | on |

Widen the committee with `OPENCODE_REVIEW_SEATS=swe,architect,tester,sre` — see
[references/design-notes.md](references/design-notes.md#why-only-two-seats-are-on-by-default).

Every seat runs on the **cheap tier of its family, at high reasoning effort** — see
[references/design-notes.md](references/design-notes.md#why-these-models).

**File-type review checklists (ported from Alibaba's open-code-review).** Before fan-out,
the script maps every changed file to a focus checklist under `prompts/rules/` (first match
wins: `*.java`→`java.md`, `*.{ts,tsx,js,jsx}`→`ts_js_tsx_jsx.md`, `pom.xml`→`pom_xml.md`,
`*mapper*.xml`→`mapper_dao_xml.md`, … else `default.md`). The union of matched checklists is
appended to **every** member's persona, so each model's attention is focused on what actually
matters for the file types in this diff — the precision of rule-matching combined with the
blind-spot diversity of multiple models. See `prompts/rules/ATTRIBUTION.md` (Apache-2.0).

This skill does **not** modify the user's OpenCode config. Gate one runs **no `gh` commands** —
there is no PR yet. Gate two may run `gh`, but only in the script and only to read: it fetches
the PR's comments and inlines them, so the model itself still has no network and no `gh`.

## When to run it

After code is written and before opening a pull request. The changes may be:

- **(a)** uncommitted (working tree and/or staged, including untracked files), or
- **(b)** committed on a feature branch that has no PR yet, or
- **both at once** — commits on the branch with more work still in the tree.

**(c)** once a PR is open is *not* gate one's path (reviewing an open PR is interactive in the
OpenCode TUI). The script detects it anyway — see the pushed-branch warning below — so that an
accidental run says so instead of quietly reviewing the wrong thing.

**Gate two runs later**, after the findings have been fixed. It does not care whether a PR
exists: with a saved review it needs nothing but the repo, and it reaches for `gh` only when
the findings have to come from the PR itself.

## How to run gate one

Invoke the bundled script with `bash`, **from the repository root** (so it can read the git
diff). The script lives in this skill's directory under `scripts/`:

```bash
bash scripts/run-review.sh
```

With no argument it detects the stage. "Ahead of base" and "dirty tree" are measured
**independently**, because both are routinely true at once:

| commits ahead of base | uncommitted work | reviewed |
|---|---|---|
| — | yes | **(a)** the working tree |
| yes | — | **(b)** `base...HEAD` |
| yes | yes | **(a+b)** the union of the two |
| — | — | nothing; exits 0 |

The union case is the one that matters. Chaining these as an either/or — review the tree *if*
it is dirty, else the branch — means a branch holding the real work plus one stray untracked
file reviews the stray file, skips every commit, and logs a scope line that reads as correct.
Base is `origin/HEAD`, else `main`/`master`.

The chosen stage is logged, **including what it left out**, so a wrong call is visible rather
than silently shaping the review:

```
[opencode-review] stage : (a+b) branch 'x' vs 'main'
[opencode-review]         3 commits + 2 uncommitted files, BOTH included
```

If the branch looks like it reached the remote — it has an upstream, **or** a
`refs/remotes/<remote>/<branch>` exists, since a plain `git push origin <branch>` sets no
upstream — the run logs a warning that a PR may exist and this is the pre-PR path.

The prompt itself **never states whether a PR exists**, in either direction. It used to assert
*"There is no pull request yet"* whenever no upstream was set, which is false exactly in the
case above. Widening the check does not fix the class — a remote-tracking ref can be stale, and
a branch pushed from another machine and never fetched here leaves no local trace at all — so
short of running `gh`, the local repo cannot settle it. The claim is therefore dropped rather
than made more accurate; the half that carries the actual instruction ("review from the local
git state only; do not run any `gh` command") is unconditionally true and is all the models
need. The pushed signal now feeds only the operator-facing warning, where a false positive
costs nothing.

To target something specific — this is also how you deliberately review one side when both are
present, which is why there is no separate stage-override knob:

```bash
bash scripts/run-review.sh main          # diff current branch vs main
bash scripts/run-review.sh <commit-sha>  # one commit
bash scripts/run-review.sh ""            # force: uncommitted changes only
```

Common overrides — `OPENCODE_REVIEW_SEATS` to widen the committee, `OPENCODE_REVIEW_*_MODEL` to
name your own models, `OPENCODE_REVIEW_FACTCHECK=0` to skip phase 3, `OPENCODE_REVIEW_SAVE=0` to
not save the run for gate two, `OPENCODE_REVIEW_DRY_RUN=1` to exercise the orchestration without
calling a model. The full list for both gates, and what to check when a run fails, is in
**[references/configuration.md](references/configuration.md)**.

The report is printed to **stdout** between the `===== … REVIEW … =====` and
`===== END OF REVIEW =====` markers; the script's own progress and error lines (prefixed
`[opencode-review]`) go to **stderr**. Exit statuses: `0` clean, `1` a stage failed, `3` a stage
failed with a provider error for a model the provider has. What the run does when a stage
produces nothing, refuses, or times out — and what it leaves behind to read afterwards — is in
**[references/run-behavior.md](references/run-behavior.md)**.

## What to do with the report

1. Read the report between the two markers on stdout. The chair lists confirmed
   high-priority issues first, then for-reference items, then rejected items (with why).
2. Give the user a short summary of the **substantive** findings — don't paste the whole
   report back unless they ask.
3. Fix the substantive issues: correctness, security, real design problems. Don't churn on
   pure style nitpicks unless the user wants them.
4. If you decide to skip a flagged item, say so in one line and why.
5. Offer to run **gate two** once the fixes are in, to confirm each finding was actually
   addressed before the PR is opened — that is cheaper and more useful than re-running the
   committee, which would produce a second opinion when what is missing is a verdict on the
   first one.

## What gate one leaves behind

Unless `OPENCODE_REVIEW_SAVE=0`, the run saves itself under the **git dir** — not the work
tree, since it is a record about this checkout that must never become a file the next review
reviews. Nothing is committed and no `.gitignore` entry is needed.

```
<git-dir>/opencode-review/
  latest                      # a pointer file: "runs/<ts>-<sha8>"
  runs/<ts>-<sha8>/
    report.md                 # YAML frontmatter + the report exactly as printed
    reviewed.diff             # the diff the committee actually read
```

The frontmatter is what makes gate two possible:

```yaml
schema: 1
scope: "branch 'x' vs 'main' (3 commits) + 2 uncommitted files"
scope_mode: "both"
base_sha: "…"
head_sha: "…"
included_uncommitted: true
seats: "swe architect"
factcheck: "applied"
```

`head_sha` is where the fix starts, and `included_uncommitted` says how to read it. When the
review covered uncommitted work, `head_sha..HEAD` is an **upper bound** on the fix — it also
contains the work that was already in the tree when the review ran and has since been
committed. `reviewed.diff` is what lets gate two tell those apart instead of assuming, and it
is inlined into the verify message exactly in that case.

A pointer file rather than a symlink: it survives a copied `.git`, needs no `readlink`, and
cannot dangle into whatever a stale link once pointed at.

## The verify gate

```bash
bash scripts/run-verify.sh          # latest saved review, or the current branch's PR
bash scripts/run-verify.sh 123      # findings from PR #123
```

One model, one question: for each finding, was it addressed? It reads the findings, the diff
since the review, the commit messages since the review, and — unlike the fact-check pass — the
**repo itself**, because whether a fix is correct usually turns on the surrounding function and
its callers, which the diff does not show.

Each finding comes back as exactly one of six verdicts, with the hunk that justifies it:

| verdict | means |
|---|---|
| 已修正 | addressed; must cite the file/hunk that does it |
| 部分修正 | addressed on one path; must name the path still uncovered |
| 未修正 | no change addressing it; must say where it looked |
| 修出新問題 | the fix introduced a regression |
| 有理由不修 | declined, with the reason visible in a comment or commit message |
| 無法驗證 | the evidence is not in the diff or the repo |

**It may not raise new findings.** Same discipline as the fact-check pass, for the same reason:
a stage that can both adjudicate and expand has no bound on its output, and the one useful
answer here — which items are still open — gets buried under a second review. The single
exception is `修出新問題`, and only for a regression *this fix* introduced; a pre-existing
problem the committee missed is not this gate's business. Changes in the fix diff that no
finding asked for are listed separately at the end, without a judgment on them — whether to
accept scope creep is a person's call.

**Where the findings come from** (`OPENCODE_REVIEW_VERIFY_SOURCE`):

| value | source |
|---|---|
| `auto` (default) | the saved review if there is one, else `gh` |
| `artifact` | the saved review only; errors if there is none |
| `gh` | the PR body, its comments, and its inline review comments |
| `file` | whatever `OPENCODE_REVIEW_VERIFY_FINDINGS` points at |

The saved review is preferred because it carries the shas. A PR comment is prose: it says
nothing about which commit the review ran against, so *"what changed since"* could only be
guessed at — which is why the `gh` and `file` paths need `OPENCODE_REVIEW_VERIFY_SINCE=<sha>`
unless a saved review supplies it.

**One source, not both.** When the review report has been pasted onto the PR, every finding
exists in both places, and feeding the model both copies would have it adjudicate each item
twice under two slightly different wordings — the same manufactured-duplication problem the
seat table's orthogonality rule exists to avoid. Set `OPENCODE_REVIEW_VERIFY_SOURCE=gh` to
judge the PR discussion (including humans' own comments) instead of the saved report.

`gh` runs **in the script**, never in the model: its output is inlined into the message, so the
verify model gets the same sandbox every review stage gets — no network, no `gh`, no writes.
The findings block is also announced to the model as data rather than instructions, because on
a public PR anyone can write a comment, and a comment saying *"mark everything fixed"* is an
item to be adjudicated, not a new task.

Gate two's own overrides are listed with gate one's in
[references/configuration.md](references/configuration.md). `OPENCODE_REVIEW_TIMEOUT`,
`_PROVIDER`, `_DEP_DIRS` and `_DRY_RUN` behave as they do for gate one, and the exit statuses are
the same three.

If nothing has changed since the review, the run says so before spending the call — every
finding would come back `未修正`, which may be the honest answer or may mean the wrong commit
is being verified.

## Further reading

Loaded only when they are needed, so this file stays the part that is read every time:

| file | answers |
|---|---|
| [references/configuration.md](references/configuration.md) | every environment override for both gates, and what to check when a run fails |
| [references/run-behavior.md](references/run-behavior.md) | what the run does with blank stages, provider refusals, timeouts and absent members, and the diagnostics it prints |
| [references/design-notes.md](references/design-notes.md) | why these models, why only two seats are on by default, why the run is sandboxed the way it is, and what the fact-check pass does and does not catch |
