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

- **(a)** uncommitted (working tree and/or staged, including untracked files), or
- **(b)** committed on a feature branch that has no PR yet, or
- **both at once** — commits on the branch with more work still in the tree.

**(c)** once a PR is open is *not* this skill's path (that one is interactive in the OpenCode
TUI and uses `gh`). The script detects it anyway — see the pushed-branch warning below — so
that an accidental run says so instead of quietly reviewing the wrong thing.

## How to run it

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
- `OPENCODE_REVIEW_FACTCHECK_DIFF_MAX=<bytes>` — how much of the diff is inlined into the
  phase-3 message before it is truncated (default `200000`). The fact-checker is given the diff
  itself, not an instruction to fetch one, since it may only prune findings that diff
  contradicts. Truncation is announced in the text with a marker rather than done silently —
  the pass has to know the diff is partial in order to keep findings about the part it cannot
  see. Raise this if you suspect relevant findings fall in the truncated tail.
- `OPENCODE_REVIEW_TIMEOUT=<seconds>` — per-model hard timeout (default `900`).
- `OPENCODE_REVIEW_STAGGER=<seconds>` — delay between the two parallel member launches
  (default `3`), to avoid opencode's session-init "database is locked" startup race.

Each stage runs with **`--format json`**, so what the script captures is opencode's event
stream — one JSON object per line — not a rendered transcript. The chair's consolidated report
is printed to **stdout** between the `===== … REVIEW … =====` and `===== END OF REVIEW =====`
markers. Only the script's own progress/error lines (prefixed `[opencode-review]`) go to
**stderr**. If the chair fails or times out, the two member reports are printed as a fallback
so you still have something actionable.

**A stage's report is its `text` events, and nothing else.** The event stream separates at the
source what a rendered transcript merges into undifferentiated lines:

| event | carries |
|---|---|
| `text` | the model's own words — this is the report |
| `tool_use` | every byte a tool produced, including tool *errors* |
| `step_finish` | `reason` the model stopped: `stop`, `tool-calls`, … |

So tool output cannot be mistaken for prose: it never shares a channel with it. The whole diff
each member reads, the `OPENCODE_PERMISSION` ruleset dumped on every denied bash call, a
mistyped command's shell error — all `tool_use`, none of them candidates.

This replaced a `<<<REVIEW-REPORT>>>` fence the personas had to emit, plus a de-noiser that
inferred structure from rendered output, plus a per-run nonce on the markers. That design
failed in both directions on real runs. Models that investigated for 30–70 KB and then stopped
left nothing fenced, so the fallback ran and forwarded whatever its state machine had last
seen: one run handed the chair **150 bytes of a shell error message** as the SWE report,
another **99 bytes of a model's opening narration** as the architect's — each logged as
`ok, but the report was not fenced`, which reads as a formatting nit rather than *this is not
a review*. Reading `text` events makes that class unrepresentable. It also retires the nonce,
which existed only because a fence line was authoritative wherever it appeared and members can
`cat` repository files, so the tree under review could forge one; file content is now tool
output by construction.

Requires **`jq`** (preferred) or **`python3`** to read the stream. Checked at startup, before
any model call, so a machine with neither fails immediately rather than after four runs.

A stage that exits 0 having written **no** report is reported as `NO REPORT PRODUCED`, not
`ok`, in both the log and the message handed to the chair — so `prompts/chair.md`'s "note which
member is absent" rule can fire, and the run's exit status is non-zero. A run that yielded
nothing can no longer look successful.

The event stream also says *how* it produced nothing, which are different failures worth
telling apart:

```
[opencode-review] WARN: swe: stopped after 14 tool calls without writing anything (reason=stop).
```

That is a model that read the diff, investigated, and ended its turn without writing it up —
not a model that never ran, and not a timeout. It is the failure recorded in
[issue #33](https://github.com/shyuan/skills/issues/33), where two members did it independently
on the same run. The script detects and reports it; it does not currently intervene.

**When members are absent, the last thing on stdout says so**, inside the report markers:

```
**DEGRADED: 2 of 2 members produced no report.** Nothing above is a committee finding —
it is a solo judgment by the chair model, which read the diff itself.
```

The chair does note an absence in its own preamble, but that lands where a skimming reader
misses it — and a chair report built on no members is one model's opinion wearing a committee's
shape, which is exactly the thing the design exists to avoid.

**When a stage fails, the log also says whether the models were even available.** opencode
gives no usable answer for a bad model id — `opencode run --model does-not-exist/at-all` exits
**0** and prints a bare `UnknownError: "Unexpected server error"` that never mentions the
model — so the script would otherwise report `NO REPORT PRODUCED (run ok)` for every stage with
nothing pointing at the cause. This is the first thing anyone hits running the skill on a
machine without the default provider. So on the failure path only, the run checks the failed
stages' models against `opencode models`:

```
[opencode-review] diag  : NOT available in this OpenCode setup: opencode-go/kimi-k2.7-code …
[opencode-review] diag  : that alone accounts for an empty report — opencode exits 0 on an
                          unusable model id and reports only a generic server error.
[opencode-review] diag  : name models you do have via OPENCODE_REVIEW_{SWE,ARCH,CHAIR,…}_MODEL,
                          or set OPENCODE_REVIEW_PROVIDER=<id> if they sit behind a router.
```

When the models *are* all present it says so too — that rules out the most likely cause and
points you at the kept events instead. `opencode models` costs ~7s, so it runs **only** after
something has already failed, at most once per run; a clean run never pays for it.

Whenever a stage produces no report, its raw event stream — and its stderr, which is captured
separately since it is not JSON — is copied into a per-run `mktemp -d` directory (mode 700) and
the path logged. Everything else the script writes lives in a private work directory removed on
exit, and a blank stage prints nothing. **If a run reports a blank stage, read that file**: the
`tool_use` events show exactly what the model was doing when it stopped.

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

Only check these if the run fails — and check the `diag :` lines first, which report the most
common cause on their own:

- `opencode` is on `PATH`, with the chosen models authenticated (same providers as the TUI).
  Only **model access** is required — no committee agents need to exist in `opencode.jsonc`.
  The defaults name `opencode-go/*` models, which assumes an OpenCode Go plan; on a setup
  without one, point `OPENCODE_REVIEW_{SWE,ARCH,CHAIR,FACTCHECK}_MODEL` at models from
  `opencode models`, or set `OPENCODE_REVIEW_PROVIDER` if the same models sit behind a router.
- **`jq` or `python3` is on `PATH`** — one of them reads opencode's JSON events. Checked at
  startup, so a missing reader fails immediately with that message rather than as four empty
  stages.
- The persona files exist in this skill directory (shipped with the skill):
  `prompts/swe.md`, `prompts/architect.md`, `prompts/chair.md`, `prompts/factcheck.md`, and
  the file-type checklists under `prompts/rules/`.
- The current working directory is inside a git repository.

## Why the run is configured the way it is

- Driven by `--model` (not `--agent`): self-contained (no config dependency) and avoids the
  `mode:subagent`-as-top-level self-replication fork bomb.
- `--pure` skips external plugins, so startup is lean and there's no port to collide on.
- `--format json` makes the report recoverable at all: the model's prose, tool output and stop
  reason arrive as separate typed events instead of as lines in a rendered transcript that had
  to be told apart afterwards. stderr is captured to its own file rather than merged, since it
  is not JSON and would otherwise interleave unparseable lines into the event stream.
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
