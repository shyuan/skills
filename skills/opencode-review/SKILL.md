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

- `OPENCODE_REVIEW_PROVIDER=<id>` — reach the **default** models through a provider one level
  up, e.g. `omniroute` → `omniroute/opencode-go/glm-5.2`. For a setup that fronts several
  OpenCode plans with a router, this is what spreads a run's four calls (two of them
  concurrent) across the plans instead of stacking them on one account. Unset (the default)
  the ids are used directly, unchanged. It applies to the four defaults only — an explicit
  `*_MODEL` below is always a full id, so spell the provider into it if you want it routed.
  Caveat: a router configured as a generic OpenAI-compatible provider is not in models.dev,
  so opencode has no context/output limits for its models and a diff that overruns one
  surfaces as a provider error rather than an up-front warning. Declare `limit` on those
  models in `opencode.jsonc` if that bites.
- `OPENCODE_REVIEW_SWE_MODEL` / `OPENCODE_REVIEW_ARCH_MODEL` / `OPENCODE_REVIEW_CHAIR_MODEL`
  — override the committee's models (defaults: `opencode-go/kimi-k2.7-code`, `opencode-go/glm-5.2`,
  `opencode-go/qwen3.7-max`).
- `OPENCODE_REVIEW_MODEL=<id>` — skip the committee and run a single model (with the SWE persona).
- `OPENCODE_REVIEW_AGENT=<name>` — escape hatch: run a single **pre-configured** opencode
  agent via `--agent` (must be `mode:primary`).
- `OPENCODE_REVIEW_RULES=0` — disable the file-type checklist injection (default on).
- `OPENCODE_REVIEW_DEP_DIRS=<dir>[:<dir>…]` — extra dependency-source directories the file
  tools may read (Go's `GOMODCACHE` and `$CARGO_HOME/registry` are detected automatically).
- `OPENCODE_REVIEW_FACTCHECK=0` — disable the phase-3 fact-check pass (default on).
- `OPENCODE_REVIEW_FACTCHECK_MODEL=<id>` — model for the fact-check pass (default
  `opencode-go/deepseek-v4-pro`; reasoning-strong and independent of the chair model).
- `OPENCODE_REVIEW_TIMEOUT=<seconds>` — per-model hard timeout (default `900`).
- `OPENCODE_REVIEW_STAGGER=<seconds>` — delay between the two parallel member launches
  (default `3`), to avoid opencode's session-init "database is locked" startup race.

The script captures each model's full output (both streams — the report is emitted on
OpenCode's render stream, not its final stdout message), **extracts the report from that
capture**, and prints the chair's consolidated report to **stdout** between the
`===== … REVIEW … =====` and `===== END OF REVIEW =====` markers. Only the script's own
progress/error lines (prefixed `[opencode-review]`) go to **stderr**. If the chair fails or
times out, the two member reports are printed as a fallback so you still have something
actionable.

Extraction matters because the capture is a *transcript*, not a report: it also holds
tool-call headers, tool output (each member echoes the whole diff), ANSI escapes, and — on
every denied bash call — the entire `OPENCODE_PERMISSION` ruleset as JSON. So each persona is
told to fence its report between `<<<REVIEW-REPORT>>>` and `<<<END-REVIEW-REPORT>>>`, and
every stage passes on only what is between them. If a model ignores the fence the script
falls back to a de-noised transcript (tool blocks and escapes dropped) and says so in the log.

The markers carry a **per-run nonce**: `prompts/*.md` hold the bare token, and `read_prompt`
rewrites it to `<<<REVIEW-REPORT-<random>>>>` on the way into each message. The fence is
allowed to outrank the render heuristics, so whatever can emit a marker line controls what is
taken as the report — and the tree under review can emit one, since members are told to read
related files and `cat`/`head`/`tail` print content verbatim. A fixed marker would also break
on this repo, whose own `prompts/*.md` contain the literal token. Edit the personas using the
bare token; never hardcode a nonced marker.

De-noising reads opencode's render structure, and that structure is not fully reliable: a
tool block is ended by a separator line or an error banner, and a tool call that renders no
output block (`Read`) emits no separator — so when it is the last call before the report, the
report begins on the very next line and would be read as more output from that tool. The
fence therefore outranks the state machine: a `<<<REVIEW-REPORT>>>` line ends a tool block
wherever it appears. This is why the fence matters beyond tidiness, and why the personas
insist on it.

There is deliberately **no** "recover it anyway" pass. Dropping the tool-output rule does
salvage a swallowed report, but it cannot tell that report from tool output — so a model that
runs `git diff` and then stops would have its own diff forwarded as its review, and the run
called `ok`. An unfenced report emitted with no separator has no anchor to recover from, so
it is reported blank and its transcript kept.

A stage that exits 0 having written **no** report is reported as
`NO REPORT PRODUCED (run ok)`, not `ok`, in both the log and the message handed to the
chair — so `prompts/chair.md`'s "note which member is absent" rule can fire, and the run's
exit status is non-zero. A run that yielded nothing can no longer look successful.

Whenever a stage produces no extractable report, its raw transcript is copied into a
per-run `mktemp -d` directory (mode 700) and the path is logged. Everything else the script
writes is a temp file removed on exit, and a blank stage prints nothing, so without this copy
there is no way to tell a model that said nothing from a de-noiser that ate the report. **If
a run reports a blank stage, read that file before concluding the model was silent.**

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
- `OPENCODE_PERMISSION` is set **for this run only** — it is merged with the saved config
  rather than substituted for it, and the saved config is not modified. `edit` is denied, and
  bash is **default-deny with a read-only allow-list** (git reads plus
  `cat`/`head`/`tail`/`wc`/`ls`/`grep`/`rg`). Trailing deny patterns for shell metacharacters
  (`;`, `|`, `&`, `>`, backticks, `$(`, `<(`, newline) override the allows, so an allowed
  prefix can't smuggle chained commands, pipes into a shell, or redirection writes. The diff
  under review is untrusted input to the reviewer models, so this hardens against prompt
  injection as well as keeping the (possibly uncommitted) work tree read-only — though glob
  matching makes it defense-in-depth, not a hard sandbox. `question` and `doom_loop` are
  denied so the run can't stall waiting for input that will never come headless.
- **What the boundary actually is.** The bash patterns are path-agnostic — `head *` matches
  `head /anywhere` — so the allow-list restricts *commands*, not *paths*: reads outside the
  repo have always been possible when spelled as a shell command. The file tools are gated
  separately by `external_directory`, whose default for an unlisted path is "ask", i.e. an
  auto-reject headless. The two routes therefore used to disagree about the same file, which
  cost members turns on rejected `Read` calls (#24). The script now allows file-tool reads
  under the dependency caches it finds (Go's module cache, `$CARGO_HOME/registry`, plus
  anything in `OPENCODE_REVIEW_DEP_DIRS`) so the ergonomic route works where it matters: for a
  diff whose assertions encode a dependency's contract, that source *is* the review question.
  Only allows are written, never a blanket deny — a `"*":"deny"` here would also override
  opencode's own entries and any the user has configured, since the two are merged. The Go
  path is resolved from `GOMODCACHE`/`GOPATH`/the `go env` file rather than by running
  `go env`: the script has to run PATH-resolved `git` and `opencode` from the repo root
  before any permission set exists, but an optional convenience should not widen that.
- **The personas state these boundaries up front** rather than letting models find them by
  hitting them: no test/build execution (that would run code from the untrusted diff), what is
  readable and how, no retrying a rejected call, and — because two members once ended a run on
  a rejected call having written nothing — produce a report regardless, noting what could not
  be verified.
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
