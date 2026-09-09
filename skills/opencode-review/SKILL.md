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
[Why only two seats are on by default](#why-only-two-seats-are-on-by-default).

Every seat runs on the **cheap tier of its family, at high reasoning effort** — see
[Why these models](#why-these-models).

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

Optional environment overrides:

- `OPENCODE_REVIEW_PROVIDER=<id>` — reach the **default** models through a provider one level
  up, e.g. `omniroute` → `omniroute/opencode-go/glm-5.3-flash`. For a setup that fronts several
  OpenCode plans with a router, this is what spreads a run's calls (the members' concurrent)
  across the plans instead of stacking them on one account. Unset (the default)
  the ids are used directly, unchanged. It applies to the defaults only — an explicit
  `*_MODEL` below is always a full id, so spell the provider into it if you want it routed.
  Caveat: a router configured as a generic OpenAI-compatible provider is not in models.dev,
  so opencode has no context/output limits for its models and a diff that overruns one
  surfaces as a provider error rather than an up-front warning. Declare `limit` on those
  models in `opencode.jsonc` if that bites.
- `OPENCODE_REVIEW_SEATS=swe,architect[,tester][,sre]` — which member seats sit on the
  committee (default `swe,architect`). Unknown names are an error rather than a silent skip;
  a repeated name is deduplicated, since two identical reports would be read by the chair as
  two members agreeing.
- `OPENCODE_REVIEW_SWE_MODEL` / `_ARCH_MODEL` / `_TESTER_MODEL` / `_SRE_MODEL` / `_CHAIR_MODEL`
  — override the committee's models (defaults: `opencode-go/muse-spark-1.3-contributor`,
  `opencode-go/glm-5.3-flash`, `opencode-go/qwen3.8-flash`, `opencode-go/gpt-5.6-luna`,
  `opencode-go/minimax-m3`). Note the env name for the architect seat is `ARCH`, not
  `ARCHITECT` — it predates the seat table and renaming it would break existing invocations.
- `OPENCODE_REVIEW_SWE_VARIANT` / `_ARCH_VARIANT` / `_TESTER_VARIANT` / `_SRE_VARIANT` /
  `_CHAIR_VARIANT` / `_FACTCHECK_VARIANT`
  — the reasoning effort each seat runs at, passed to opencode as `--variant`. Defaults
  `xhigh`, `max`, `xhigh`, `max`, **none**, `max` respectively — the chair's is empty because
  `minimax-m3` exposes reasoning as a toggle rather than a ladder, and passing a rung a model
  does not have is how a stage gets refused under a message the log can only call a provider
  error. Effort names are **per-model** — they come
  from each model's own `reasoning_options`, and the ladders differ (`glm`/`deepseek`/`gpt`
  top out at `max`, `muse`/`qwen` at `xhigh`) — so a default variant is only valid for the
  model it was picked for. Naming your own model for a seat therefore **clears that seat's
  variant** unless you also name one; set a variant to `""` to pass none.
- `OPENCODE_REVIEW_MODEL=<id>` — skip the committee and run a single model (with the SWE persona).
- `OPENCODE_REVIEW_VARIANT=<effort>` — variant for `OPENCODE_REVIEW_MODEL`. No default: the
  model is the caller's choice, so its effort ladder is unknown here.
- `OPENCODE_REVIEW_AGENT=<name>` — escape hatch: run a single **pre-configured** opencode
  agent via `--agent` (must be `mode:primary`).
