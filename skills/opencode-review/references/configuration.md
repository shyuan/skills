# Configuration

Every environment override for both gates, and what to check when a run fails. See
[SKILL.md](../SKILL.md) for how to invoke either gate.

## Gate one

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
  [What gate one leaves behind](../SKILL.md#what-gate-one-leaves-behind)).
- `OPENCODE_REVIEW_DRY_RUN=1` — synthesise every model call instead of making it. Nothing is
  billed and **nothing is reviewed**; the synthetic report echoes the stage, model, variant and
  the first line of the message it was handed. This is a test seam for the orchestration —
  seat fan-out, message assembly, report plumbing, exit statuses — which is the part that breaks
  when a seat is added, and which otherwise costs real money and minutes per iteration to
  exercise. `OPENCODE_REVIEW_DRY_RUN_FAIL="swe=empty,chair=error,sre=timeout"` injects the three
  failure shapes the real runs produce (a model that stops without writing, a provider refusal,
  a timeout) so the degraded paths can be exercised too.

## Gate two

`OPENCODE_REVIEW_VERIFY_SOURCE`, `_FINDINGS` and `_SINCE` are described with the gate itself in
[SKILL.md](../SKILL.md#the-verify-gate), since which findings are judged and what they are judged
against is not a tuning knob. The rest: `OPENCODE_REVIEW_VERIFY_MODEL` (default
`opencode-go/glm-5.3-flash`, a different family from the chair's default so it does not share the
blind spots of the stage it is checking), `OPENCODE_REVIEW_VERIFY_VARIANT` (default `max`),
`OPENCODE_REVIEW_VERIFY_PR`,
`OPENCODE_REVIEW_VERIFY_RUN` (a specific saved run directory instead of the one `latest`
names), and `OPENCODE_REVIEW_VERIFY_DIFF_MAX` (default `200000`; truncation is announced in the
message with a marker, and a finding whose fix would fall in the truncated tail must come back
`無法驗證`, never `未修正`). `OPENCODE_REVIEW_TIMEOUT`, `_PROVIDER`, `_DEP_DIRS` and
`_DRY_RUN` behave as they do for gate one. Exit statuses are the same three: `0`, `1`, `3`.

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