- `OPENCODE_REVIEW_RULES=0` — disable the file-type checklist injection (default on).
- `OPENCODE_REVIEW_DEP_DIRS=<dir>[:<dir>…]` — extra dependency-source directories the file
  tools may read (Go's `GOMODCACHE` and `$CARGO_HOME/registry` are detected automatically).
- `OPENCODE_REVIEW_FACTCHECK=0` — disable the phase-3 fact-check pass (default on).
- `OPENCODE_REVIEW_FACTCHECK_MODEL=<id>` — model for the fact-check pass (default
  `opencode-go/deepseek-v4-flash`; independent of the chair model).
- `OPENCODE_REVIEW_FACTCHECK_DIFF_MAX=<bytes>` — how much of the diff is inlined into the
  phase-3 message before it is truncated (default `200000`). The fact-checker is given the diff
  itself, not an instruction to fetch one, since it may only prune findings that diff
  contradicts. Truncation is announced in the text with a marker rather than done silently —
  the pass has to know the diff is partial in order to keep findings about the part it cannot
  see. Raise this if you suspect relevant findings fall in the truncated tail.
- `OPENCODE_REVIEW_TIMEOUT=<seconds>` — per-model hard timeout (default `900`).
- `OPENCODE_REVIEW_STAGGER=<seconds>` — delay **between** consecutive parallel member launches
  (default `3`), to avoid opencode's session-init "database is locked" startup race. It is paid
  per extra member, so a four-seat run starts 9s after a one-seat run does.
- `OPENCODE_REVIEW_SAVE=0` — do not save the run for gate two (default on; see
  [What gate one leaves behind](#what-gate-one-leaves-behind)).
- `OPENCODE_REVIEW_DRY_RUN=1` — synthesise every model call instead of making it. Nothing is
  billed and **nothing is reviewed**; the synthetic report echoes the stage, model, variant and
  the first line of the message it was handed. This is a test seam for the orchestration —
  seat fan-out, message assembly, report plumbing, exit statuses — which is the part that breaks
  when a seat is added, and which otherwise costs real money and minutes per iteration to
  exercise. `OPENCODE_REVIEW_DRY_RUN_FAIL="swe=empty,chair=error,sre=timeout"` injects the three
  failure shapes the real runs produce (a model that stops without writing, a provider refusal,
  a timeout) so the degraded paths can be exercised too.

Each stage runs with **`--format json`**, so what the script captures is opencode's event
stream — one JSON object per line — not a rendered transcript. The chair's consolidated report
is printed to **stdout** between the `===== … REVIEW … =====` and `===== END OF REVIEW =====`
markers. Only the script's own progress/error lines (prefixed `[opencode-review]`) go to
**stderr**. If the chair fails or times out, the member reports are printed as a fallback so
you still have something actionable.

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
any model call, so a machine with neither fails immediately rather than after every stage.

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

**A provider refusal is reported as itself, and short-circuits the run.** opencode emits a
`{"type":"error"}` event when a request fails outright — bad model id, auth failure, quota — and
that event carries the provider's own words:

```
[opencode-review] WARN: swe: provider error: Monthly usage limit reached. Resets in 1 day.
[opencode-review] WARN: every member failed with a provider error; continuing to the chair,
                        which may still read the diff itself.
```

**No stage is skipped because of it**, and the run reports it in the exit status instead. A
refused stage ends in about a second under `--format json`, so there is nothing left to save by
giving up early — the ~45 minutes [issue #30](https://github.com/shyuan/skills/issues/30)
recorded came from the *old* output format leaving the process alive with nothing to say, which
#34 removed when it switched every stage to the event stream. (Fact-check was never part of that
cost: it only runs when the chair produced a report.)

Skipping the chair would also risk the whole output for no gain, because the error event cannot
tell *"this provider is out of quota"* from *"these two model ids are wrong"* — and in the second
case a chair on a valid model would have worked.

Exit statuses: `0` clean, `1` a stage failed, `3` a stage failed **with a provider error, for a
model the provider has**. That is the whole claim — `3` does not tell you whether to retry, and
deliberately so:

```
Monthly usage limit reached. Resets in 1 day.   -> rerunning cannot help
Provider rate limit exceeded                    -> rerunning may well help
Inference is temporarily unavailable            -> rerunning may well help
```

All three arrive as the same event. The message that distinguishes them is the provider's own,
and it is printed on the `WARN` line — so the status classifies and the message advises.

Two conditions gate `3`, both supportable from evidence. There has to be an error event, which
separates a provider failure from a model that merely stopped. And every failed model has to be
one `opencode models` lists: a *nonexistent model id* produces the same generic `UnknownError`,
but the cause there is local configuration and the `diag :` lines already say so (`1`). If the
listing could not be obtained, neither is claimed and it stays `1`.

`3` classifies a run that completed every stage — nothing is skipped to produce it.

**When members are absent, the last thing on stdout says so**, inside the report markers:

```
**DEGRADED: 2 of 4 members produced no report.** Missing: tester, sre.
**DEGRADED: 2 of 2 members produced no report.** Nothing above is a committee finding —
it is a solo judgment by the chair model, which read the diff itself.
```

Which of the two it says is decided by the chair's own state: claiming a solo chair judgment
when the chair also produced nothing would describe output that does not exist.

The chair does note an absence in its own preamble, but that lands where a skimming reader
misses it — and a chair report built on no members is one model's opinion wearing a committee's
shape, which is exactly the thing the design exists to avoid.

**When a stage fails, the log also says whether the models were even available.** opencode
says nothing about the model when the id is bad — `opencode run --model does-not-exist/at-all`
emits a bare `UnknownError: "Unexpected server error"` that never names the id — so the script
would otherwise report `NO REPORT PRODUCED` for every stage with nothing pointing at the cause.
This is the first thing anyone hits running the skill on a machine without the default provider.
So on the failure path only, the run checks the failed stages' models against `opencode models`:

```
[opencode-review] diag  : NOT available in this OpenCode setup: opencode-go/glm-5.3-flash …
[opencode-review] diag  : that alone accounts for an empty report — opencode reports only a
                          generic server error for an unusable model id, never naming it.
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

Other overrides: `OPENCODE_REVIEW_VERIFY_MODEL` (default `opencode-go/glm-5.3-flash`, a
different family from the chair's default so it does not share the blind spots of the stage it
is checking), `OPENCODE_REVIEW_VERIFY_VARIANT` (default `max`), `OPENCODE_REVIEW_VERIFY_PR`,
`OPENCODE_REVIEW_VERIFY_RUN` (a specific saved run directory instead of the one `latest`
names), and `OPENCODE_REVIEW_VERIFY_DIFF_MAX` (default `200000`; truncation is announced in the
message with a marker, and a finding whose fix would fall in the truncated tail must come back
`無法驗證`, never `未修正`). `OPENCODE_REVIEW_TIMEOUT`, `_PROVIDER`, `_DEP_DIRS` and
`_DRY_RUN` behave as they do for gate one. Exit statuses are the same three: `0`, `1`, `3`.

If nothing has changed since the review, the run says so before spending the call — every
finding would come back `未修正`, which may be the honest answer or may mean the wrong commit
is being verified.

## Prerequisites

Only check these if the run fails — and check the `diag :` lines first, which report the most
common cause on their own:

- `opencode` is on `PATH`, with the chosen models authenticated (same providers as the TUI).
  Only **model access** is required — no committee agents need to exist in `opencode.jsonc`.
  The defaults name `opencode-go/*` models, which assumes an OpenCode Go plan; on a setup
  without one, point `OPENCODE_REVIEW_{SWE,ARCH,TESTER,SRE,CHAIR,FACTCHECK,VERIFY}_MODEL` at models from
  `opencode models`, or set `OPENCODE_REVIEW_PROVIDER` if the same models sit behind a router.
  Doing either clears that seat's reasoning-effort default, since effort names are per-model.
- An `opencode` new enough to have `run --variant`. If it is not, the run says so on its
  **last line**, on the success path as well as the failure path:

  ```
  [opencode-review] WARN: this 'opencode' has no 'run --variant' flag. The reasoning effort
                          logged above as '@...' was therefore NOT applied — each stage ran
                          at its model's default effort, whatever the log line said.
  ```

  Reporting it on a *clean* run is the point. A parser that rejects the unknown flag fails
  every stage at once and is already loud; the dangerous case is one that ignores it, where
  every stage succeeds at default effort and the log claims `@xhigh` — a report quietly worse
  than the one it says it is. The check costs ~6s and runs in the **background**, concurrently
  with phase 1, so a clean run pays nothing in wall-clock; a run that passes no variant never
  starts it. It reports what the binary does, and does not blame any particular failure on it.
- **`jq` or `python3` is on `PATH`** — one of them reads opencode's JSON events. Checked at
  startup, so a missing reader fails immediately with that message rather than as a run of
  empty stages.
- The persona files exist in this skill directory (shipped with the skill):
  `prompts/swe.md`, `prompts/architect.md`, `prompts/tester.md`, `prompts/sre.md`,
  `prompts/chair.md`, `prompts/factcheck.md`, `prompts/verify.md`, and the file-type checklists
  under `prompts/rules/`. The machinery both scripts share lives in `scripts/lib/common.sh`,
  which is sourced, not executed.
- The current working directory is inside a git repository.

## Why these models

Every seat sits on the **cheap tier of the family it used to run at the top of**, and buys
back what that costs with **reasoning effort** rather than with a bigger model. A committee
run is four calls by default, two of them reading the whole diff — the flagship tier priced a routine
pre-PR check like a rare one. Per million tokens, in/out:

| seat | was | now | effort |
|---|---|---|---|
| SWE | `kimi-k3` — 3.00 / 15.00 | `muse-spark-1.3-contributor` — 0.10 / 0.20 | `xhigh` |
| Architect | `glm-5.3` — 1.40 / 4.40 | `glm-5.3-flash` — 0.075 / 0.25 | `max` |
| Chair | `qwen3.8-max` — 2.00 / 6.00 | `minimax-m3` — 0.30 / 1.20 | *toggle* |
| Fact-check | `deepseek-v4-pro` — 0.66 / 1.98 | `deepseek-v4-flash` — 0.22 / 0.66 | `max` |
| Tester (opt-in) | — | `qwen3.8-flash` — 0.15 / 0.47 | `xhigh` |
| SRE (opt-in) | — | `gpt-5.6-luna` — 0.20 / 1.20 | `max` |
| Verify (gate two) | — | `glm-5.3-flash` — 0.075 / 0.25 | `max` |

The two limits the seats actually bind on survive the swap, which is what makes it a swap
rather than a downgrade in kind. Every member keeps a **~1M context window** — the SWE seat's
constraint, since it reads the whole diff plus the rules checklists plus whatever it opens with
the file tools, and a run that overruns bills for the whole thing and returns no report — and
the chair keeps a **131k output cap**, its own constraint, since the consolidated report is its
output and a 64k cap once truncated it.

**The chair is the exception to both halves of that trade**, and deliberately so. It is the
dearest seat in the run — `minimax-m3` at 0.30/1.20, and 0.60/2.40 once its context passes
200k, against 0.075–0.20 in for every member — and the only seat with no reasoning effort,
since its `reasoning_options` are a bare toggle with no ladder to climb. Two things
about this seat and no other pay for that:

- **It is the seat to spend on.** Every later stage can only *remove* from what the chair lets
  through, so precision bought here is the only kind that reaches the report. The absolute cost
  stays small because the chair's input is the members' *reports*, not the diff — of every
  stage, it is the cheapest one to run dear.
- **It has to be nobody's family.** The chair judges the members, and it used to default to
  `qwen3.8-flash`, which is also the tester seat's default — so on a four-seat run the chair was
  a member checking itself under a different persona. `minimax` is a fifth family, shared with
  no seat. It also keeps the 131k output cap this seat binds on, and brings a 1M window for when
  the chair reads the diff itself.

None of this is a measured quality claim; it is a cost/quality trade taken deliberately. **If
the committee still reads thin, keep spending here** rather than on the members: put
`qwen3.8-max` in via `OPENCODE_REVIEW_CHAIR_MODEL` before touching the others, and remember to
set `OPENCODE_REVIEW_CHAIR_VARIANT` with it — naming a model clears that seat's effort default,
since effort names are per-model.

## Why only two seats are on by default

The cost of an extra seat is not the money — on this tier a member call is fractions of a cent.
It is three things the committee's design is built on:

- **The chair is the only precision lever, and it stays one flash model.** Every extra member
  enlarges the synthesis job that the one stage capable of rejecting shaky items has to do.
- **The chair reads agreement as confidence.** "Two members raised this" is a signal it acts on,
  so a seat that overlaps an existing one does not add a check — it manufactures agreement.
- **Every seat is an independent false-positive source.** Recall is not free; it is paid for in
  the chair's ability to say no.

So **orthogonality, not usefulness, is the admission test**. Tester and SRE pass it: neither
default seat reads the test files, and neither asks what happens after the change ships. A
*security* seat would fail it — `prompts/swe.md` already covers injection, auth bypass and
secret leakage, so splitting it out would double-count every finding it makes unless `swe.md`
gave that ground up. Docs/DX fails it for a different reason: on most diffs it has nothing to
say, and a seat with nothing to say writes something anyway.

The four members deliberately run four **different families**, the chair a fifth, and the
fact-check a sixth. The whole argument for a committee is blind-spot diversity; two seats on one
family is one seat that costs twice, a chair sharing a member's model is a member marking its own
work, and a fact-check sharing a member's model is that member being asked whether its own
reasoning was supported. The one overlap left is deliberate: gate two's verify model is the
architect's `glm-5.3-flash`, and the two never see the same input — verify reads findings and fix
commits, never the review it is checking up on.

Widen the committee when a change deserves it: a release-shaped change (schema, config format,
public API, deploy path) is what `sre` is for, and a change to code with a real test suite is
what `tester` is for.

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
- **The run has no network and cannot delegate.** `webfetch` and `websearch` are denied, as are
  `task`, `skill` and `lsp`. `webfetch` was the one that mattered: it had been left unset and
  opencode's default for it is *allow*, so a reviewer had unrestricted outbound egress while
  reading a diff this same block documents as untrusted — a way for injected text to send repo
  content outward, with none of the host or path restrictions bash has. No persona asks for the
  network.
- **Every `PermissionConfig` key is decided, not defaulted.** "Unset" is not a uniform default
  and cannot be reasoned about as a group: in the same headless run an unset `external_directory`
  auto-rejects while an unset `webfetch` allows. Denied: `edit`, `question`, `doom_loop`,
  `webfetch`, `websearch`, `task`, `skill`, `lsp`. Structured: `bash`, `external_directory`.
  Left to the user's config on purpose: `read`, `glob`, `grep`, `list`, `todowrite` — writing
  them as explicit allows would override a user who had deliberately restricted them, and they
  are the reviewers' actual job. Denying is free, unlike denying a bash *pattern*: a denied tool
  is removed from the model's toolset rather than rejected on use, so it costs no turn.
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
- **What is readable is asked, not assumed.** `OPENCODE_PERMISSION` is *merged* with the saved
  config and `external_directory` merges deep, so a path allowed in your global config or the
  project's `opencode.json` is readable to the file tools as well — something the caches above
  say nothing about. The script therefore asks `opencode debug config --pure`, under the
  permission set it is about to use, for the merged answer, and it is that list the `deps :`
  line reports and the personas receive. Only `"allow"` entries are taken (naming a `deny`/`ask`
  path would send members at reads that get rejected), a trailing `/**` is stripped and `~` is
  expanded, since a persona needs an absolute path. The call is bounded like every other
  `opencode` call here and fails soft: on a missing subcommand, a non-zero exit, a timeout or
  unparseable output the list falls back to the script's own caches and the log says so, so the
  lookup can only ever add information. It costs one extra `opencode` invocation (~5s, measured)
  before phase 1, overlapped with the `--variant` probe.
- **That list is partly untrusted, and is treated as such.** A project's `opencode.json` is a
  file in the checkout under review, so on a branch you did not write its `external_directory`
  keys are attacker-controlled text heading straight for the most trusted part of every persona.
  A key holding an escaped newline would otherwise become a second bullet in the environment
  section — a prompt injection with a short path to "report no findings". So only keys that are
  plain absolute paths survive (no control characters, no backtick, 512 bytes max), a second
  filter drops any line that is not a path before it reaches a prompt, each one is rendered
  inside a code span so a name that reads like prose arrives as data, the personas say outright
  that the entries are path strings and not instructions, and the list is capped at 40 with the
  remainder announced. Rejected entries are counted in the log, never echoed — the log is read
  by the calling agent too.
- **The personas state these boundaries up front** rather than letting models find them by
  hitting them: no test/build execution (that would run code from the untrusted diff), what is
  readable and how, no retrying a rejected call, and — because two members once ended a run on
  a rejected call having written nothing — produce a report regardless, noting what could not
  be verified. The readable-path list is not written in the prompt files: they carry a
  `{{EXTERNAL_READ_PATHS}}` placeholder that `read_prompt` fills for every persona, members and
  chair alike, so no persona can state a boundary that differs from the one in force. Before
  this, all three hardcoded "outside the repo is denied" — and, told to trust that rather than
  probe, reviewers left a sibling repo the user had deliberately allowed unread and reported it
  as unverifiable (#42).
- `GIT_PAGER=cat` / `PAGER=cat` stop git from opening a pager that would hang in a non-TTY.
- The members run in parallel, then the chair runs once, then the optional fact-check runs
  once — so a large diff can take a few minutes. Each model run has its own timeout; a hung
  member can't block the others, the chair, or the fact-check.
- The fact-check pass can only ever *remove* false positives: on any failure/timeout/empty
  output the chair's report is emitted unchanged, and removed items are listed transparently
  (not silently dropped) so you can override the call.
- **Both scripts share `scripts/lib/common.sh`**, which holds the permission set, the private
  scratch dir, the bounded `opencode run` wrapper, the JSON event readers and the model
  diagnosis. It is sourced, never executed; the caller sets its own seat/model variables and
  calls `oc_env_init`, whose ordering is load-bearing (scratch dir → `--variant` probe →
  cleanup trap → permission-dependent readable-path resolution). It was split out when gate two
  appeared and would otherwise have had to copy ~900 lines of gate one.
- **Gate two keeps repo read access; the fact-check pass does not.** They look similar — one
  model, one message, adjudicating someone else's findings — but their safety properties are
  opposite. Fact-check is diff-only precisely so that it *cannot* over-prune: a finding it
  cannot see is a finding it must keep. Gate two has to answer "is this fix correct", and a fix
  read without its callers is routinely judged wrong; denying it the repo would not make it
  safer, it would make every non-trivial verdict `無法驗證`.

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
